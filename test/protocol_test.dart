import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glim/protocol.dart';
import 'package:glim/receiver/recorder.dart';
import 'package:glim/receiver/settings.dart';

void main() {
  test('parser reassembles packets split across chunks', () {
    final a = GlimProtocol.encode(GlimProtocol.kVideo, [1, 2, 3, 4, 5]);
    final audio = BytesBuilder()
      ..add([0, 0, 0xBB, 0x80, 1]) // 48000 Hz, mono
      ..add([10, 0, 20, 0]);
    final b = GlimProtocol.encode(GlimProtocol.kAudio, audio.toBytes());
    final c = GlimProtocol.encodeJson(GlimProtocol.kInfo, {'device': 'iPhone'});
    final all = [...a, ...b, ...c];

    final parser = GlimPacketParser();
    final out = <GlimPacket>[];
    for (var i = 0; i < all.length; i += 3) {
      out.addAll(parser.add(all.sublist(i, (i + 3).clamp(0, all.length))));
    }
    expect(out.length, 3);
    expect(out[0].type, GlimProtocol.kVideo);
    expect(out[0].payload, [1, 2, 3, 4, 5]);
    expect(out[1].audioSampleRate, 48000);
    expect(out[1].audioChannels, 1);
    expect(out[1].audioPcm, [10, 0, 20, 0]);
    expect(out[2].json['device'], 'iPhone');
  });

  test('parser rejects absurd sizes', () {
    final parser = GlimPacketParser();
    expect(
      () => parser.add([1, 0xFF, 0xFF, 0xFF, 0xFF]),
      throwsFormatException,
    );
  });

  test('reel filter', () {
    final f = buildReelFilter(
      width: 1080,
      height: 1920,
      framing: Framing.fill,
      mirror: true,
    );
    expect(f, contains('crop=1080:1920:(in_w-out_w)*0.500:(in_h-out_h)*0.500'));
    expect(f, contains('hflip'));
    final g = buildReelFilter(width: 720, height: 1280, framing: Framing.fit);
    expect(g, contains('overlay'));
  });
}
