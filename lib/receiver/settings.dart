import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'phone_link.dart';

enum Framing { fill, fit }

enum AudioSource { phone, desktop, none }

/// What ends up in the 9:16 frame.
enum ReelLayout {
  /// Only the iPhone camera.
  camera,

  /// Screen recording on top, iPhone camera below (classic coding reel).
  split,

  /// Screen recording fills the frame, camera in a round bubble.
  bubble,
}

enum Corner { topLeft, topRight, bottomLeft, bottomRight }

/// A rectangle of the X11 screen to capture (w == 0 means "not set").
class ScreenRegion {
  const ScreenRegion(this.x, this.y, this.w, this.h, [this.label = '']);

  final int x;
  final int y;
  final int w;
  final int h;
  final String label;

  bool get isValid => w > 1 && h > 1;

  @override
  String toString() => '${w}x$h +$x,$y${label.isEmpty ? '' : ' ($label)'}';

  Map<String, Object?> toJson() => {
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'label': label,
  };

  static ScreenRegion? fromJson(Object? j) {
    if (j is! Map) return null;
    int i(String k) => (j[k] as num?)?.toInt() ?? 0;
    return ScreenRegion(
      i('x'),
      i('y'),
      i('w'),
      i('h'),
      (j['label'] as String?) ?? '',
    );
  }
}

/// Desktop recorder settings, persisted to ~/.config/glim/settings.json.
class RecorderSettings extends ChangeNotifier {
  int outWidth = 1080;
  int outHeight = 1920;
  int fps = 30;
  int crf = 20;
  Framing framing = Framing.fill;

  /// Horizontal crop position for [Framing.fill]: -1 (left) .. 1 (right).
  double cropX = 0;

  /// Vertical crop position for [Framing.fill]: -1 (top) .. 1 (bottom).
  double cropY = 0;
  bool mirror = false;
  AudioSource audio = AudioSource.phone;

  /// 0 = unlimited.
  int maxSeconds = 0;
  int countdown = 3;
  String outputDir = '';
  bool safeZones = true;
  bool grid = false;
  bool virtualCam = false;
  String virtualCamDevice = '/dev/video10';

  ReelLayout layout = ReelLayout.camera;

  /// Share of the frame height used by the screen in [ReelLayout.split].
  double splitRatio = 0.58;
  bool cameraOnTop = false;

  /// Bubble diameter as a share of the frame width.
  double bubbleSize = 0.38;
  Corner bubbleCorner = Corner.bottomLeft;

  /// true = letterbox the screen (whole region visible), false = crop.
  bool screenFit = true;
  bool drawMouse = true;
  ScreenRegion? screenRegion;
  String display = Platform.environment['DISPLAY'] ?? ':0';

  LinkMode linkMode = LinkMode.usb;
  String wifiHost = '';

  static String get _home => Platform.environment['HOME'] ?? '.';

  static File get _file {
    final base = Platform.environment['XDG_CONFIG_HOME'] ?? '$_home/.config';
    return File('$base/glim/settings.json');
  }

  static Future<String> defaultOutputDir() async {
    var videos = '$_home/Videos';
    try {
      final r = await Process.run('xdg-user-dir', ['VIDEOS']);
      final out = (r.stdout as String).trim();
      if (r.exitCode == 0 && out.isNotEmpty && out != _home) videos = out;
    } catch (_) {}
    return '$videos/Glim';
  }

  Future<void> load() async {
    try {
      final f = _file;
      if (await f.exists()) {
        fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      }
    } catch (_) {}
    if (outputDir.isEmpty) outputDir = await defaultOutputDir();
    notifyListeners();
  }

  Future<void> save() async {
    try {
      final f = _file;
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(toJson()),
      );
    } catch (_) {}
  }

  void update(VoidCallback fn) {
    fn();
    notifyListeners();
    save();
  }

  Map<String, Object?> toJson() => {
    'outWidth': outWidth,
    'outHeight': outHeight,
    'fps': fps,
    'crf': crf,
    'framing': framing.name,
    'cropX': cropX,
    'cropY': cropY,
    'mirror': mirror,
    'audio': audio.name,
    'maxSeconds': maxSeconds,
    'countdown': countdown,
    'outputDir': outputDir,
    'safeZones': safeZones,
    'grid': grid,
    'virtualCam': virtualCam,
    'virtualCamDevice': virtualCamDevice,
    'layout': layout.name,
    'splitRatio': splitRatio,
    'cameraOnTop': cameraOnTop,
    'bubbleSize': bubbleSize,
    'bubbleCorner': bubbleCorner.name,
    'screenFit': screenFit,
    'drawMouse': drawMouse,
    'screenRegion': screenRegion?.toJson(),
    'linkMode': linkMode.name,
    'wifiHost': wifiHost,
  };

  void fromJson(Map<String, dynamic> j) {
    T pick<T>(String k, T def) => j[k] is T ? j[k] as T : def;
    E pickEnum<E extends Enum>(String k, List<E> values, E def) =>
        values.firstWhere((e) => e.name == j[k], orElse: () => def);

    outWidth = pick('outWidth', outWidth);
    outHeight = pick('outHeight', outHeight);
    fps = pick('fps', fps);
    crf = pick('crf', crf);
    framing = pickEnum('framing', Framing.values, framing);
    cropX = (j['cropX'] as num?)?.toDouble() ?? cropX;
    cropY = (j['cropY'] as num?)?.toDouble() ?? cropY;
    mirror = pick('mirror', mirror);
    audio = pickEnum('audio', AudioSource.values, audio);
    maxSeconds = pick('maxSeconds', maxSeconds);
    countdown = pick('countdown', countdown);
    outputDir = pick('outputDir', outputDir);
    safeZones = pick('safeZones', safeZones);
    grid = pick('grid', grid);
    virtualCam = pick('virtualCam', virtualCam);
    virtualCamDevice = pick('virtualCamDevice', virtualCamDevice);
    layout = pickEnum('layout', ReelLayout.values, layout);
    splitRatio = (j['splitRatio'] as num?)?.toDouble() ?? splitRatio;
    cameraOnTop = pick('cameraOnTop', cameraOnTop);
    bubbleSize = (j['bubbleSize'] as num?)?.toDouble() ?? bubbleSize;
    bubbleCorner = pickEnum('bubbleCorner', Corner.values, bubbleCorner);
    screenFit = pick('screenFit', screenFit);
    drawMouse = pick('drawMouse', drawMouse);
    screenRegion = ScreenRegion.fromJson(j['screenRegion']) ?? screenRegion;
    linkMode = pickEnum('linkMode', LinkMode.values, linkMode);
    wifiHost = pick('wifiHost', wifiHost);
  }
}
