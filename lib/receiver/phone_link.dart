import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../protocol.dart';

enum LinkMode { usb, wifi }

enum LinkState { idle, waitingDevice, connecting, connected, error }

class RemoteCamera {
  RemoteCamera(this.id, this.name, this.front);
  final String id;
  final String name;
  final bool front;
}

/// Connects the desktop to the iPhone app.
///
/// USB mode starts `iproxy` (libusbmuxd-tools) which forwards a local TCP
/// port to the phone's port through the USB cable, then connects to it.
/// Wi-Fi mode connects to the phone's IP address directly.
class PhoneLink extends ChangeNotifier {
  static const int localUsbPort = 18686;

  LinkMode mode = LinkMode.usb;
  String host = '';
  int port = GlimProtocol.defaultPort;

  LinkState state = LinkState.idle;
  String message = '';

  // Phone info.
  String deviceName = '';
  List<RemoteCamera> cameras = [];
  String cameraId = '';
  double zoom = 1;
  double maxZoom = 1;
  bool hasTorch = false;
  bool torch = false;
  int frameWidth = 0;
  int frameHeight = 0;

  /// Latest received JPEG frame.
  Uint8List? latestFrame;
  int framesReceived = 0;
  int fps = 0;
  double mbps = 0;

  final _frames = StreamController<Uint8List>.broadcast();
  final _audio = StreamController<GlimPacket>.broadcast();

  /// Every received JPEG frame.
  Stream<Uint8List> get frames => _frames.stream;

  /// Every received audio packet (s16le PCM).
  Stream<GlimPacket> get audio => _audio.stream;

  Process? _iproxy;
  Socket? _socket;
  StreamSubscription<Uint8List>? _sub;
  final _parser = GlimPacketParser();
  bool _wanted = false;
  Timer? _retry;
  Timer? _stats;
  int _statFrames = 0;
  int _statBytes = 0;

  bool get connected => state == LinkState.connected;

  Future<void> start() async {
    _wanted = true;
    _stats ??= Timer.periodic(const Duration(seconds: 1), (_) {
      fps = _statFrames;
      mbps = _statBytes * 8 / 1e6;
      _statFrames = 0;
      _statBytes = 0;
      notifyListeners();
    });
    await _connectLoop();
  }

  Future<void> stop() async {
    _wanted = false;
    _retry?.cancel();
    _retry = null;
    await _closeSocket();
    _killIproxy();
    _setState(LinkState.idle, "Ulanish to'xtatildi");
  }

