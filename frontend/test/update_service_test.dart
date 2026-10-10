import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/main.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class TestUpdater extends AppUpdateService {
  TestUpdater(http.Client client) : super(client: client, demoMode: false);
  @override
  bool get enabled => true;
}

class BannerSession extends Session {
  BannerSession(http.Client client) : super(client: client);
  late final AppUpdateService _bannerUpdater = TestUpdater(client)
    ..state = UpdateState.ready
    ..update = AppUpdate(
      version: '100.0.1',
      notes: 'Test',
      asset: Uri.parse('https://updates.invalid/setup.exe'),
      sha256: '',
    );
  @override
  AppUpdateService get updater => _bannerUpdater;
}

String manifest({
  String version = '100.0.1',
  String scheme = 'https',
  String? hash,
}) => jsonEncode({
  'version': version,
  'notes': 'Test release',
  'platforms': {
    'windows': {
      'url': '$scheme://updates.invalid/setup.exe',
      'sha256':
          hash ?? sha256.convert(utf8.encode('test installer')).toString(),
    },
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory downloads;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(() async {
    downloads = await Directory.systemTemp.createTemp('avtar-updater-tests-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => downloads.path);
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await downloads.delete(recursive: true);
  });

  test('debug/demo builds do not check or download updates', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response(manifest(), 200);
    });
    final service = AppUpdateService(client: client, demoMode: true);
    final session = Session(client: client, demoMode: true);
    await service.runAutomaticUpdate(session);
    await service.check();
    expect(requests, 0);
    expect(service.state, UpdateState.disabled);
    service.dispose();
    session.dispose();
  });

  testWidgets(
    'global update banner opens install confirmation through the app navigator',
    (tester) async {
      final session = BannerSession(
        MockClient((_) async => http.Response('{}', 200)),
      )..ready = true;
      await tester.pumpWidget(AvtarApp(session: session));
      expect(find.text('Update 100.0.1 downloaded.'), findsOneWidget);
      await tester.tap(find.text('Install update'));
      await tester.pumpAndSettle();
      expect(find.text('Install update and restart?'), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    },
    skip: !Platform.isWindows,
  );

  test('older version never becomes available', () async {
    final client = MockClient(
      (_) async => http.Response(manifest(version: '1.0.0'), 200),
    );
    final service = TestUpdater(client);
    await service.check();
    expect(service.state, UpdateState.idle);
    expect(service.update, isNull);
    service.dispose();
    client.close();
  });

  test('insecure URLs and malformed checksums are rejected', () async {
    for (final body in [manifest(scheme: 'http'), manifest(hash: 'bad')]) {
      final client = MockClient((_) async => http.Response(body, 200));
      final service = TestUpdater(client);
      await service.check();
      expect(service.state, UpdateState.error);
      service.dispose();
      client.close();
    }
  });

  test('overlapping checks issue only one request', () async {
    var requests = 0;
    final response = Completer<http.Response>();
    final client = MockClient((_) {
      requests++;
      return response.future;
    });
    final service = TestUpdater(client);
    final first = service.check();
    await service.check();
    response.complete(http.Response(manifest(), 200));
    await first;
    expect(requests, 1);
    service.dispose();
    client.close();
  });

  test(
    'automatic restart waits for unlock screen and all durable work',
    () async {
      final session =
          Session(client: MockClient((_) async => http.Response('{}', 200)))
            ..ready = true
            ..user = {'id': 1, 'role': 'owner'};
      session.local = await LocalStore.connect(
        databaseFactoryFfi,
        inMemoryDatabasePath,
      );
      final service = TestUpdater(session.client);
      expect(await service.canAutomaticallyRestart(session), false);
      session.appLocked = true;
      expect(await service.canAutomaticallyRestart(session), true);
      session.syncing = true;
      expect(await service.canAutomaticallyRestart(session), false);
      session.syncing = false;
      await session.local!.db.insert('outbox', {
        'key': 'test',
        'entity': 'order',
        'resource': 'orders',
        'method': 'POST',
        'path': 'orders',
        'payload': '{}',
      });
      expect(await service.canAutomaticallyRestart(session), false);
      await session.local!.db.update('outbox', {'state': 'conflict'});
      expect(await service.canAutomaticallyRestart(session), false);
      await session.local!.db.delete('outbox');
      await session.local!.draft({'id': 'draft', 'items': []});
      expect(await service.canAutomaticallyRestart(session), false);
      await session.local!.db.delete('drafts');
      expect(await service.canAutomaticallyRestart(session), true);
      session.ready = false;
      expect(await service.canAutomaticallyRestart(session), false);
      await session.local!.db.close();
      service.dispose();
      session.dispose();
    },
  );

  test('automatic update verifies download and preserves active counter', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return http.Response(
        request.url.host == 'updates.invalid' ? 'test installer' : manifest(),
        200,
      );
    });
    final service = TestUpdater(client);
    final session = Session(client: client)
      ..ready = true
      ..user = {'id': 1};
    await service.runAutomaticUpdate(session);
    expect(service.state, UpdateState.ready);
    expect(service.canInstall, true);
    expect(session.installingUpdate, false);
    await service.runAutomaticUpdate(session);
    await service.check();
    await service.download();
    expect(
      requests,
      2,
      reason:
          'A verified ready installer is retained, without repeated downloads.',
    );
    service.dispose();
    session.dispose();
  }, skip: !Platform.isWindows);

  test('checksum mismatch prevents install', () async {
    final client = MockClient(
      (request) async => http.Response(
        request.url.host == 'updates.invalid'
            ? 'tampered installer'
            : manifest(version: '100.0.2'),
        200,
      ),
    );
    final service = TestUpdater(client);
    await service.check();
    await service.download();
    expect(service.state, UpdateState.error);
    expect(service.canInstall, false);
    expect(service.status, contains('hash did not match'));
    service.dispose();
    client.close();
  }, skip: !Platform.isWindows);

  test(
    'installer changed after download is rejected before OS launch',
    () async {
      final client = MockClient(
        (request) async => http.Response(
          request.url.host == 'updates.invalid'
              ? 'test installer'
              : manifest(version: '100.0.3'),
          200,
        ),
      );
      final service = TestUpdater(client);
      final session = Session(client: client)
        ..ready = true
        ..user = {'id': 1};
      await service.check();
      await service.download();
      expect(service.canInstall, true);
      await File('${downloads.path}/updates/AvtarPOS-Setup-100.0.3.exe')
          .writeAsString('changed');
      await expectLater(service.installAndRestart(session), throwsStateError);
      expect(service.canInstall, false);
      expect(service.state, UpdateState.error);
      expect(session.installingUpdate, false);
      service.dispose();
      session.dispose();
    },
    skip: !Platform.isWindows,
  );

  test(
    'automatic retries stay quiet for five minutes after a failed check',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        throw const SocketException('offline');
      });
      final service = TestUpdater(client);
      final session = Session(client: client)..ready = true;
      await service.runAutomaticUpdate(session);
      await service.runAutomaticUpdate(session);
      expect(requests, 1);
      expect(service.state, UpdateState.error);
      expect(service.status, contains('retry automatically'));
      service.dispose();
      session.dispose();
    },
  );
}
