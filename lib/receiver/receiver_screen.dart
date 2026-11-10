import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'composer.dart';
import 'phone_link.dart';
import 'preview.dart';
import 'recorder.dart';
import 'screen_source.dart';
import 'settings.dart';

/// Desktop (Ubuntu) side: receives the iPhone camera and records reels.
class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  final settings = RecorderSettings();
  final link = PhoneLink();
  final recorder = ReelRecorder();
  final vcam = VirtualCamera();
  final screenPreview = ScreenPreview();
  late final Listenable _all = Listenable.merge([
    settings,
    link,
    recorder,
    vcam,
    screenPreview,
  ]);
  List<ScreenRegion> monitors = [];
  bool hasSlop = true;
  StreamSubscription<FileSystemEvent>? _toggleWatch;

  bool hasFfmpeg = true;
  bool hasIproxy = true;
  int? countdownLeft;
  Timer? _countdownTimer;
  final _hostCtrl = TextEditingController();
  bool _wasConnected = false;

  @override
  void initState() {
    super.initState();
    link.addListener(_onLinkChange);
    _init();
  }

  Future<void> _init() async {
    await settings.load();
    _hostCtrl.text = settings.wifiHost;
    hasFfmpeg = await hasCommand('ffmpeg');
    hasIproxy = await hasCommand('iproxy');
    hasSlop = await hasCommand('slop');
    monitors = await ScreenCapture.listMonitors(settings.display);
    if (settings.screenRegion == null && monitors.isNotEmpty) {
      settings.screenRegion = monitors.first;
    }
    settings.addListener(_syncScreenPreview);
    _syncScreenPreview();
    _watchToggleFile();
    link
      ..mode = settings.linkMode
      ..host = settings.wifiHost;
    await link.start();
    if (mounted) setState(() {});
  }

  /// Runs the low-fps screen grabber only when a screen layout is active.
  void _syncScreenPreview() {
    final r = settings.screenRegion;
    if (settings.layout != ReelLayout.camera && r != null && r.isValid) {
      screenPreview.start(r, settings.display, drawMouse: settings.drawMouse);
    } else {
      screenPreview.stop();
    }
  }

  /// `glim-toggle` (bind it to a global shortcut) touches this file to
  /// start/stop recording while another window (your editor) has focus.
  void _watchToggleFile() {
    final dir = Directory(
      Platform.environment['XDG_RUNTIME_DIR'] ?? Directory.systemTemp.path,
    );
    try {
      _toggleWatch = dir.watch().listen((e) {
        if (!e.path.endsWith('/glim.toggle')) return;
        final f = File(e.path);
        if (e.type == FileSystemEvent.delete || !f.existsSync()) return;
        try {
          f.deleteSync();
        } catch (_) {}
        if (mounted) _toggleRecord();
      });
    } catch (_) {}
  }

  Future<void> _pickRegion() async {
    try {
      final r = await ScreenCapture.pickRegion(settings.display);
      if (r != null) settings.update(() => settings.screenRegion = r);
    } on ProcessException {
      _snack("Hudud tanlash uchun slop kerak: sudo apt install slop");
    }
  }

  void _onLinkChange() {
    final c = link.connected;
    if (c != _wasConnected) {
      _wasConnected = c;
      if (c && settings.virtualCam) vcam.start(link, settings);
      if (!c) {
        vcam.stop();
        // In screen layouts keep going (the last camera frame is held) —
        // a USB hiccup shouldn't ruin a coding session.
        if (recorder.recording && settings.layout == ReelLayout.camera) {
          recorder.stop().then(_onSaved);
        }
      }
    }
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    link.removeListener(_onLinkChange);
    _toggleWatch?.cancel();
    settings.removeListener(_syncScreenPreview);
    screenPreview.dispose();
    recorder.dispose();
    vcam.dispose();
    link.dispose();
    settings.dispose();
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _reconnect() async {
    await link.stop();
    link
      ..mode = settings.linkMode
      ..host = settings.wifiHost;
    await link.start();
  }

  void _toggleRecord() {
    if (countdownLeft != null) {
      _countdownTimer?.cancel();
      setState(() => countdownLeft = null);
      return;
    }
    if (recorder.recording) {
      recorder.stop().then(_onSaved);
      return;
    }
    if (recorder.state != RecorderState.idle) return;
    if (!link.connected || link.latestFrame == null) {
      _snack("iPhone ulanmagan — avval ulang");
      return;
    }
    if (!hasFfmpeg) {
      _snack("ffmpeg o'rnatilmagan: sudo apt install ffmpeg");
      return;
    }
    if (settings.countdown <= 0) {
      recorder.start(link, settings);
      return;
    }
    setState(() => countdownLeft = settings.countdown);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final left = (countdownLeft ?? 1) - 1;
      if (left <= 0) {
        t.cancel();
        setState(() => countdownLeft = null);
        recorder.start(link, settings);
      } else {
        setState(() => countdownLeft = left);
      }
    });
  }

  void _onSaved(String? path) {
    if (path != null) {
      _snack(
        'Saqlandi: $path',
        action: SnackBarAction(
          label: 'Ochish',
          onPressed: () => Process.run('xdg-open', [path]),
        ),
      );
    } else if (recorder.error != null) {
      _snack('Xato: ${recorder.error}');
    }
  }

  void _snack(String msg, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        action: action,
        duration: const Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): _toggleRecord,
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            _toggleRecord,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: AnimatedBuilder(
            animation: _all,
            builder: (context, _) => Row(
              children: [
                Expanded(child: _stage()),
                SizedBox(width: 360, child: _sidePanel()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- stage

  Widget _stage() {
    final rec = recorder.recording;
    return Container(
      color: const Color(0xFF0A0A0C),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                'Glim',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              ),
              const SizedBox(width: 8),
              const Text(
                'Reels Recorder',
                style: TextStyle(color: Colors.white54),
              ),
              const Spacer(),
              _statusPill(),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Center(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: rec ? Colors.redAccent : Colors.white12,
                        width: 2,
                      ),
                    ),
                    padding: const EdgeInsets.all(2),
                    child: ReelPreview(
                      link: link,
                      settings: settings,
                      screen: screenPreview,
                    ),
                  ),
                  if (rec) Positioned(top: 16, child: _recBadge()),
                  if (countdownLeft != null)
                    Text(
                      '$countdownLeft',
                      style: const TextStyle(
                        fontSize: 120,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        shadows: [Shadow(blurRadius: 24)],
                      ),
                    ),
                  if (recorder.state == RecorderState.finishing)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 12),
                            Text('Saqlanmoqda…'),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _recordBar(),
        ],
      ),
    );
  }

  Widget _statusPill() {
    final (color, text) = switch (link.state) {
      LinkState.connected => (
        Colors.greenAccent,
        '${link.deviceName.isEmpty ? 'iPhone' : link.deviceName} • '
            '${settings.linkMode == LinkMode.usb ? 'USB' : 'Wi-Fi'} • '
            '${link.fps} fps • ${link.mbps.toStringAsFixed(1)} Mbit/s',
      ),
      LinkState.connecting => (Colors.amberAccent, 'Ulanmoqda…'),
      LinkState.waitingDevice => (Colors.amberAccent, 'Kutilmoqda'),
      LinkState.error => (Colors.redAccent, 'Xato'),
      LinkState.idle => (Colors.white38, 'Ulanmagan'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Text(text, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _recBadge() {
    final max = settings.maxSeconds;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.redAccent,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '● REC ${_fmt(recorder.elapsed)}${max > 0 ? ' / ${_fmt(Duration(seconds: max))}' : ''}',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _recordBar() {
    final rec = recorder.recording;
    final max = settings.maxSeconds;
    return Column(
      children: [
        if (rec && max > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              width: 320,
              child: LinearProgressIndicator(
                value: (recorder.elapsed.inMilliseconds / (max * 1000)).clamp(
                  0,
                  1,
                ),
                color: Colors.redAccent,
              ),
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.filledTonal(
              tooltip: 'Papkani ochish',
              onPressed: () async {
                await Directory(settings.outputDir).create(recursive: true);
                Process.run('xdg-open', [settings.outputDir]);
              },
              icon: const Icon(Icons.folder_open),
            ),
            const SizedBox(width: 24),
            Tooltip(
              message: 'Yozish / to\'xtatish (Space)',
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _toggleRecord,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  padding: EdgeInsets.all(rec ? 18 : 6),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      borderRadius: BorderRadius.circular(rec ? 6 : 40),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 24),
            IconButton.filledTonal(
              tooltip: 'Oxirgi videoni ochish',
              onPressed: recorder.lastFile == null
                  ? null
                  : () => Process.run('xdg-open', [recorder.lastFile!]),
              icon: const Icon(Icons.play_arrow),
            ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------ side panel

  Widget _sidePanel() {
    final s = settings;
    final locked = recorder.state != RecorderState.idle;
    return Material(
      color: const Color(0xFF16161A),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!hasFfmpeg)
            _warning("ffmpeg topilmadi", 'sudo apt install ffmpeg'),
          if (!hasIproxy && s.linkMode == LinkMode.usb)
            _warning(
              "USB uchun iproxy topilmadi",
              'sudo apt install usbmuxd libimobiledevice-utils libusbmuxd-tools',
            ),
          _section('Ulanish', [
            SegmentedButton<LinkMode>(
              segments: const [
                ButtonSegment(
                  value: LinkMode.usb,
                  icon: Icon(Icons.usb),
                  label: Text('USB kabel'),
                ),
                ButtonSegment(
                  value: LinkMode.wifi,
                  icon: Icon(Icons.wifi),
                  label: Text('Wi-Fi'),
                ),
              ],
              selected: {s.linkMode},
              onSelectionChanged: locked
                  ? null
                  : (v) {
                      s.update(() => s.linkMode = v.first);
                      _reconnect();
                    },
            ),
            if (s.linkMode == LinkMode.wifi) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _hostCtrl,
                decoration: const InputDecoration(
                  labelText: 'iPhone IP manzili',
                  hintText: '192.168.1.23',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (v) {
                  s.update(() => s.wifiHost = v.trim());
                  _reconnect();
                },
              ),
            ],
            const SizedBox(height: 8),
            Text(
              link.message,
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: locked ? null : _reconnect,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Qayta ulanish'),
              ),
            ),
          ]),
          _layoutSection(locked),
          if (link.connected) _phoneSection(),
          _section('Format', [
            _segmented<String>(
              {'1080x1920': '1080×1920', '720x1280': '720×1280'},
              '${s.outWidth}x${s.outHeight}',
              locked
                  ? null
                  : (v) => s.update(() {
                      final p = v.split('x');
                      s.outWidth = int.parse(p[0]);
                      s.outHeight = int.parse(p[1]);
                    }),
            ),
            const SizedBox(height: 8),
            _segmented<int>(
              {30: '30 fps', 60: '60 fps'},
              s.fps,
              locked ? null : (v) => s.update(() => s.fps = v),
            ),
            const SizedBox(height: 8),
            _segmented<int>(
              {16: 'Yuqori', 20: "O'rta", 26: 'Kichik fayl'},
              s.crf,
              locked ? null : (v) => s.update(() => s.crf = v),
            ),
          ]),
          _section('Kadr (9:16)', [
            _segmented<Framing>(
              {
                Framing.fill: "To'ldirish (crop)",
                Framing.fit: 'Sig\'dirish (blur)',
              },
              s.framing,
              locked ? null : (v) => s.update(() => s.framing = v),
            ),
            if (s.framing == Framing.fill) ...[
              _slider(
                'Gorizontal',
                s.cropX,
                locked ? null : (v) => s.update(() => s.cropX = v),
              ),
              _slider(
                'Vertikal',
                s.cropY,
                locked ? null : (v) => s.update(() => s.cropY = v),
              ),
            ],
            _switch(
              'Ko\'zgu (mirror)',
              s.mirror,
              locked ? null : (v) => s.update(() => s.mirror = v),
            ),
            _switch(
              'Xavfsiz zonalar (IG / YT UI)',
              s.safeZones,
              (v) => s.update(() => s.safeZones = v),
            ),
            _switch(
              'To\'r (1/3 grid)',
              s.grid,
              (v) => s.update(() => s.grid = v),
            ),
          ]),
          _section('Ovoz', [
            _segmented<AudioSource>(
              {
                AudioSource.phone: 'iPhone mik',
                AudioSource.desktop: 'Kompyuter mik',
                AudioSource.none: "Yo'q",
              },
              s.audio,
              locked ? null : (v) => s.update(() => s.audio = v),
            ),
          ]),
          _section('Davomiylik', [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final sec in const [0, 15, 30, 60, 90, 180])
                  ChoiceChip(
                    label: Text(
                      sec == 0 ? 'Cheksiz' : _fmt(Duration(seconds: sec)),
                    ),
                    selected: s.maxSeconds == sec,
                    onSelected: locked
                        ? null
                        : (_) => s.update(() => s.maxSeconds = sec),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Taymer (boshlashdan oldin)',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                for (final c in const [0, 3, 5, 10])
                  ChoiceChip(
                    label: Text(c == 0 ? "O'chiq" : '$c s'),
                    selected: s.countdown == c,
                    onSelected: (_) => s.update(() => s.countdown = c),
                  ),
              ],
            ),
          ]),
          _section('Virtual veb-kamera (OBS, Zoom, Meet)', [
            _switch('v4l2loopback ga uzatish', s.virtualCam, (v) {
              s.update(() => s.virtualCam = v);
              if (v && link.connected) {
                vcam.start(link, s);
              } else {
                vcam.stop();
              }
            }),
            Text(
              vcam.error ??
                  (vcam.active
                      ? 'Faol: ${s.virtualCamDevice}'
                      : 'Qurilma: ${s.virtualCamDevice}'),
              style: TextStyle(
                fontSize: 12,
                color: vcam.error != null ? Colors.redAccent : Colors.white60,
              ),
            ),
          ]),
          _section('Saqlash joyi', [
            SelectableText(s.outputDir, style: const TextStyle(fontSize: 12)),
            if (recorder.lastFile != null) ...[
              const SizedBox(height: 6),
              Text(
                'Oxirgi: ${recorder.lastFile!.split('/').last}',
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ],
            if (recorder.error != null) ...[
              const SizedBox(height: 6),
              Text(
                recorder.error!,
                style: const TextStyle(fontSize: 12, color: Colors.redAccent),
              ),
            ],
          ]),
          const SizedBox(height: 8),
          const Text(
            'Space / Ctrl+R — yozishni boshlash / to\'xtatish',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  Widget _layoutSection(bool locked) {
    final s = settings;
    final g = ReelGeometry.of(s);
    final region = s.screenRegion;
    return _section('Rejim', [
      _segmented<ReelLayout>(
        {
          ReelLayout.camera: 'Kamera',
          ReelLayout.split: 'Split',
          ReelLayout.bubble: 'Doira',
        },
        s.layout,
        locked ? null : (v) => s.update(() => s.layout = v),
      ),
      if (s.layout != ReelLayout.camera) ...[
        if (ScreenCapture.isWayland)
          _warning(
            'Wayland sessiyasi: ekran qora chiqishi mumkin',
            "Chiqib, login ekranida ⚙ → 'Ubuntu on Xorg' ni tanlang",
          ),
        const SizedBox(height: 10),
        Text(
          'Ekran hududi: ${region ?? 'tanlanmagan'}',
          style: const TextStyle(fontSize: 12),
        ),
        if (g.screen != null)
          Text(
            'Ideal nisbat: ${_ratio(g.screen!.w, g.screen!.h)} '
            '(${g.screen!.w}×${g.screen!.h})',
            style: const TextStyle(fontSize: 11, color: Colors.white54),
          ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final m in monitors)
              ChoiceChip(
                label: Text('${m.label} ${m.w}×${m.h}'),
                selected: region?.toString() == m.toString(),
                onSelected: locked
                    ? null
                    : (_) => s.update(() => s.screenRegion = m),
              ),
            ActionChip(
              avatar: const Icon(Icons.crop_free, size: 16),
              label: const Text('Hududni belgilash'),
              onPressed: locked ? null : _pickRegion,
            ),
          ],
        ),
        if (!hasSlop)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: SelectableText(
              'sudo apt install slop',
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Colors.white54,
              ),
            ),
          ),
        const SizedBox(height: 8),
        _segmented<bool>(
          {true: "Sig'dirish (to'liq)", false: "To'ldirish (crop)"},
          s.screenFit,
          locked ? null : (v) => s.update(() => s.screenFit = v),
        ),
        if (s.layout == ReelLayout.split) ...[
          _labeledSlider(
            'Ekran ulushi ${(s.splitRatio * 100).round()}%',
            s.splitRatio,
            0.4,
            0.75,
            locked ? null : (v) => s.update(() => s.splitRatio = v),
          ),
          _switch(
            'Kamera tepada',
            s.cameraOnTop,
            locked ? null : (v) => s.update(() => s.cameraOnTop = v),
          ),
        ],
        if (s.layout == ReelLayout.bubble) ...[
          _labeledSlider(
            'Doira hajmi ${(s.bubbleSize * 100).round()}%',
            s.bubbleSize,
            0.25,
            0.55,
            locked ? null : (v) => s.update(() => s.bubbleSize = v),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (final c in Corner.values)
                ChoiceChip(
                  label: Text(switch (c) {
                    Corner.topLeft => '↖',
                    Corner.topRight => '↗',
                    Corner.bottomLeft => '↙',
                    Corner.bottomRight => '↘',
                  }),
                  selected: s.bubbleCorner == c,
                  onSelected: locked
                      ? null
                      : (_) => s.update(() => s.bubbleCorner = c),
                ),
            ],
          ),
        ],
        _switch(
          'Sichqonchani ko\'rsatish',
          s.drawMouse,
          locked ? null : (v) => s.update(() => s.drawMouse = v),
        ),
        const Text(
          "Maslahat: muharrirni hudud ichiga, Glim oynasini tashqariga qo'ying. "
          "Muharrirdan turib boshqarish uchun klaviatura yorlig'iga "
          "glim-toggle buyrug'ini biriktiring.",
          style: TextStyle(fontSize: 11, color: Colors.white38),
        ),
      ],
    ]);
  }

  Widget _labeledSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double>? onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(fontSize: 12)),
      Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
      ),
    ],
  );

  static String _ratio(int w, int h) {
    int gcd(int a, int b) => b == 0 ? a : gcd(b, a % b);
    final r = w / h;
    for (final (a, b) in const [
      (16, 9),
      (4, 3),
      (1, 1),
      (3, 4),
      (9, 16),
      (3, 2),
      (2, 3),
    ]) {
      if ((r - a / b).abs() < 0.02) return '$a:$b';
    }
    final d = gcd(w, h);
    return r >= 1
        ? '${(r).toStringAsFixed(2)}:1 (${w ~/ d}:${h ~/ d})'
        : '1:${(1 / r).toStringAsFixed(2)}';
  }

  Widget _phoneSection() {
    return _section('iPhone kamerasi', [
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final c in link.cameras)
            ChoiceChip(
              label: Text(c.name),
              selected: c.id == link.cameraId,
              onSelected: (_) => link.selectCamera(c.id),
            ),
        ],
      ),
      if (link.maxZoom > 1)
        Row(
          children: [
            const Icon(Icons.zoom_in, size: 18),
            Expanded(
              child: Slider(
                value: link.zoom.clamp(1, link.maxZoom),
                min: 1,
                max: link.maxZoom,
                onChanged: link.setZoom,
              ),
            ),
            Text('${link.zoom.toStringAsFixed(1)}×'),
          ],
        ),
      if (link.hasTorch) _switch('Chiroq (torch)', link.torch, link.setTorch),
      if (link.frameWidth > 0)
        Text(
          'Manba: ${link.frameWidth}×${link.frameHeight}',
          style: const TextStyle(fontSize: 12, color: Colors.white60),
        ),
    ]);
  }

  // -------------------------------------------------------------- helpers

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 1.1,
            fontWeight: FontWeight.w700,
            color: Colors.white54,
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );

  Widget _warning(String title, String cmd) => Card(
    color: const Color(0xFF3A1D1D),
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          SelectableText(
            cmd,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    ),
  );

  Widget _segmented<T>(
    Map<T, String> options,
    T value,
    ValueChanged<T>? onChanged,
  ) => SegmentedButton<T>(
    showSelectedIcon: false,
    segments: [
      for (final e in options.entries)
        ButtonSegment<T>(
          value: e.key,
          label: Text(e.value, style: const TextStyle(fontSize: 12)),
        ),
    ],
    selected: {value},
    onSelectionChanged: onChanged == null ? null : (v) => onChanged(v.first),
  );

  Widget _slider(String label, double value, ValueChanged<double>? onChanged) =>
      Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Slider(value: value, min: -1, max: 1, onChanged: onChanged),
          ),
        ],
      );

  Widget _switch(String label, bool value, ValueChanged<bool>? onChanged) =>
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label, style: const TextStyle(fontSize: 13)),
        value: value,
        onChanged: onChanged,
      );

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
