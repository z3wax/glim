// Simulates the iPhone app for testing the desktop recorder without a phone.
//
//   dart run tool/fake_phone.dart [port]
//
// Then choose "Wi-Fi" in the desktop app and connect to 127.0.0.1.
// Needs ffmpeg (generates a 720x1280 test pattern + a 440 Hz tone).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:glim/protocol.dart';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : GlimProtocol.defaultPort;
  final server = await serveFakePhone(port);
  stdout.writeln('Fake iPhone listening on ${server.port}');
}

Future<ServerSocket> serveFakePhone(int port, {int fps = 30}) async {
  final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
  server.listen((client) => _serveClient(client, fps), onError: (_) {});
  return server;
}

Future<void> _serveClient(Socket client, int fps) async {
  // Writes after the desktop disconnects fail asynchronously; ignore them.
  client.done.catchError((Object _) {});
  {
    client.setOption(SocketOption.tcpNoDelay, true);
    client.add(
      GlimProtocol.encodeJson(GlimProtocol.kInfo, {
        'device': 'Fake iPhone',
        'cameras': [
          {'id': 'back', 'name': 'Back Camera', 'front': false},
          {'id': 'front', 'name': 'Front Camera', 'front': true},
        ],
        'camera': 'back',
        'width': 720,
        'height': 1280,
        'zoom': 1.0,
        'maxZoom': 5.0,
        'hasTorch': true,
        'torch': false,
      }),
    );

    final video = await Process.start('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-re',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=720x1280:rate=$fps',
      '-f',
      'image2pipe',
      '-c:v',
      'mjpeg',
      '-q:v',
      '5',
      '-',
    ]);
    final audio = await Process.start('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-re',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=44100',
      '-f',
      's16le',
      '-ac',
      '1',
      '-',
    ]);

    var closed = false;
    void close() {
      if (closed) return;
      closed = true;
      video.kill();
      audio.kill();
      client.destroy();
    }

    client.listen((_) {}, onDone: close, onError: (_) => close());
    client.done.then((_) => close(), onError: (_) => close());

    // Split the MJPEG byte stream on SOI/EOI markers.
    final buf = BytesBuilder(copy: false);
    video.stdout.listen((chunk) {
      buf.add(chunk);
      var data = buf.takeBytes();
      var start = 0;
      for (var i = 1; i < data.length; i++) {
        if (data[i - 1] == 0xFF && data[i] == 0xD9) {
          final frame = Uint8List.sublistView(data, start, i + 1);
          if (!closed) {
            client.add(GlimProtocol.encode(GlimProtocol.kVideo, frame));
          }
          start = i + 1;
        }
      }
      buf.add(Uint8List.sublistView(data, start));
    });
    audio.stdout.listen((chunk) {
      final header = ByteData(5)
        ..setUint32(0, 44100)
        ..setUint8(4, 1);
      if (!closed) {
        client.add(
          GlimProtocol.encode(GlimProtocol.kAudio, [
            ...header.buffer.asUint8List(),
            ...chunk,
          ]),
        );
      }
    });
  }
}
