import 'dart:io';

import 'package:flutter/material.dart';

import '../protocol.dart';
import 'camera_bridge.dart';

/// iPhone side: camera preview + streaming server.
class SenderScreen extends StatefulWidget {
  const SenderScreen({super.key});

  @override
  State<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends State<SenderScreen> {
  final cam = CameraBridge();

  String preset = '1080p';
  int fps = 30;
  double quality = 0.7;
  bool audio = true;
  bool portrait = true;
  int port = GlimProtocol.defaultPort;
  bool blackout = false;
  List<String> addresses = [];
  bool initializing = true;

  @override
  void initState() {
    super.initState();
    cam.addListener(_onChange);
    _init();
  }

  Future<void> _init() async {
    try {
      await cam.initialize();
      await _loadAddresses();
      if (cam.cameraGranted) await _start();
    } finally {
      if (mounted) setState(() => initializing = false);
    }
  }

  Future<void> _loadAddresses() async {
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      addresses = [
        for (final i in list)
          for (final a in i.addresses)
            if (!a.isLoopback) '${a.address} (${i.name})',
      ];
    } catch (_) {}
  }

  Future<void> _start() => cam.start(
    preset: preset,
    fps: fps,
    quality: quality,
    audio: audio,
    port: port,
    portrait: portrait,
  );

  Future<void> _restart() async {
    if (cam.running) {
      await cam.stop();
      await _start();
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    cam.removeListener(_onChange);
    cam.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (blackout) {
      return GestureDetector(
        onDoubleTap: () => setState(() => blackout = false),
        child: Container(
          color: Colors.black,
          alignment: Alignment.bottomCenter,
          padding: const EdgeInsets.only(bottom: 48),
          child: Text(
            cam.clientConnected
                ? 'Uzatilmoqda • ${cam.sendFps} fps\nQaytish uchun ikki marta bosing'
                : 'Ulanish kutilmoqda…\nQaytish uchun ikki marta bosing',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white24, fontSize: 13),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _preview(),
          if (!initializing && !cam.cameraGranted) _permissionHint(),
          SafeArea(
            child: Column(
              children: [_topBar(), const Spacer(), _bottomControls()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _preview() {
    final id = cam.textureId;
    if (id == null || id < 0) return const SizedBox();
    final w = cam.width > 0 ? cam.width.toDouble() : 1080.0;
    final h = cam.height > 0 ? cam.height.toDouble() : 1920.0;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: w,
        height: h,
        child: Texture(textureId: id),
      ),
    );
  }

  Widget _permissionHint() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        "Kameraga ruxsat berilmagan.\nSozlamalar → Glim → Kamera'ni yoqing.",
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium,
      ),
    ),
  );

  Widget _topBar() {
    final connected = cam.clientConnected;
    final color = connected
        ? Colors.greenAccent
        : (cam.listening ? Colors.amberAccent : Colors.redAccent);
    final usb =
        cam.clientAddress.contains('127.0.0.1') ||
        cam.clientAddress.contains('::1');
    final label = connected
        ? 'Ulandi${usb ? ' (USB)' : ''} • ${cam.sendFps}/${cam.captureFps} fps'
        : cam.listening
        ? 'Kompyuter kutilmoqda • port $port'
        : (cam.running ? 'Ishga tushmoqda…' : "To'xtatilgan");
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _glass(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.circle, size: 10, color: color),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          label,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  if (!connected && addresses.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'USB kabel bilan ulang yoki Wi-Fi: ${addresses.join(', ')}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                  if (cam.width > 0)
                    Text(
                      '${cam.width}×${cam.height}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white54,
                      ),
                    ),
                  if (cam.error.isNotEmpty)
                    Text(
                      cam.error,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.redAccent,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _roundButton(Icons.tune, _openSettings),
          const SizedBox(width: 8),
          _roundButton(Icons.dark_mode, () => setState(() => blackout = true)),
        ],
      ),
    );
  }

  Widget _bottomControls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (cam.maxZoom > 1)
            _glass(
              Row(
                children: [
                  const Icon(Icons.zoom_in, size: 18),
                  Expanded(
                    child: Slider(
                      value: cam.zoom.clamp(1, cam.maxZoom),
                      min: 1,
                      max: cam.maxZoom,
                      onChanged: (v) => cam.setZoom(v),
                    ),
                  ),
                  Text('${cam.zoom.toStringAsFixed(1)}×'),
                ],
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final c in cam.cameras)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(c.name),
                      selected: c.id == cam.cameraId,
                      onSelected: (_) => cam.selectCamera(c.id),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _roundButton(
                cam.torch ? Icons.flash_on : Icons.flash_off,
                cam.hasTorch ? () => cam.setTorch(!cam.torch) : null,
              ),
              GestureDetector(
                onTap: () => cam.running ? cam.stop() : _start(),
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  padding: const EdgeInsets.all(6),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: cam.running ? BoxShape.rectangle : BoxShape.circle,
                      borderRadius: cam.running
                          ? BorderRadius.circular(8)
                          : null,
                      color: cam.running ? Colors.redAccent : Colors.white,
                    ),
                    child: Icon(
                      cam.running ? Icons.stop : Icons.videocam,
                      color: cam.running ? Colors.white : Colors.black,
                    ),
                  ),
                ),
              ),
              _roundButton(Icons.refresh, () async {
                await _loadAddresses();
                setState(() {});
              }),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void update(VoidCallback fn) {
            setSheet(fn);
            setState(() {});
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            shrinkWrap: true,
            children: [
              Text(
                'Uzatish sozlamalari',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              const Text('Sifat (rezolyutsiya)'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: '720p', label: Text('720p')),
                  ButtonSegment(value: '1080p', label: Text('1080p')),
                  ButtonSegment(value: '4k', label: Text('4K')),
                ],
                selected: {preset},
                onSelectionChanged: (s) => update(() => preset = s.first),
              ),
              const SizedBox(height: 12),
              const Text('Kadr tezligi'),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 24, label: Text('24')),
                  ButtonSegment(value: 30, label: Text('30')),
                  ButtonSegment(value: 60, label: Text('60')),
                ],
                selected: {fps},
                onSelectionChanged: (s) => update(() => fps = s.first),
              ),
              const SizedBox(height: 12),
              Text('JPEG sifati: ${(quality * 100).round()}%'),
              Slider(
                value: quality,
                min: 0.3,
                max: 0.95,
                onChanged: (v) => update(() => quality = v),
                onChangeEnd: cam.setQuality,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Vertikal (Reels / Shorts 9:16)'),
                value: portrait,
                onChanged: (v) => update(() => portrait = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('iPhone mikrofonini uzatish'),
                subtitle: cam.micGranted
                    ? null
                    : const Text('Mikrofonga ruxsat berilmagan'),
                value: audio,
                onChanged: (v) => update(() => audio = v),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _restart();
                },
                icon: const Icon(Icons.check),
                label: const Text("Qo'llash"),
              ),
              const SizedBox(height: 8),
              Text(
                'Port: $port. Ubuntu ilovasi USB orqali avtomatik ulanadi '
                '(usbmuxd / iproxy).',
                style: const TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _glass(Widget child) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(14),
    ),
    child: child,
  );

  Widget _roundButton(IconData icon, VoidCallback? onTap) => Material(
    color: Colors.black54,
    shape: const CircleBorder(),
    child: IconButton(
      icon: Icon(icon),
      color: Colors.white,
      disabledColor: Colors.white24,
      onPressed: onTap,
    ),
  );
}
