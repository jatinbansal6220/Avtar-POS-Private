import 'dart:convert';
import 'dart:io';

import 'package:avtar_pos/core/feature_policy.dart';
import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/features/developer/developer_panel.dart';
import 'package:avtar_pos/features/developer/feature_access.dart';
import 'package:avtar_pos/features/orders/data/order_draft.dart';
import 'package:avtar_pos/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Json defaults() => {
  'app_enabled': true,
  'message': 'Contact developer.',
  'features': {for (final key in developerFeatures.keys) key: true},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    Session.prefs = await SharedPreferences.getInstance();
  });

  test('demo developer controls verify access, persist flags and reject expired grants', () async {
    var requests = 0;
    final session = Session(demoMode: true, client: MockClient((_) async {
      requests++;
      return http.Response('{}', 500);
    }))..token = 'demo-token'..user = {'id': 1, 'role': 'owner'};
    await expectLater(session.unlockDeveloper('wrong-password'), throwsA(isA<ApiFailure>()));
    final unlocked = await session.unlockDeveloper('test-only-password');
    final grant = unlocked['developer_token'] as String;
    final snapshot = await session.developerRequest('GET', 'developer/controls', grant: grant);
    final policy = snapshot['global']['policy'] as Json;
    policy['app_enabled'] = false;
    (policy['features'] as Map)['printing'] = false;
    await session.developerRequest('PUT', 'developer/controls/global', grant: grant,
      body: {'revision': 0, 'policy': policy});
    await session.startControlPolicy();
    expect(session.appEnabled, false);
    expect(session.policyAllows('printing'), false);
    await expectLater(session.developerRequest('PUT', 'developer/controls/global', grant: grant,
      body: {'revision': 0, 'policy': policy}), throwsA(isA<ApiFailure>()));
    session.demoDeveloperGrantExpires = DateTime.now().subtract(const Duration(seconds: 1));
    await expectLater(session.developerRequest('GET', 'developer/controls', grant: grant), throwsA(isA<ApiFailure>()));
    expect(requests, 0);
    expect(Session.prefs.getKeys().any((key) => key.contains('grant')), false);
    session.dispose();
  }, skip: const String.fromEnvironment('DEMO_DEVELOPER_PASSWORD_HASH').isEmpty);

  testWidgets('demo developer verification opens the local controls panel', (tester) async {
    final session = Session(demoMode: true)..token = 'demo-token'..user = {'id': 1};
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => openDeveloperPanel(context, session), child: const Text('Open developer'))))));
    await tester.tap(find.text('Open developer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Developer password'), 'test-only-password');
    await tester.tap(find.text('Verify'));
    await tester.pumpAndSettle();
    expect(find.text('Developer controls'), findsOneWidget);
    expect(find.text('This local demo only'), findsOneWidget);
    expect(find.text('App access'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  }, skip: const String.fromEnvironment('DEMO_DEVELOPER_PASSWORD_HASH').isEmpty);

  testWidgets('partial login does not mount database-backed POS pages', (tester) async {
    final session = Session(demoMode: true)
      ..ready = true
      ..token = 'demo-token'
      ..user = {'id': 1, 'role': 'owner'};
    await tester.pumpWidget(AvtarApp(session: session));
    session.changed();
    await tester.pump();
    expect(find.text('Sign in to your restaurant'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });

  test(
    'remote flags survive offline restart and are isolated by restaurant',
    () async {
      var offline = false;
      final policy = defaults()..['app_enabled'] = false;
      (policy['features'] as Map)['kot'] = false;
      final session =
          Session(
              client: MockClient((request) async {
                if (offline) throw const SocketException('offline');
                return http.Response(jsonEncode({'policy': policy}), 200);
              }),
            )
            ..base = 'https://test.invalid/api'
            ..token = 'account-token'
            ..user = {'id': 1};
      await session.refreshControlPolicy();
      expect(session.appEnabled, false);
      expect(session.featureEnabled('kot'), false);
      offline = true;
      await session.refreshControlPolicy();
      expect(session.appEnabled, false);
      await session.startControlPolicy();
      expect(session.appEnabled, false);
      session.user = {'id': 2};
      await session.startControlPolicy();
      expect(session.appEnabled, true);
      session.dispose();
    },
  );

  test('sync off keeps durable local saves; app pause preserves and blocks new mutations', () async {
    final session = Session(
      client: MockClient((_) async => throw const SocketException('offline')),
    )..user = {'id': 1, 'role': 'owner'};
    session.local = await LocalStore.connect(
      databaseFactoryFfi,
      inMemoryDatabasePath,
    );
    session.controlPolicy = defaults();
    (session.controlPolicy['features'] as Map)['sync'] = false;
    final draft = newOrder();
    await session.enqueueOrder(draft);
    final queued = await session.local!.db.query('outbox');
    expect(queued.length, 1);
    expect(await session.local!.get('orders', draft['id']), isNotNull);
    await session.sync();
    expect(await session.local!.db.query('outbox'), queued);
    session.controlPolicy['app_enabled'] = false;
    await expectLater(
      session.enqueueOrder(newOrder()),
      throwsA(isA<ApiFailure>()),
    );
    expect(await session.local!.db.query('outbox'), queued);
    await session.local!.db.close();
    session.dispose();
  });

  test(
    'payment and module guards cannot be bypassed through save services',
    () async {
      final session = Session(demoMode: true)..controlPolicy = defaults();
      final flags = session.controlPolicy['features'] as Map;
      flags['upi'] = false;
      expect(
        () => session.validateControlledPayment({
          'payment_method': 'mixed',
          'payments': [
            {'method': 'upi', 'amount_minor': 100},
          ],
        }),
        throwsA(isA<ApiFailure>()),
      );
      flags['discounts'] = false;
      expect(
        () => session.validateControlledPayment({'discount_value': 100}),
        throwsA(isA<ApiFailure>()),
      );
      flags['table_merge'] = false;
      await expectLater(
        session.mergeDiningTables(newOrder(), '02'),
        throwsA(isA<ApiFailure>()),
      );
      flags['staff'] = false;
      await expectLater(
        session.mutate('attendance', {}),
        throwsA(isA<ApiFailure>()),
      );
      flags['inventory'] = false;
      await expectLater(
        session.mutate('inventory_entries', {}),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        session.createInventoryItem(name: 'Milk', quantity: 1),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        session.recordInventoryQuantity({'id': 'milk'}, quantity: 1),
        throwsA(isA<ApiFailure>()),
      );
      session.dispose();
    },
  );

  test(
    're-enabling sync uploads queued work even while app access is paused',
    () async {
      final remote = defaults()..['app_enabled'] = false;
      final session =
          Session(
              client: MockClient((request) async {
                if (request.url.path.endsWith('control-policy')) {
                  return http.Response(jsonEncode({'policy': remote}), 200);
                }
                if (request.method == 'POST') {
                  return http.Response(
                    jsonEncode({
                      ...jsonDecode(request.body) as Map<String, dynamic>,
                      'version': 1,
                      'status': 'open',
                    }),
                    201,
                  );
                }
                return http.Response(
                  jsonEncode({
                    'changes': [],
                    'next_cursor': 0,
                    'has_more': false,
                  }),
                  200,
                );
              }),
            )
            ..base = 'https://test.invalid/api'
            ..token = 'account-token'
            ..user = {'id': 1, 'role': 'owner'}
            ..controlPolicy = defaults();
      session.local = await LocalStore.connect(
        databaseFactoryFfi,
        inMemoryDatabasePath,
      );
      await session.local!.setMeta('cursor', '0');
      (session.controlPolicy['features'] as Map)['sync'] = false;
      final draft = newOrder();
      await session.enqueueOrder(draft);
      expect((await session.local!.db.query('outbox')).length, 1);
      await session.refreshControlPolicy();
      while (session.syncing) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(session.appEnabled, false);
      expect(await session.local!.db.query('outbox'), isEmpty);
      expect((await session.local!.get('orders', draft['id']))?['version'], 1);
      await session.local!.db.close();
      session.dispose();
    },
  );

  test(
    'invalid server response does not remove an accepted restriction',
    () async {
      final session =
          Session(
              client: MockClient(
                (_) async => http.Response(
                  jsonEncode({
                    'policy': {'app_enabled': true, 'features': 'invalid'},
                  }),
                  200,
                ),
              ),
            )
            ..base = 'https://test.invalid/api'
            ..token = 'account-token'
            ..user = {'id': 1}
            ..controlPolicy = (defaults()..['app_enabled'] = false);
      await session.refreshControlPolicy();
      expect(session.appEnabled, false);
      session.dispose();
    },
  );

  testWidgets('disabled page retains its in-progress editor and can recover', (
    tester,
  ) async {
    final session = Session(demoMode: true)..controlPolicy = defaults();
    final editor = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeatureAccess(
            session: session,
            feature: 'staff',
            child: TextField(controller: editor),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Unsaved staff notes');
    (session.controlPolicy['features'] as Map)['staff'] = false;
    session.changed();
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Feature unavailable'), findsOneWidget);
    (session.controlPolicy['features'] as Map)['staff'] = true;
    session.changed();
    await tester.pump();
    expect(find.text('Unsaved staff notes'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    editor.dispose();
    session.dispose();
  });

  testWidgets('Ctrl Shift F12 triggers developer entry from login', (
    tester,
  ) async {
    final session = Session(demoMode: true)..ready = true;
    await tester.pumpWidget(AvtarApp(session: session));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      find.text(
        'Sign in to a restaurant account before developer verification.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets(
    'developer grant stays in memory and confirmed policy uses revision',
    (tester) async {
      var policy = defaults();
      var revision = 0;
      Json? submitted;
      final session =
          Session(
              client: MockClient((request) async {
                if (request.url.path.endsWith('developer/unlock')) {
                  return http.Response(
                    jsonEncode({'developer_token': 'test-memory-grant'}),
                    200,
                  );
                }
                if (request.url.path.endsWith('control-policy')) {
                  return http.Response(jsonEncode({'policy': policy}), 200);
                }
                expect(
                  request.headers['X-Developer-Token'],
                  'test-memory-grant',
                );
                if (request.method == 'PUT') {
                  expect(request.url.path.endsWith('/global'), true);
                  submitted = jsonDecode(request.body) as Json;
                  policy = submitted!['policy'] as Json;
                  revision++;
                  return http.Response(jsonEncode({'revision': revision}), 200);
                }
                return http.Response(
                  jsonEncode({
                    'global': {
                      'scope': 'global',
                      'revision': revision,
                      'policy': policy,
                    },
                    'tenants': [
                      {
                        'id': 2,
                        'name': 'Other restaurant',
                        'control': {
                          'scope': 'tenant:2',
                          'revision': 0,
                          'policy': defaults(),
                        },
                      },
                    ],
                  }),
                  200,
                );
              }),
            )
            ..base = 'https://test.invalid/api'
            ..token = 'account-token'
            ..user = {'id': 1, 'role': 'owner'}
            ..ready = true
            ..appLocked = true
            ..appLockConfigured = true
            ..controlPolicy = (defaults()..['app_enabled'] = false);
      await tester.pumpWidget(AvtarApp(session: session));
      expect(find.text('App access paused'), findsOneWidget);
      await tester.tap(find.text('Developer access'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'test-only-password',
      );
      await tester.tap(find.text('Verify'));
      await tester.pumpAndSettle();
      expect(find.text('Developer controls'), findsOneWidget);
      final appSwitch = find.widgetWithText(SwitchListTile, 'App access');
      await tester.tap(appSwitch);
      await tester.pump();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other restaurant (#2)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
            .value,
        'global',
      );
      expect(tester.widget<SwitchListTile>(appSwitch).value, false);
      final apply = find.text('Apply controls');
      await tester.scrollUntilVisible(
        apply,
        600,
        scrollable: find
            .descendant(
              of: find.byType(DeveloperPanel),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(apply);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(submitted!['revision'], 0);
      expect((submitted!['policy'] as Map)['app_enabled'], false);
      expect(revision, 1);
      for (final key in Session.prefs.getKeys()) {
        final value = '${Session.prefs.get(key)}';
        expect(value, isNot(contains('test-memory-grant')));
        expect(value, isNot(contains('test-only-password')));
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(session.developerPanelVisible, false);
      expect(find.text('App access paused'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
}
