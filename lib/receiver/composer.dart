import 'dart:math' as math;
import 'dart:typed_data';

import 'settings.dart';

/// Integer rectangle in output (reel) pixels.
class Box {
  const Box(this.x, this.y, this.w, this.h);
  final int x;
  final int y;
  final int w;
  final int h;

  @override
  String toString() => 'Box($x,$y ${w}x$h)';
}

int _even(num v) => (v / 2).round() * 2;

/// Where the screen and the camera go inside the W×H reel. Shared by the
/// Flutter preview and the ffmpeg filter so both always match.
class ReelGeometry {
  ReelGeometry._(
    this.width,
    this.height,
    this.screen,
    this.camera,
    this.round,
    this.ring,
  );

  final int width;
  final int height;

  /// Null in [ReelLayout.camera].
  final Box? screen;
  final Box camera;

  /// Camera is drawn as a circle.
  final bool round;

  /// White ring width around the bubble.
  final int ring;

  factory ReelGeometry.of(RecorderSettings s) {
    final w = s.outWidth;
    final h = s.outHeight;
    switch (s.layout) {
      case ReelLayout.camera:
        return ReelGeometry._(w, h, null, Box(0, 0, w, h), false, 0);
      case ReelLayout.split:
        final sh = _even(h * s.splitRatio.clamp(0.3, 0.8));
        final ch = h - sh;
        return s.cameraOnTop
            ? ReelGeometry._(
                w,
                h,
                Box(0, ch, w, sh),
                Box(0, 0, w, ch),
                false,
                0,
              )
            : ReelGeometry._(
                w,
                h,
                Box(0, 0, w, sh),
                Box(0, sh, w, ch),
                false,
                0,
              );
      case ReelLayout.bubble:
        final d = _even(w * s.bubbleSize.clamp(0.2, 0.6));
        final margin = _even(w * 0.05);
        final ring = math.max(2, _even(w * 0.006));
        final left =
            s.bubbleCorner == Corner.topLeft ||
            s.bubbleCorner == Corner.bottomLeft;
        final top =
            s.bubbleCorner == Corner.topLeft ||
            s.bubbleCorner == Corner.topRight;
        final x = left ? margin : w - d - margin;
        // Stay clear of the Reels/Shorts header (~11%) and caption (~21%).
        final y = top ? _even(h * 0.12) : _even(h * 0.78) - d;
        return ReelGeometry._(
          w,
          h,
          Box(0, 0, w, h),
          Box(x, y, d, d),
          true,
          ring,
        );
    }
  }
}

String _pos(double v) => ((v.clamp(-1.0, 1.0) + 1) / 2).toStringAsFixed(3);

/// Scales/crops the camera into a w×h box (always "fill").
String cameraChain(RecorderSettings s, int w, int h) =>
    'scale=$w:$h:force_original_aspect_ratio=increase,'
    'crop=$w:$h:(in_w-out_w)*${_pos(s.cropX)}:(in_h-out_h)*${_pos(s.cropY)}'
    '${s.mirror ? ',hflip' : ''},setsar=1';

/// Scales the screen capture into a w×h box.
String screenChain(RecorderSettings s, int w, int h) => s.screenFit
    ? 'scale=$w:$h:force_original_aspect_ratio=decrease:force_divisible_by=2,'
          'pad=$w:$h:(ow-iw)/2:(oh-ih)/2:color=0x0d0d10,setsar=1'
    : 'scale=$w:$h:force_original_aspect_ratio=increase,crop=$w:$h,setsar=1';

/// Builds the ffmpeg `-filter_complex` graph producing `[v]`.
///
/// Inputs: 0 = camera (MJPEG pipe), 1 = screen (x11grab),
/// 2 = circle mask (grayscale image, looped) for [ReelLayout.bubble].
/// [cameraOnly] is the single-input filter used for [ReelLayout.camera].
String buildComposeFilter(RecorderSettings s, {required String cameraOnly}) {
  final g = ReelGeometry.of(s);
  final fw = g.width;
  final fh = g.height;
  switch (s.layout) {
    case ReelLayout.camera:
      return '[0:v]$cameraOnly[v]';
    case ReelLayout.split:
      final scr = g.screen!;
      final cam = g.camera;
      final top = s.cameraOnTop ? '[cam][scr]' : '[scr][cam]';
      return '[1:v]${screenChain(s, scr.w, scr.h)},format=yuv420p[scr];'
          '[0:v]${cameraChain(s, cam.w, cam.h)},format=yuv420p[cam];'
          '${top}vstack=inputs=2:shortest=1,format=yuv420p[v]';
    case ReelLayout.bubble:
      final c = g.camera;
      final r = c.w + g.ring * 2;
      return '[1:v]${screenChain(s, fw, fh)},format=yuv420p[bg];'
          '[2:v]split=2[m1][m2];'
          '[m1]scale=${c.w}:${c.h},format=gray[m];'
          '[m2]scale=$r:$r,format=gray[rm];'
          'color=c=white:s=${r}x$r:r=${s.fps},format=yuva420p[rc];'
          '[rc][rm]alphamerge=shortest=1[ring];'
          '[0:v]${cameraChain(s, c.w, c.h)},format=yuva420p[c];'
          '[c][m]alphamerge=shortest=1[cm];'
          '[bg][ring]overlay=${c.x - g.ring}:${c.y - g.ring}[bg2];'
          '[bg2][cm]overlay=${c.x}:${c.y}:shortest=1,format=yuv420p[v]';
  }
}

/// Anti-aliased circle mask as a binary PGM image.
Uint8List circleMaskPgm([int size = 512]) {
  final header = 'P5\n$size $size\n255\n'.codeUnits;
  final out = Uint8List(header.length + size * size);
  out.setRange(0, header.length, header);
  final r = size / 2;
  var i = header.length;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = x + 0.5 - r;
      final dy = y + 0.5 - r;
      final d = math.sqrt(dx * dx + dy * dy);
      out[i++] = ((r - d).clamp(0.0, 1.0) * 255).round();
    }
  }
  return out;
}
