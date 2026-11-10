import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PhoneCamera {
  PhoneCamera(this.id, this.name, this.front);

  final String id;
  final String name;
  final bool front;

  factory PhoneCamera.fromMap(Map<dynamic, dynamic> m) =>
      PhoneCamera(m['id'] as String, m['name'] as String, m['front'] == true);
}

/// Dart side of the native iOS streamer in `ios/Runner/AppDelegate.swift`.
class CameraBridge extends ChangeNotifier {
  CameraBridge() {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static const _channel = MethodChannel('glim/camera');

  int? textureId;
  bool cameraGranted = false;
  bool micGranted = false;
  List<PhoneCamera> cameras = [];

  bool running = false;
  bool listening = false;
  bool clientConnected = false;
  String clientAddress = '';
  int captureFps = 0;
  int sendFps = 0;
  int width = 0;
  int height = 0;
  String error = '';

  String? cameraId;
  double zoom = 1;
  double maxZoom = 1;
  bool torch = false;
  bool hasTorch = false;

  Future<void> initialize() async {
    final res = await _channel.invokeMapMethod<String, dynamic>('initialize');
    if (res == null) return;
    textureId = res['textureId'] as int?;
    cameraGranted = res['cameraGranted'] == true;
    micGranted = res['micGranted'] == true;
    cameras = (res['cameras'] as List)
        .map((e) => PhoneCamera.fromMap(e as Map))
        .toList();
    cameraId ??= cameras
        .firstWhere((c) => !c.front, orElse: () => cameras.first)
        .id;
    notifyListeners();
  }

  Future<void> start({
    required String preset,
    required int fps,
    required double quality,
    required bool audio,
    required int port,
    required bool portrait,
  }) async {
    await _channel.invokeMethod('start', {
      'camera': cameraId,
      'preset': preset,
      'fps': fps,
      'quality': quality,
      'audio': audio && micGranted,
      'port': port,
      'orientation': portrait ? 'portrait' : 'landscape',
    });
    running = true;
    notifyListeners();
  }

  Future<void> stop() async {
    await _channel.invokeMethod('stop');
    running = false;
    clientConnected = false;
    notifyListeners();
  }

  Future<void> selectCamera(String id) async {
    cameraId = id;
    zoom = 1;
    torch = false;
    notifyListeners();
    await _channel.invokeMethod('selectCamera', {'id': id});
  }

  Future<void> setZoom(double value) async {
    zoom = value;
    notifyListeners();
    await _channel.invokeMethod('setZoom', {'value': value});
  }

  Future<void> setTorch(bool on) async {
    torch = on;
    notifyListeners();
    await _channel.invokeMethod('setTorch', {'on': on});
  }

  Future<void> setQuality(double value) =>
      _channel.invokeMethod('setQuality', {'value': value});

  Future<dynamic> _onNativeCall(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'status':
        listening = args['listening'] == true;
        clientConnected = args['client'] == true;
        clientAddress = (args['clientAddress'] as String?) ?? '';
        captureFps = (args['captureFps'] as int?) ?? 0;
        sendFps = (args['sendFps'] as int?) ?? 0;
        width = (args['width'] as int?) ?? 0;
        height = (args['height'] as int?) ?? 0;
        error = (args['error'] as String?) ?? '';
      case 'info':
        cameraId = (args['camera'] as String?) ?? cameraId;
        zoom = (args['zoom'] as num?)?.toDouble() ?? zoom;
        maxZoom = (args['maxZoom'] as num?)?.toDouble() ?? maxZoom;
        torch = args['torch'] == true;
        hasTorch = args['hasTorch'] == true;
      case 'remoteCommand':
        // State is refreshed by the following 'info' call.
        break;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    _channel.invokeMethod('dispose');
    super.dispose();
  }
}
