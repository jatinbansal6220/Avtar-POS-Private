import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/ui/login.dart';
import 'package:avtar_pos/ui/shared.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('login fits ${size.width.toInt()} without overflow', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = Session();
      addTearDown(session.dispose);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: RepaintBoundary(key: key, child: LoginPage(session)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Sign in'), findsOneWidget);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await Directory('build/qa').create(recursive: true);
        await File('build/qa/login_${size.width.toInt()}.png')
            .writeAsBytes(png!.buffer.asUint8List());
      });
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      expect(find.text('Password is required'), findsOneWidget);
    });
  }
}
