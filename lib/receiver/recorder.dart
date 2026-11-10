import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../protocol.dart';
import 'composer.dart';
import 'phone_link.dart';
import 'screen_source.dart';
import 'settings.dart';

/// Builds the ffmpeg video filter that turns the phone picture into a
/// vertical W×H reel (fill = crop, fit = blurred background).
String buildReelFilter({
  required int width,
  required int height,
  required Framing framing,
  double cropX = 0,
  double cropY = 0,
  bool mirror = false,
}) {
  String f(double v) => ((v.clamp(-1.0, 1.0) + 1) / 2).toStringAsFixed(3);
  final flip = mirror ? ',hflip' : '';
  if (framing == Framing.fill) {
    return 'scale=$width:$height:force_original_aspect_ratio=increase,'
        'crop=$width:$height:(in_w-out_w)*${f(cropX)}:(in_h-out_h)*${f(cropY)}'
        '$flip,setsar=1,format=yuv420p';
  }
  return 'split=2[bg][fg];'
      '[bg]scale=$width:$height:force_original_aspect_ratio=increase,'
      'crop=$width:$height,boxblur=luma_radius=30:luma_power=2[bgb];'
      '[fg]scale=$width:$height:force_original_aspect_ratio=decrease:'
      'force_divisible_by=2[fgs];'
      '[bgb][fgs]overlay=(W-w)/2:(H-h)/2$flip,setsar=1,format=yuv420p';
}

/// Checks whether a command line tool is available.
Future<bool> hasCommand(String cmd) async {
  try {
    final r = await Process.run('which', [cmd]);
    return r.exitCode == 0;
  } catch (_) {
    return false;
  }
}

enum RecorderState { idle, recording, finishing }

/// Records the phone stream into an MP4 (H.264 + AAC) reel using ffmpeg.
///
/// Video: JPEG frames are written to ffmpeg's stdin at a constant frame rate
/// driven by the wall clock (the latest frame is repeated / dropped), so the
/// result stays in sync with audio even if the phone's frame rate varies.
/// Audio: raw PCM from the iPhone, or the desktop's default PulseAudio /
/// PipeWire source. Both are muxed together when recording stops.
class ReelRecorder extends ChangeNotifier {
  RecorderState state = RecorderState.idle;
  Duration elapsed = Duration.zero;
  String? lastFile;
  String? error;

  Process? _video;
  Process? _desktopAudio;
  IOSink? _phoneAudioSink;
  StreamSubscription<GlimPacket>? _audioSub;
  Timer? _ticker;
  final _clock = Stopwatch();
  int _framesWritten = 0;
  Uint8List? _lastFrame;
  Directory? _tmp;
  int _audioRate = 0;
  int _audioChannels = 0;
  AudioSource _audioSource = AudioSource.none;
  late RecorderSettings _settings;
  PhoneLink? _link;
  final _stderr = StringBuffer();

  bool get recording => state == RecorderState.recording;

