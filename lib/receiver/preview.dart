import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'phone_link.dart';
import 'settings.dart';

/// Live 9:16 preview that mirrors exactly what the recorder will produce.
class ReelPreview extends StatefulWidget {
  const ReelPreview({super.key, required this.link, required this.settings});

  final PhoneLink link;
  final RecorderSettings settings;

  @override
  State<ReelPreview> createState() => _ReelPreviewState();
}

class _ReelPreviewState extends State<ReelPreview> {
  StreamSubscription<Uint8List>? _sub;
  ui.Image? _image;
  bool _decoding = false;
  Uint8List? _pending;

  @override
  void initState() {
    super.initState();
    _sub = widget.link.frames.listen(_onFrame);
  }

  @override
  void didUpdateWidget(covariant ReelPreview old) {
    super.didUpdateWidget(old);
    if (old.link != widget.link) {
      _sub?.cancel();
      _sub = widget.link.frames.listen(_onFrame);
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
  Widget build(BuildContext context) {
    final s = widget.settings;
    final img = _image;
    final connected = widget.link.connected;

    Widget content;
    if (img == null || !connected) {
      content = Container(
        color: const Color(0xFF111114),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.phone_iphone, size: 56, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              widget.link.message.isEmpty
                  ? 'iPhone ulanmagan'
                  : widget.link.message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      );
    } else {
      final raw = SizedBox(
        width: img.width.toDouble(),
        height: img.height.toDouble(),
        child: RawImage(image: img, filterQuality: FilterQuality.medium),
      );
      if (s.framing == Framing.fill) {
        content = FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment(s.cropX, s.cropY),
          clipBehavior: Clip.hardEdge,
          child: raw,
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
                child: raw,
              ),
            ),
            FittedBox(fit: BoxFit.contain, child: raw),
          ],
        );
      }
      if (s.mirror) {
        content = Transform.flip(flipX: true, child: content);
      }
    }

    return AspectRatio(
      aspectRatio: s.outWidth / s.outHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          fit: StackFit.expand,
          children: [
            content,
            if (s.grid) const _GridOverlay(),
            if (s.safeZones && img != null && connected) const _SafeZones(),
          ],
        ),
      ),
    );
  }
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
