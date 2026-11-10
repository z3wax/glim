import 'package:flutter_test/flutter_test.dart';
import 'package:glim/receiver/composer.dart';
import 'package:glim/receiver/screen_source.dart';
import 'package:glim/receiver/settings.dart';

void main() {
  test('split geometry fills the frame without gaps', () {
    final s = RecorderSettings()
      ..layout = ReelLayout.split
      ..splitRatio = 0.6;
    final g = ReelGeometry.of(s);
    expect(g.screen!.y, 0);
    expect(g.screen!.h + g.camera.h, 1920);
    expect(g.camera.y, g.screen!.h);
    expect(g.screen!.h.isEven, isTrue);

    s.cameraOnTop = true;
    final t = ReelGeometry.of(s);
    expect(t.camera.y, 0);
    expect(t.screen!.y, t.camera.h);
  });

  test('bubble stays inside the frame in every corner', () {
    for (final c in Corner.values) {
      final s = RecorderSettings()
        ..layout = ReelLayout.bubble
        ..bubbleCorner = c;
      final g = ReelGeometry.of(s);
      expect(g.round, isTrue);
      expect(g.camera.x - g.ring, greaterThanOrEqualTo(0));
      expect(g.camera.y - g.ring, greaterThanOrEqualTo(0));
      expect(g.camera.x + g.camera.w + g.ring, lessThanOrEqualTo(1080));
      expect(g.camera.y + g.camera.h + g.ring, lessThanOrEqualTo(1920));
    }
  });

  test('compose filters', () {
    final s = RecorderSettings()..layout = ReelLayout.split;
    expect(buildComposeFilter(s, cameraOnly: 'x'), contains('vstack'));
    s.layout = ReelLayout.bubble;
    final f = buildComposeFilter(s, cameraOnly: 'x');
    expect(f, contains('alphamerge'));
    expect(f, endsWith('[v]'));
    s.layout = ReelLayout.camera;
    expect(buildComposeFilter(s, cameraOnly: 'x'), '[0:v]x[v]');
  });

  test('circle mask', () {
    final m = circleMaskPgm(64);
    expect(String.fromCharCodes(m.sublist(0, 2)), 'P5');
    final header = 'P5\n64 64\n255\n'.length;
    expect(m[header], 0); // corner transparent
    expect(m[header + 32 * 64 + 32], 255); // centre opaque
  });

  test('xrandr monitors', () {
    const out =
        'Monitors: 2\n'
        ' 0: +*eDP-1 1920/344x1080/194+0+0  eDP-1\n'
        ' 1: +HDMI-1 2560/597x1440/336+1920+0  HDMI-1\n';
    final m = ScreenCapture.parseXrandrMonitors(out);
    expect(m.length, 2);
    expect(m[1].x, 1920);
    expect(m[1].w, 2560);
    expect(m[1].label, 'HDMI-1');
  });

  test('jpeg splitter', () {
    final sp = JpegStreamSplitter();
    expect(sp.add([0xFF, 0xD8, 1, 2, 0xFF]), isEmpty);
    final out = sp.add([0xD9, 0xFF, 0xD8, 3, 0xFF, 0xD9]);
    expect(out.length, 2);
    expect(out[0], [0xFF, 0xD8, 1, 2, 0xFF, 0xD9]);
  });
}