  Future<void> start(PhoneLink link, RecorderSettings s) async {
    if (state != RecorderState.idle) return;
    error = null;
    _settings = s;
    _link = link;
    _framesWritten = 0;
    _lastFrame = null;
    _audioRate = 0;
    _audioChannels = 0;
    _stderr.clear();
    _audioSource = s.audio;

    try {
      _tmp = await Directory.systemTemp.createTemp('glim_');
      final videoPath = '${_tmp!.path}/video.mp4';
      final cameraOnly = buildReelFilter(
        width: s.outWidth,
        height: s.outHeight,
        framing: s.framing,
        cropX: s.cropX,
        cropY: s.cropY,
        mirror: s.mirror,
      );

      final extraInputs = <String>[];
      if (s.layout != ReelLayout.camera) {
        final region = s.screenRegion;
        if (region == null || !region.isValid) {
          throw Exception('Ekran hududi tanlanmagan');
        }
        extraInputs.addAll(
          ScreenCapture.x11grabInput(
            region,
            display: s.display,
            fps: s.fps,
            drawMouse: s.drawMouse,
          ),
        );
        if (s.layout == ReelLayout.bubble) {
          final mask = File('${_tmp!.path}/mask.pgm');
          await mask.writeAsBytes(circleMaskPgm());
          extraInputs.addAll([
            '-loop',
            '1',
            '-framerate',
            '${s.fps}',
            '-i',
            mask.path,
          ]);
        }
      }

      _video = await Process.start('ffmpeg', [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-thread_queue_size', '512',
        // Don't probe the pipe for seconds: inputs are opened in order, so a
        // long probe would start the screen grab late (screen ahead of face).
        '-probesize', '32', '-analyzeduration', '0',
        '-f', 'image2pipe', '-framerate', '${s.fps}', '-c:v', 'mjpeg',
        '-i', '-',
        ...extraInputs,
        '-filter_complex', buildComposeFilter(s, cameraOnly: cameraOnly),
        '-map', '[v]',
        // Code/text needs a bit more bitrate than a face to stay crisp.
        '-c:v', 'libx264', '-preset', 'veryfast',
        '-crf', '${s.layout == ReelLayout.camera ? s.crf : s.crf - 2}',
        '-profile:v', 'high', '-pix_fmt', 'yuv420p',
        '-r', '${s.fps}', '-g', '${s.fps * 2}',
        videoPath,
      ]);
      _video!.stderr
          .transform(const SystemEncoding().decoder)
          .listen(_stderr.write);
      _video!.stdin.done.catchError((Object _) {});

      if (_audioSource == AudioSource.phone) {
        _phoneAudioSink = File('${_tmp!.path}/audio.pcm').openWrite();
        _audioSub = link.audio.listen((p) {
          if (_audioRate == 0) {
            _audioRate = p.audioSampleRate;
            _audioChannels = p.audioChannels;
          }
          if (p.audioSampleRate == _audioRate &&
              p.audioChannels == _audioChannels) {
            _phoneAudioSink?.add(p.audioPcm);
          }
        });
      } else if (_audioSource == AudioSource.desktop) {
        _desktopAudio = await Process.start('ffmpeg', [
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-f',
          'pulse',
          '-i',
          'default',
          '-ac',
          '2',
          '-ar',
          '48000',
          '-c:a',
          'pcm_s16le',
          '${_tmp!.path}/audio.wav',
        ]);
        _desktopAudio!.stdout.drain<void>();
        _desktopAudio!.stderr
            .transform(const SystemEncoding().decoder)
            .listen(_stderr.write);
      }

      state = RecorderState.recording;
      elapsed = Duration.zero;
      _clock
        ..reset()
        ..start();
      final tick = Duration(microseconds: (1e6 / s.fps / 2).round());
      _ticker = Timer.periodic(tick, (_) => _onTick());
      notifyListeners();
    } catch (e) {
      error = 'Yozishni boshlab bo\'lmadi: $e';
      await _cleanupProcesses();
      state = RecorderState.idle;
      notifyListeners();
    }
  }

  void _onTick() {
    if (state != RecorderState.recording) return;
    // Keep repeating the last frame if the phone drops out for a moment.
    final frame = _lastFrame = _link?.latestFrame ?? _lastFrame;
    final due = (_clock.elapsedMicroseconds * _settings.fps / 1e6).floor();
    if (frame != null && _framesWritten < due) {
      // Repeat the latest frame for every slot that is due (handles phone
      // frame drops); a slower phone never desyncs the timeline.
      _writeRepeated(frame, due - _framesWritten);
    }
    final newElapsed = Duration(microseconds: _clock.elapsedMicroseconds);
    if (newElapsed.inMilliseconds ~/ 100 != elapsed.inMilliseconds ~/ 100) {
      elapsed = newElapsed;
      notifyListeners();
    }
    final max = _settings.maxSeconds;
    if (max > 0 && _clock.elapsed.inMilliseconds >= max * 1000) {
      stop();
    }
  }

  void _writeRepeated(Uint8List frame, int count) {
    for (var i = 0; i < count; i++) {
      try {
        _video?.stdin.add(frame);
      } catch (_) {}
    }
    _framesWritten += count;
  }

  /// Stops recording and returns the path of the finished file.
  Future<String?> stop() async {
    if (state != RecorderState.recording) return null;
    state = RecorderState.finishing;
    _ticker?.cancel();
    _clock.stop();
    notifyListeners();

    final tmp = _tmp!;
    String? out;
    try {
      // Pad the video up to the exact wall-clock length.
      final frame = _lastFrame;
      final due = (_clock.elapsedMicroseconds * _settings.fps / 1e6).floor();
      if (frame != null && _framesWritten < due) {
        _writeRepeated(frame, due - _framesWritten);
      }

      await _video?.stdin.close();
      final videoCode = await _video?.exitCode;
      _video = null;

      await _audioSub?.cancel();
      _audioSub = null;
      await _phoneAudioSink?.close();
      _phoneAudioSink = null;

      if (_desktopAudio != null) {
        _desktopAudio!.stdin.writeln('q');
        await _desktopAudio!.stdin.flush().catchError((Object _) {});
        await _desktopAudio!.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            _desktopAudio?.kill(ProcessSignal.sigint);
            return -1;
          },
        );
        _desktopAudio = null;
      }

