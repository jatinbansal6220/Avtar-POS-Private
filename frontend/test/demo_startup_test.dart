import 'dart:convert';
import 'dart:io';

import 'package:avtar_pos/core/session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  test('local demo opens directly and preserves drafts and live session',
      () async {
    final directory = await Directory.systemTemp.createTemp('demo-startup-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => directory.path);
    final official = jsonEncode({
      'base': 'https://avtarpos.duckdns.org/api',
      'token': 'test-real-account-token',
      'user': {'id': 7, 'role': 'owner'},
    });
    SharedPreferences.setMockInitialValues({'session': official});
    var requests = 0;
    Session createSession() => Session(
          demoMode: true,
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 500);
          }),
        );
    final first = createSession();
    await first.restore();
    expect(first.ready, isTrue);
    expect(first.local, isNotNull);
    expect(first.appLocked, isFalse);
    expect(Session.prefs.getString('session'), official);
    await first.local!.draft({'id': 'retained-draft', 'status': 'open'});
    await first.local!.db.close();
    first.dispose();

    final restarted = createSession();
    await restarted.restore();
    expect(await restarted.local!.readDraft('retained-draft'), isNotNull);
    expect(requests, 0);
    expect(restarted.ready, isTrue);
    expect(restarted.appLocked, isFalse);
    expect(restarted.user, isNotNull);
    await restarted.local!.db.close();
    restarted.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
  });
}
