import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'composer.dart';
import 'phone_link.dart';
import 'screen_source.dart';
import 'settings.dart';

/// Decodes a stream of JPEG frames and rebuilds with the newest image.
class JpegStreamView extends StatefulWidget {
  const JpegStreamView({
    super.key,
    required this.frames,
    required this.builder,
  });

  final Stream<Uint8List> frames;
  final Widget Function(BuildContext context, ui.Image? image) builder;

  @override
  State<JpegStreamView> createState() => _JpegStreamViewState();
}

class _JpegStreamViewState extends State<JpegStreamView> {
  StreamSubscription<Uint8List>? _sub;
  ui.Image? _image;
  bool _decoding = false;
  Uint8List? _pending;

  @override
  void initState() {
    super.initState();
    _sub = widget.frames.listen(_onFrame);
  }

  @override
  void didUpdateWidget(covariant JpegStreamView old) {
    super.didUpdateWidget(old);
    if (old.frames != widget.frames) {
      _sub?.cancel();
      _sub = widget.frames.listen(_onFrame);
    }
  }

  void _onFrame(Uint8List jpeg) {
    if (_decoding) {
      _pending = jpeg; // keep only the newest frame
      return;
    }
    _decode(jpeg);
  }

  Future<void> _decode(Uint8List jpeg) async {
    _decoding = true;
    try {
      final codec = await ui.instantiateImageCodec(jpeg);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      final old = _image;
      setState(() => _image = frame.image);
      old?.dispose();
    } catch (_) {
      // Ignore broken frames.
    } finally {
      _decoding = false;
      final next = _pending;
      _pending = null;
      if (next != null && mounted) _decode(next);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _image);
}

Widget _raw(ui.Image img) => SizedBox(
  width: img.width.toDouble(),
  height: img.height.toDouble(),
  child: RawImage(image: img, filterQuality: FilterQuality.medium),
);

/// Live 9:16 preview that mirrors exactly what the recorder will produce.
class ReelPreview extends StatelessWidget {
  const ReelPreview({
    super.key,
    required this.link,
    required this.settings,
    required this.screen,
  });

  final PhoneLink link;
  final RecorderSettings settings;
  final ScreenPreview screen;

  @override
  Widget build(BuildContext context) {
    final s = settings;
    final g = ReelGeometry.of(s);
    final connected = link.connected;

    return AspectRatio(
      aspectRatio: s.outWidth / s.outHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: LayoutBuilder(
          builder: (context, c) {
            final k = c.maxWidth / g.width;
            Rect r(Box b) => Rect.fromLTWH(b.x * k, b.y * k, b.w * k, b.h * k);

            final camera = JpegStreamView(
              frames: link.frames,
              builder: (context, img) => img == null || !connected
                  ? _cameraPlaceholder(compact: s.layout != ReelLayout.camera)
                  : _cameraContent(img),
            );

            final children = <Widget>[
              const ColoredBox(color: Color(0xFF0D0D10)),
            ];
            if (g.screen != null) {
              children.add(
                Positioned.fromRect(
                  rect: r(g.screen!),
                  child: JpegStreamView(
                    frames: screen.frames,
                    builder: (context, img) => img == null
                        ? _screenPlaceholder()
                        : FittedBox(
                            fit: s.screenFit ? BoxFit.contain : BoxFit.cover,
                            clipBehavior: Clip.hardEdge,
                            child: _raw(img),
                          ),
                  ),
                ),
              );
            }
            if (g.round) {
              final ring = g.ring * k;
              children.add(
                Positioned.fromRect(
                  rect: r(g.camera).inflate(ring),
                  child: Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                    padding: EdgeInsets.all(ring),
                    child: ClipOval(child: camera),
                  ),
                ),
              );
            } else {
              children.add(
                Positioned.fromRect(rect: r(g.camera), child: camera),
              );
            }
            if (s.grid) children.add(const _GridOverlay());
            if (s.safeZones) children.add(const _SafeZones());
            return Stack(fit: StackFit.expand, children: children);
          },
        ),
      ),
    );
  }

  Widget _cameraContent(ui.Image img) {
    final s = settings;
    Widget content;
    if (s.layout != ReelLayout.camera || s.framing == Framing.fill) {
      content = FittedBox(
        fit: BoxFit.cover,
        alignment: Alignment(s.cropX, s.cropY),
        clipBehavior: Clip.hardEdge,
        child: _raw(img),
      );
    } else {
      content = Stack(
        fit: StackFit.expand,
        children: [
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: _raw(img),
            ),
          ),
          FittedBox(fit: BoxFit.contain, child: _raw(img)),
        ],
      );
    }
    return s.mirror ? Transform.flip(flipX: true, child: content) : content;
  }

  Widget _cameraPlaceholder({required bool compact}) => Container(
    color: const Color(0xFF17171C),
    alignment: Alignment.center,
    padding: const EdgeInsets.all(12),
    child: compact
        ? const Icon(Icons.phone_iphone, size: 36, color: Colors.white24)
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.phone_iphone, size: 56, color: Colors.white24),
              const SizedBox(height: 12),
              Text(
                link.message.isEmpty ? 'iPhone ulanmagan' : link.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54),
              ),
            ],
          ),
  );

  Widget _screenPlaceholder() => Container(
    color: const Color(0xFF101014),
    alignment: Alignment.center,
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.desktop_windows, size: 40, color: Colors.white24),
        const SizedBox(height: 8),
        Text(
          screen.error ??
              (settings.screenRegion == null
                  ? 'Ekran hududini tanlang'
                  : 'Ekran yuklanmoqda…'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    ),
  );
}

class _GridOverlay extends StatelessWidget {
  const _GridOverlay();

  @override
  Widget build(BuildContext context) =>
      IgnorePointer(child: CustomPaint(painter: _GridPainter()));
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white38
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Approximate areas covered by the Instagram Reels / YouTube Shorts / TikTok
/// interface (caption, buttons, header). Keep faces and text out of them.
class _SafeZones extends StatelessWidget {
  const _SafeZones();

  @override
  Widget build(BuildContext context) {
    const shade = Color(0x55000000);
    const border = BorderSide(color: Color(0x88FF4D6D), width: 1);
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, c) {
          final h = c.maxHeight;
          final w = c.maxWidth;
          return Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: h * 0.11,
                child: Container(
                  decoration: const BoxDecoration(
                    color: shade,
                    border: Border(bottom: border),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: h * 0.21,
                child: Container(
                  decoration: const BoxDecoration(
                    color: shade,
                    border: Border(top: border),
                  ),
                  alignment: Alignment.topLeft,
                  padding: const EdgeInsets.all(6),
                  child: const Text(
                    'caption / UI',
                    style: TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: h * 0.45,
                bottom: h * 0.21,
                width: w * 0.14,
                child: Container(
                  decoration: const BoxDecoration(
                    color: shade,
                    border: Border(left: border),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