      final videoFile = File('${tmp.path}/video.mp4');
      if (videoCode != 0 || !await videoFile.exists()) {
        throw Exception(
          'ffmpeg xatosi ($videoCode): ${_stderr.toString().trim()}',
        );
      }

      final dir = Directory(_settings.outputDir);
      await dir.create(recursive: true);
      out = '${dir.path}/${_fileName()}';

      List<String>? audioInput;
      if (_audioSource == AudioSource.phone && _audioRate > 0) {
        final pcm = File('${tmp.path}/audio.pcm');
        if (await pcm.exists() && await pcm.length() > 0) {
          audioInput = [
            '-f',
            's16le',
            '-ar',
            '$_audioRate',
            '-ac',
            '$_audioChannels',
            '-i',
            pcm.path,
          ];
        }
      } else if (_audioSource == AudioSource.desktop) {
        final wav = File('${tmp.path}/audio.wav');
        if (await wav.exists() && await wav.length() > 44) {
          audioInput = ['-i', wav.path];
        }
      }

      final args = <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-i',
        videoFile.path,
        if (audioInput != null) ...[
          ...audioInput,
          '-map',
          '0:v:0',
          '-map',
          '1:a:0',
          '-c:v',
          'copy',
          '-af',
          'apad',
          '-c:a',
          'aac',
          '-b:a',
          '192k',
          '-ar',
          '48000',
          '-shortest',
        ] else ...[
          '-c',
          'copy',
        ],
        '-movflags',
        '+faststart',
        out,
      ];
      final r = await Process.run('ffmpeg', args);
      if (r.exitCode != 0) {
        throw Exception('ffmpeg mux xatosi: ${r.stderr}');
      }
      lastFile = out;
    } catch (e) {
      error = e.toString();
      out = null;
      await _cleanupProcesses();
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
      _tmp = null;
      state = RecorderState.idle;
      notifyListeners();
    }
    return out;
  }

  String _fileName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'glim_reel_${n.year}${two(n.month)}${two(n.day)}_'
        '${two(n.hour)}${two(n.minute)}${two(n.second)}.mp4';
  }

  Future<void> _cleanupProcesses() async {
    _ticker?.cancel();
    _video?.kill();
    _video = null;
    _desktopAudio?.kill();
    _desktopAudio = null;
    await _audioSub?.cancel();
    _audioSub = null;
    await _phoneAudioSink?.close();
    _phoneAudioSink = null;
  }

  @override
  void dispose() {
    _cleanupProcesses();
    super.dispose();
  }
}

/// Feeds the stream into a v4l2loopback device so OBS, Zoom, Chrome, etc.
/// can use the iPhone as a regular Linux webcam.
class VirtualCamera extends ChangeNotifier {
  Process? _proc;
  StreamSubscription<Uint8List>? _sub;
  String? error;
  bool get active => _proc != null;

  Future<void> start(PhoneLink link, RecorderSettings s) async {
    await stop();
    error = null;
    if (!await File(s.virtualCamDevice).exists()) {
      error =
          '${s.virtualCamDevice} topilmadi. v4l2loopback modulini yuklang:\n'
          'sudo modprobe v4l2loopback devices=1 video_nr=10 '
          'card_label="Glim iPhone" exclusive_caps=1';
      notifyListeners();
      return;
    }
    try {
      final p = await Process.start('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'image2pipe',
        '-c:v',
        'mjpeg',
        '-i',
        '-',
        '-vf',
        buildReelFilter(
          width: s.outWidth == 1080 ? 720 : s.outWidth,
          height: s.outWidth == 1080 ? 1280 : s.outHeight,
          framing: s.framing,
          cropX: s.cropX,
          cropY: s.cropY,
          mirror: s.mirror,
        ),
        '-f',
        'v4l2',
        s.virtualCamDevice,
      ]);
      p.stdin.done.catchError((Object _) {});
      final err = StringBuffer();
      p.stderr.transform(const SystemEncoding().decoder).listen(err.write);
      _proc = p;
      _sub = link.frames.listen((f) {
        try {
          _proc?.stdin.add(f);
        } catch (_) {}
      });
      unawaited(
        p.exitCode.then((code) {
          if (_proc == p) {
            _proc = null;
            _sub?.cancel();
            _sub = null;
            if (code != 0) {
              error = 'Virtual kamera to\'xtadi: ${err.toString().trim()}';
            }
            notifyListeners();
          }
        }),
      );
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    final p = _proc;
    _proc = null;
    if (p != null) {
      try {
        await p.stdin.close();
      } catch (_) {}
      p.kill();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
