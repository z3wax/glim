import 'dart:io';

import 'package:flutter/material.dart';

import 'receiver/receiver_screen.dart';
import 'sender/sender_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GlimApp());
}

/// One codebase, two roles:
///  * iOS   -> camera sender (iPhone becomes a USB webcam)
///  * Linux -> reels recorder (receives the iPhone camera and records 9:16)
class GlimApp extends StatelessWidget {
  const GlimApp({super.key});

  @override
  Widget build(BuildContext context) {
    final isPhone = Platform.isIOS || Platform.isAndroid;
    return MaterialApp(
      title: 'Glim',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF4D6D),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: isPhone ? const SenderScreen() : const ReceiverScreen(),
    );
  }
}
