import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:avtar_pos/core/cached_login.dart';
import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/main.dart';
import 'package:avtar_pos/ui/login.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestPaths extends PathProviderPlatform {
  final String directory;
  TestPaths(this.directory);
  @override
  Future<String?> getApplicationSupportPath() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'an API response from an old account is rejected after account switch',
    () async {
      final reply = Completer<http.Response>();
      final started = Completer<void>();
      final session =
          Session(
              demoMode: false,
              client: MockClient((_) {
                started.complete();
                return reply.future;
              }),
            )
            ..base = 'https://fixture.invalid/api'
            ..user = {'id': 81001};
      addTearDown(session.dispose);
      final request = session.request('GET', 'bills');
      final rejected = expectLater(request, throwsA(isA<ApiFailure>()));
      await started.future;
      session.user = {'id': 81002};
      reply.complete(
        http.Response('{"data":[{"id":"old-account-bill"}]}', 200),
      );
      await rejected;
    },
  );

  test('offline password verifier matches PBKDF2 SHA256 vector', () {
    final derived = deriveLoginVerifier({
      'password': 'password',
      'salt': utf8.encode('salt'),
      'rounds': 1,
    });
    expect(
      derived.map((v) => v.toRadixString(16).padLeft(2, '0')).join(),
      '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
    );
  });

  test(
    'cached verifier is salted, rejects wrong and expired credentials',
    () async {
      final first = await createCachedLogin('fixture-password');
      final second = await createCachedLogin('fixture-password');
      expect(first, isNot(second));
      expect(first, isNot(contains('fixture-password')));
      expect(await verifyCachedLogin(first, 'fixture-password'), true);
      expect(await verifyCachedLogin(first, 'incorrect'), false);
      final expired = jsonDecode(first) as Map<String, dynamic>;
      expired['expires_at'] = '2000-01-01T00:00:00Z';
      expect(
        await verifyCachedLogin(jsonEncode(expired), 'fixture-password'),
        false,
      );
      expect(await verifyCachedLogin('{}', 'fixture-password'), false);
    },
  );

  test(
    'startup requires account login and switching preserves isolated databases',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'account-isolation-',
      );
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = TestPaths(directory.path);
      addTearDown(() => PathProviderPlatform.instance = originalPaths);
      SharedPreferences.setMockInitialValues({});
      Session.prefs = await SharedPreferences.getInstance();
      var networkDown = false;
      final writes = <String>[];
      const accountA = {
        'id': 81001,
        'email': 'a@fixture.invalid',
        'role': 'owner',
      };
      const accountB = {
        'id': 81002,
        'email': 'b@fixture.invalid',
        'role': 'owner',
      };
      Session createSession() => Session(
        demoMode: false,
        client: MockClient((request) async {
          if (networkDown) {
            throw const SocketException('Test network unavailable');
          }
          final path = request.url.path;
          if (path.endsWith('/auth/login')) {
            final body = jsonDecode(request.body) as Map;
            final account = body['email'] == accountA['email']
                ? accountA
                : accountB;
            if (body['password'] != 'fixture-password') {
              return http.Response(
                '{"message":"Email or password is incorrect."}',
                422,
              );
            }
            return http.Response(
              jsonEncode({
                'user': account,
                'token': 'fixture-${account['id']}',
              }),
              200,
            );
          }
          if (path.endsWith('/auth/me')) {
            return http.Response(
              jsonEncode(
                request.headers['authorization']!.contains('81001')
                    ? accountA
                    : accountB,
              ),
              200,
            );
          }
          if (path.endsWith('/health')) {
            return http.Response(
              jsonEncode({'timestamp': DateTime.now().toIso8601String()}),
              200,
            );
          }
          if (path.endsWith('/control-policy')) return http.Response('{}', 404);
          if (path.endsWith('/sync/cursor')) {
            return http.Response('{"cursor":0}', 200);
          }
          if (path.endsWith('/updates')) {
            return http.Response(
              '{"changes":[],"next_cursor":0,"has_more":false}',
              200,
            );
          }
          if (request.method == 'POST') {
            writes.add(request.headers['authorization']!);
            return http.Response(
              '{"message":"Test mutation intentionally retained"}',
              422,
            );
          }
          return http.Response('{"data":[],"next_cursor":null}', 200);
        }),
      );

      final first = createSession();
      await first.login('', 'a@fixture.invalid', 'fixture-password');
      await LocalStore.put(first.local!.db, 'bills', {
        'id': 'bill-a',
        'total_minor': 12345,
      });
      await first.local!.draft({'id': 'draft-a', 'status': 'open'});
      await first.local!.db.insert('outbox', {
        'key': 'fixture-write-a',
        'entity': 'order-a',
        'resource': 'orders',
        'method': 'POST',
        'path': 'orders',
        'payload': '{}',
      });
      await first.local!.db.close();
      first.dispose();

      final restarted = createSession();
      await restarted.restore();
      expect(restarted.accountLoginRequired, true);
      expect(restarted.appLocked, false);
      expect(restarted.timer, isNull);
      await restarted.sync();
      expect(writes, isEmpty);
      await restarted.login('', 'b@fixture.invalid', 'fixture-password');
      expect(restarted.accountLoginRequired, false);
      expect(await restarted.local!.get('bills', 'bill-a'), isNull);
      expect(await restarted.local!.readDraft('draft-a'), isNull);
      expect(await restarted.local!.db.query('outbox'), isEmpty);
      expect(writes, isEmpty);
      await LocalStore.put(restarted.local!.db, 'bills', {
        'id': 'bill-b',
        'total_minor': 67890,
      });
      await restarted.local!.db.close();
      restarted.dispose();

      final offline = createSession();
      networkDown = true;
      await offline.restore();
      await expectLater(
        offline.login('', 'a@fixture.invalid', 'fixture-password'),
        throwsA(isA<SocketException>()),
      );
      await expectLater(
        offline.login('', 'b@fixture.invalid', 'incorrect'),
        throwsA(isA<ApiFailure>()),
      );
      expect(offline.accountLoginRequired, true);
      await offline.login('', 'b@fixture.invalid', 'fixture-password');
      expect(offline.accountLoginRequired, false);
      expect(await offline.local!.get('bills', 'bill-b'), isNotNull);
      expect(await offline.local!.get('bills', 'bill-a'), isNull);
      await offline.local!.db.close();
      offline.dispose();

      networkDown = false;
      final returning = createSession();
      await returning.restore();
      await returning.login('', 'a@fixture.invalid', 'fixture-password');
      expect(await returning.local!.get('bills', 'bill-a'), isNotNull);
      expect(await returning.local!.get('bills', 'bill-b'), isNull);
      expect(await returning.local!.readDraft('draft-a'), isNotNull);
      expect(await returning.local!.db.query('outbox'), isNotEmpty);
      expect(writes.every((token) => token.contains('81001')), true);
      await returning.local!.db.close();
      returning.dispose();
    },
  );

  testWidgets(
    'cached startup shows full login instead of local password screen',
    (tester) async {
      final session = Session(demoMode: false)
        ..ready = true
        ..accountLoginRequired = true
        ..user = {'id': 81001, 'email': 'a@fixture.invalid', 'role': 'owner'};
      addTearDown(session.dispose);
      await tester.pumpWidget(AvtarApp(session: session));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.text('Email / login ID'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('a@fixture.invalid'), findsOneWidget);
      expect(find.text('Create app password'), findsNothing);
    },
  );
}
