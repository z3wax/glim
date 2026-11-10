import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glim/receiver/phone_link.dart';
import 'package:glim/receiver/recorder.dart';
import 'package:glim/receiver/settings.dart';

import '../tool/fake_phone.dart';

void main() {
  test('records a 9:16 reel with audio from a fake phone', () async {
    if (!await hasCommand('ffmpeg')) {
      markTestSkipped('ffmpeg not installed');
      return;
    }
    final server = await serveFakePhone(0);
    final out = await Directory.systemTemp.createTemp('glim_test_');
    final link = PhoneLink()
      ..mode = LinkMode.wifi
      ..host = '127.0.0.1'
      ..port = server.port;
    final settings = RecorderSettings()
      ..outputDir = out.path
      ..outWidth = 720
      ..outHeight = 1280
      ..framing = Framing.fit
      ..audio = AudioSource.phone;
    final recorder = ReelRecorder();
    try {
      await link.start();
      for (var i = 0; i < 50 && link.latestFrame == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(link.connected, isTrue);
      expect(link.deviceName, 'Fake iPhone');

      await recorder.start(link, settings);
      await Future<void>.delayed(const Duration(seconds: 3));
      final path = await recorder.stop();
      expect(recorder.error, isNull);
      expect(path, isNotNull);

      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'stream=codec_type,codec_name,width,height:format=duration',
        '-of',
        'default=nw=1',
        path!,
      ]);
      final info = probe.stdout as String;
      expect(info, contains('codec_name=h264'));
      expect(info, contains('width=720'));
      expect(info, contains('height=1280'));
      expect(info, contains('codec_name=aac'));
      final dur = double.parse(
        RegExp(r'duration=([\d.]+)').firstMatch(info)!.group(1)!,
      );
      expect(dur, inInclusiveRange(2.5, 3.6));
    } finally {
      await link.stop();
      link.dispose();
      await server.close();
      await out.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
