import 'dart:convert';
import 'dart:typed_data';

/// Glim wire protocol (TCP, iPhone is the server, default port 8686).
///
/// Every packet is: [type: u8][length: u32 big-endian][payload: length bytes]
///
///  phone -> desktop
///   * [kVideo] one JPEG-encoded frame (already rotated to the capture
///     orientation, portrait by default)
///   * [kAudio] [sampleRate: u32 BE][channels: u8][PCM s16le interleaved]
///   * [kInfo]  UTF-8 JSON describing the phone state (cameras, size ...)
///
///  desktop -> phone
///   * [kCommand] UTF-8 JSON, e.g. {"cmd":"camera","id":"..."}
class GlimProtocol {
  static const int defaultPort = 8686;

  static const int kVideo = 1;
  static const int kAudio = 2;
  static const int kInfo = 3;
  static const int kCommand = 4;

  static const int headerSize = 5;

  /// Hard upper bound for a single packet, protects against garbage input.
  static const int maxPacket = 16 * 1024 * 1024;

  static Uint8List encode(int type, List<int> payload) {
    final out = Uint8List(headerSize + payload.length);
    out[0] = type;
    ByteData.sublistView(out).setUint32(1, payload.length, Endian.big);
    out.setRange(headerSize, out.length, payload);
    return out;
  }

  static Uint8List encodeJson(int type, Map<String, Object?> json) =>
      encode(type, utf8.encode(jsonEncode(json)));
}

class GlimPacket {
  GlimPacket(this.type, this.payload);

  final int type;
  final Uint8List payload;

  Map<String, dynamic> get json =>
      jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;

  /// For [GlimProtocol.kAudio] packets.
  int get audioSampleRate =>
      ByteData.sublistView(payload).getUint32(0, Endian.big);
  int get audioChannels => payload[4];
  Uint8List get audioPcm => Uint8List.sublistView(payload, 5);
}

/// Incremental packet parser: feed it arbitrary TCP chunks, get packets out.
class GlimPacketParser {
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);
  int _offset = 0;

  /// Throws [FormatException] if the stream is corrupt.
  List<GlimPacket> add(List<int> chunk) {
    if (_offset < _pending.length) {
      _buf.add(Uint8List.sublistView(_pending, _offset));
    }
    _buf.add(chunk);
    _pending = _buf.takeBytes();
    _offset = 0;

    final packets = <GlimPacket>[];
    final view = ByteData.sublistView(_pending);
    while (_pending.length - _offset >= GlimProtocol.headerSize) {
      final type = _pending[_offset];
      final len = view.getUint32(_offset + 1, Endian.big);
      if (len > GlimProtocol.maxPacket) {
        throw FormatException('Packet too large: $len bytes');
      }
      final end = _offset + GlimProtocol.headerSize + len;
      if (end > _pending.length) break;
      packets.add(
        GlimPacket(
          type,
          Uint8List.fromList(
            Uint8List.sublistView(
              _pending,
              _offset + GlimProtocol.headerSize,
              end,
            ),
          ),
        ),
      );
      _offset = end;
    }
    return packets;
  }

  void reset() {
    _buf.clear();
    _pending = Uint8List(0);
    _offset = 0;
  }
}
