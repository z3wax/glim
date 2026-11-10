import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'settings.dart';

/// Desktop screen capture helpers (X11 / XWayland via ffmpeg `x11grab`).
class ScreenCapture {
  /// Native Wayland windows are invisible to x11grab (they record black).
  static bool get isWayland =>
      (Platform.environment['XDG_SESSION_TYPE'] ?? '').toLowerCase() ==
          'wayland' ||
      (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;

  /// Monitors reported by `xrandr --listmonitors` (falls back to the root
  /// window size from `xdpyinfo`).
  static Future<List<ScreenRegion>> listMonitors(String display) async {
    final env = {'DISPLAY': display};
    try {
      final r = await Process.run('xrandr', [
        '--listmonitors',
      ], environment: env);
      if (r.exitCode == 0) {
        final list = parseXrandrMonitors(r.stdout as String);
        if (list.isNotEmpty) return list;
      }
    } catch (_) {}
    try {
      final r = await Process.run('xdpyinfo', [], environment: env);
      final m = RegExp(r'dimensions:\s+(\d+)x(\d+)')
          .firstMatch(r.stdout as String);
      if (m != null) {
        return [
          ScreenRegion(
            0,
            0,
            int.parse(m.group(1)!),
            int.parse(m.group(2)!),
            'Ekran',
          ),
        ];
      }
    } catch (_) {}
    return const [];
  }

  /// Parses lines like ` 0: +*eDP-1 1920/344x1080/194+0+0  eDP-1`.
  static List<ScreenRegion> parseXrandrMonitors(String out) {
    final re = RegExp(r'(\d+)/\d+x(\d+)/\d+\+(\d+)\+(\d+)\s+(\S+)\s*$');
    return [
      for (final line in out.split('\n'))
        if (re.firstMatch(line.trim()) case final m?)
          ScreenRegion(
            int.parse(m.group(3)!),
            int.parse(m.group(4)!),
            int.parse(m.group(1)!),
            int.parse(m.group(2)!),
            m.group(5)!,
          ),
    ];
  }

  /// Lets the user drag a rectangle on screen with `slop`.
  /// Returns null when cancelled; throws [ProcessException] if missing.
  static Future<ScreenRegion?> pickRegion(String display) async {
    final r = await Process.run(
      'slop',
      ['-f', '%x %y %w %h', '-b', '3', '-c', '1,0.3,0.43,1'],
      environment: {'DISPLAY': display},
    );
    if (r.exitCode != 0) return null;
    final p = (r.stdout as String).trim().split(RegExp(r'\s+'));
    if (p.length != 4) return null;
    final v = p.map(int.tryParse).toList();
    if (v.any((e) => e == null)) return null;
    final region = ScreenRegion(v[0]!, v[1]!, v[2]!, v[3]!, 'tanlangan');
    return region.isValid ? region : null;
  }

  /// ffmpeg input arguments that grab [region] of [display].
  static List<String> x11grabInput(
    ScreenRegion region, {
    required String display,
    required int fps,
    bool drawMouse = true,
  }) {
    // x11grab wants even sizes for most encoders.
    final w = region.w ~/ 2 * 2;
    final h = region.h ~/ 2 * 2;
    return [
      '-thread_queue_size',
      '512',
      '-f',
      'x11grab',
      '-framerate',
      '$fps',
      '-draw_mouse',
      drawMouse ? '1' : '0',
      '-video_size',
      '${w}x$h',
      '-i',
      '$display+${region.x},${region.y}',
    ];
  }
}

/// Low frame-rate screen grabber used only for the live preview.
class ScreenPreview extends ChangeNotifier {
  Process? _proc;
  String? error;
  ScreenRegion? _region;
  final _frames = StreamController<Uint8List>.broadcast();

  Stream<Uint8List> get frames => _frames.stream;
  bool get active => _proc != null;

  Future<void> start(
    ScreenRegion region,
    String display, {
    bool drawMouse = true,
  }) async {
    if (_proc != null && _region?.toString() == region.toString()) {
      return;
    }
    await stop();
    _region = region;
    error = null;
    try {
      final p = await Process.start('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        ...ScreenCapture.x11grabInput(
          region,
          display: display,
          fps: 8,
          drawMouse: drawMouse,
        ),
        '-vf',
        'scale=960:960:force_original_aspect_ratio=decrease',
        '-f',
        'image2pipe',
        '-c:v',
        'mjpeg',
        '-q:v',
        '6',
        '-',
      ]);
      _proc = p;
      final err = StringBuffer();
      p.stderr.transform(const SystemEncoding().decoder).listen(err.write);
      final splitter = JpegStreamSplitter();
      p.stdout.listen((chunk) {
        for (final f in splitter.add(chunk)) {
          if (!_frames.isClosed) _frames.add(f);
        }
      });
      unawaited(
        p.exitCode.then((code) {
          if (_proc == p) {
            _proc = null;
            if (code != 0 && code != -15) {
              error = 'Ekranni olib bo\'lmadi: ${err.toString().trim()}';
            }
            notifyListeners();
          }
        }),
      );
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    _region = null;
    p?.kill();
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    _frames.close();
    super.dispose();
  }
}

/// Splits a concatenated MJPEG byte stream into individual JPEG images.
/// (0xFFD9 can't appear inside JPEG entropy data thanks to byte stuffing.)
class JpegStreamSplitter {
  final BytesBuilder _buf = BytesBuilder(copy: false);

  List<Uint8List> add(List<int> chunk) {
    _buf.add(chunk);
    final data = _buf.takeBytes();
    final frames = <Uint8List>[];
    var start = 0;
    for (var i = 1; i < data.length; i++) {
      if (data[i - 1] == 0xFF && data[i] == 0xD9) {
        frames.add(
          Uint8List.fromList(Uint8List.sublistView(data, start, i + 1)),
        );
        start = i + 1;
      }
    }
    if (start < data.length) _buf.add(Uint8List.sublistView(data, start));
    return frames;
  }
}
