import 'dart:async';

import 'package:flutter/material.dart';

class BrandSplash extends StatefulWidget {
  final bool closing;
  const BrandSplash({super.key, this.closing = false});
  @override
  State<BrandSplash> createState() => _BrandSplashState();
}

class _BrandSplashState extends State<BrandSplash> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer(Duration(milliseconds: widget.closing ? 2100 : 1800), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF0B0C0D),
    body: Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          widget.closing
              ? 'assets/branding/avtar_end.jpeg'
              : 'assets/branding/zelovix_start_splash.png',
          fit: BoxFit.cover,
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: widget.closing ? .44 : .18),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              const Spacer(),
              if (widget.closing)
                const Text(
                  'Thank you for choosing Avtar Cooks',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 14),
              const Text(
                'Z E L O V I X',
                style: TextStyle(
                  color: Color(0xFFE6B85C),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 5,
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ],
    ),
  );
}