  Future<void> _connectLoop() async {
    if (!_wanted || _socket != null) return;
    try {
      String targetHost;
      int targetPort;
      if (mode == LinkMode.usb) {
        final devices = await listUsbDevices();
        if (devices == null) {
          _setState(
            LinkState.error,
            "iproxy topilmadi. O'rnating: sudo apt install usbmuxd libimobiledevice-utils libusbmuxd-tools",
          );
          _scheduleRetry(const Duration(seconds: 3));
          return;
        }
        if (devices.isEmpty) {
          _killIproxy();
          _setState(
            LinkState.waitingDevice,
            "iPhone USB orqali topilmadi. Kabelni ulang va iPhone'da \"Trust / Ishonish\" ni bosing.",
          );
          _scheduleRetry(const Duration(seconds: 2));
          return;
        }
        await _ensureIproxy();
        targetHost = '127.0.0.1';
        targetPort = localUsbPort;
      } else {
        if (host.trim().isEmpty) {
          _setState(LinkState.error, 'iPhone IP manzilini kiriting');
          return;
        }
        targetHost = host.trim();
        targetPort = port;
      }

      _setState(LinkState.connecting, 'Ulanmoqda $targetHost:$targetPort…');
      final socket = await Socket.connect(
        targetHost,
        targetPort,
        timeout: const Duration(seconds: 3),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _parser.reset();
      var gotData = false;
      _sub = socket.listen(
        (chunk) {
          if (!gotData) {
            gotData = true;
            _setState(LinkState.connected, 'Ulandi');
          }
          _statBytes += chunk.length;
          try {
            for (final p in _parser.add(chunk)) {
              _handle(p);
            }
          } on FormatException catch (e) {
            _setState(LinkState.error, 'Buzilgan oqim: ${e.message}');
            _onDisconnected();
          }
        },
        onError: (_) => _onDisconnected(),
        onDone: _onDisconnected,
        cancelOnError: true,
      );
      // iproxy accepts the TCP connection even when the app isn't running on
      // the phone, it then closes immediately; onDone handles the retry.
      Timer(const Duration(seconds: 3), () {
        if (_socket == socket && !gotData) {
          _setState(
            LinkState.connecting,
            "iPhone'da Glim ilovasini oching (port $port)…",
          );
        }
      });
    } catch (e) {
      await _closeSocket();
      _setState(
        LinkState.waitingDevice,
        mode == LinkMode.usb
            ? "iPhone'da Glim ilovasini oching va streamni yoqing…"
            : 'Ulanib bo\'lmadi: $e',
      );
      _scheduleRetry(const Duration(seconds: 2));
    }
  }

  void _handle(GlimPacket p) {
    switch (p.type) {
      case GlimProtocol.kVideo:
        latestFrame = p.payload;
        framesReceived++;
        _statFrames++;
        _frames.add(p.payload);
      case GlimProtocol.kAudio:
        _audio.add(p);
      case GlimProtocol.kInfo:
        final j = p.json;
        deviceName = (j['device'] as String?) ?? '';
        cameras = [
          for (final c in (j['cameras'] as List? ?? const []))
            RemoteCamera(
              c['id'] as String,
              c['name'] as String,
              c['front'] == true,
            ),
        ];
        cameraId = (j['camera'] as String?) ?? '';
        zoom = (j['zoom'] as num?)?.toDouble() ?? 1;
        maxZoom = (j['maxZoom'] as num?)?.toDouble() ?? 1;
        hasTorch = j['hasTorch'] == true;
        torch = j['torch'] == true;
        frameWidth = (j['width'] as num?)?.toInt() ?? 0;
        frameHeight = (j['height'] as num?)?.toInt() ?? 0;
        notifyListeners();
    }
  }

  void sendCommand(Map<String, Object?> cmd) {
    final s = _socket;
    if (s == null) return;
    try {
      s.add(GlimProtocol.encodeJson(GlimProtocol.kCommand, cmd));
    } catch (_) {}
  }

  void selectCamera(String id) => sendCommand({'cmd': 'camera', 'id': id});
  void setZoom(double v) {
    zoom = v;
    notifyListeners();
    sendCommand({'cmd': 'zoom', 'value': v});
  }

  void setTorch(bool on) => sendCommand({'cmd': 'torch', 'on': on});

  void _onDisconnected() {
    final wasConnected = state == LinkState.connected;
    _closeSocket();
    latestFrame = null;
    if (_wanted) {
      _setState(
        LinkState.waitingDevice,
        wasConnected
            ? 'Aloqa uzildi, qayta ulanmoqda…'
            : "iPhone'da Glim ilovasini oching…",
      );
      _scheduleRetry(const Duration(milliseconds: 1500));
    }
  }

  void _scheduleRetry(Duration d) {
    _retry?.cancel();
    if (!_wanted) return;
    _retry = Timer(d, _connectLoop);
  }

  Future<void> _closeSocket() async {
    final sub = _sub;
    final s = _socket;
    _sub = null;
    _socket = null;
    await sub?.cancel();
    s?.destroy();
  }

  /// Returns UDIDs of iPhones connected by USB, or null when the
  /// libimobiledevice tools are not installed.
  static Future<List<String>?> listUsbDevices() async {
    try {
      final r = await Process.run('idevice_id', ['-l']);
      if (r.exitCode != 0 && (r.stdout as String).trim().isEmpty) {
        // idevice_id exits non-zero when usbmuxd isn't running.
        return [];
      }
      return const LineSplitter()
          .convert(r.stdout as String)
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    } on ProcessException {
      // Fall back to iproxy only (it can still work without idevice_id).
      return await _hasCommand('iproxy') ? ['unknown'] : null;
    }
  }

  static Future<bool> _hasCommand(String cmd) async {
    try {
      final r = await Process.run('which', [cmd]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureIproxy() async {
    if (_iproxy != null) return;
    // libusbmuxd >= 2.0 syntax: iproxy LOCAL:DEVICE
    Process p = await Process.start('iproxy', ['$localUsbPort:$port']);
    var exited = false;
    unawaited(p.exitCode.then((_) => exited = true));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (exited) {
      // Legacy syntax: iproxy LOCAL DEVICE
      p = await Process.start('iproxy', ['$localUsbPort', '$port']);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    p.stdout.drain<void>();
    p.stderr.drain<void>();
    _iproxy = p;
    unawaited(
      p.exitCode.then((_) {
        if (_iproxy == p) _iproxy = null;
      }),
    );
  }

  void _killIproxy() {
    _iproxy?.kill();
    _iproxy = null;
  }

  void _setState(LinkState s, String msg) {
    state = s;
    message = msg;
    notifyListeners();
  }

  @override
  void dispose() {
    _wanted = false;
    _retry?.cancel();
    _stats?.cancel();
    _closeSocket();
    _killIproxy();
    _frames.close();
    _audio.close();
    super.dispose();
  }
}
