import 'dart:async';

import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/core/session.dart';
import 'package:avtar_pos/features/staff/staff_directory_page.dart';
import 'package:avtar_pos/features/staff/staff_salary.dart';
import 'package:avtar_pos/ui/record_editor_page.dart';
import 'package:avtar_pos/ui/staff.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Json employee([String id = 'employee']) => {
  'id': id,
  'name': 'Aman',
  'phone': '9876543210',
  'role': 'waiter',
  'joining_date': day(indiaNow()),
  'created_at': indiaTimestamp(),
  'monthly_salary_minor': 1500000,
  'is_active': true,
  'version': 1,
};

Future<Session> createSession({bool demo = true}) async {
  SharedPreferences.setMockInitialValues({});
  Session.prefs = await SharedPreferences.getInstance();
  final session = Session(
    client: MockClient((_) async => http.Response('{}', demo ? 200 : 503)),
    demoMode: demo,
  )..user = {'id': 1, 'role': 'owner'};
  // Keep uploads paused while verifying the local/offline transaction itself.
  session.expired = !demo;
  session.local = await LocalStore.connect(
    databaseFactoryFfi,
    inMemoryDatabasePath,
  );
  return session;
}

Future<void> settleStorage(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    if (find.text('Saving…').evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
}

Future<void> closeSession(WidgetTester tester, Session session) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(() => session.local!.db.close());
  session.dispose();
}

void mobile(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class DelayedAttendanceStore extends LocalStore {
  DelayedAttendanceStore(super.db);
  final firstRead = Completer<List<Json>>();
  int reads = 0;
  @override
  Future<List<Json>> list(
    String resource, {
    String query = '',
    String? status,
    int offset = 0,
    int limit = 100,
    Json filters = const {},
  }) {
    if (resource == 'attendance') {
      if (reads++ == 0) return firstRead.future;
      return Future.value([
        {'date': filters['from'], 'status': 'absent', 'staff_id': 'employee'},
      ]);
    }
    return super.list(
      resource,
      query: query,
      status: status,
      offset: offset,
      limit: limit,
      filters: filters,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'duplicate attendance rolls back both local record and queued mutation',
    () async {
      final session = await createSession(demo: false);
      addTearDown(() async {
        session.dispose();
        await session.local!.db.close();
      });
      final payload = {
        'staff_id': 'employee',
        'date': '2026-10-07',
        'status': 'present',
      };
      final first = await session.mutate('attendance', payload);
      await expectLater(
        session.mutate('attendance', payload),
        throwsA(isA<ApiFailure>()),
      );
      expect((await session.local!.listAll('attendance')).length, 1);
      expect((await session.local!.db.query('outbox')).length, 1);
      await session.mutate('attendance', {...first, 'status': 'half_day'});
      expect(
        (await session.local!.listAll('attendance')).single['status'],
        'half_day',
      );
      await session.mutate('attendance', {...payload, 'date': '2026-10-08'});
      expect((await session.local!.listAll('attendance')).length, 2);
    },
  );

  test('confirmed month cannot be deducted twice and employee ledgers stay separate', () async {
    final session = await createSession();
    addTearDown(() async {
      session.dispose();
      await session.local!.db.close();
    });
    final cut = {
      'staff_id': 'employee',
      'month_start': '2026-09-01',
      'deduction_minor': 10000,
      'absent_days': 1,
      'half_days': 0,
      'reason': 'Attendance',
    };
    await session.mutate('staff_salary_adjustments', cut);
    await expectLater(
      session.mutate('staff_salary_adjustments', cut),
      throwsA(isA<ApiFailure>()),
    );
    await session.mutate('staff_salary_adjustments', {
      ...cut,
      'staff_id': 'other',
    });
    await session.mutate('payments', {
      'staff_id': 'employee',
      'amount_minor': 50000,
      'date': '2026-10-07',
    });
    await session.mutate('payments', {
      'staff_id': 'other',
      'amount_minor': 20000,
      'date': '2026-10-07',
    });
    expect(await session.local!.paymentTotalsByStaff(), {
      'employee': 50000,
      'other': 20000,
    });
    expect(
      (await session.local!.listAll('staff_salary_adjustments')).length,
      2,
    );
  });

  test('existing salary cycle policy and half-day deduction are preserved', () {
    final staff = {
      ...employee(),
      'created_at': '2026-07-20T10:00:00+05:30',
      'joining_date': '2020-01-10',
    };
    expect(completedSalaryMonths(staff, today: DateTime(2026, 8, 9)), 0);
    expect(completedSalaryMonths(staff, today: DateTime(2026, 8, 10)), 1);
    expect(staffSalaryAccrued(staff, today: DateTime(2026, 9, 10)), 3000000);
    expect(
      attendanceSalaryDeductionForMonth(staff, [
        {'staff_id': 'employee', 'date': '2026-09-01', 'status': 'absent'},
        {'staff_id': 'employee', 'date': '2026-09-02', 'status': 'half_day'},
        {'staff_id': 'other', 'date': '2026-09-02', 'status': 'absent'},
      ], DateTime(2026, 9)),
      75000,
    );
  });

  test('server staff refresh preserves optional local notes and explicit clearing works', () async {
    final session = await createSession();
    addTearDown(() async {
      session.dispose();
      await session.local!.db.close();
    });
    await LocalStore.put(session.local!.db, 'staff', {
      ...employee(),
      'qualification': 'Hotel management',
      'degree': 'Diploma',
      'experience': '3 years',
    });
    await LocalStore.put(session.local!.db, 'staff', {
      ...employee(),
      'name': 'Updated by server',
      'version': 2,
    });
    var saved = (await session.local!.get('staff', 'employee'))!;
    expect(saved['name'], 'Updated by server');
    expect(saved['qualification'], 'Hotel management');
    expect(saved['degree'], 'Diploma');
    expect(saved['experience'], '3 years');
    await LocalStore.put(session.local!.db, 'staff', {
      ...saved,
      'experience': null,
    });
    saved = (await session.local!.get('staff', 'employee'))!;
    expect(saved['experience'], isNull);
  });

  testWidgets(
    'directory searches beyond 200 profiles and fits a small mobile screen',
    (tester) async {
      mobile(tester);
      final session = (await tester.runAsync(createSession))!;
      await tester.runAsync(() async {
        await session.local!.db.transaction((txn) async {
          for (var i = 0; i < 201; i++) {
            await LocalStore.put(txn, 'staff', {
              ...employee('staff-$i'),
              'name': 'Staff ${i.toString().padLeft(3, '0')}',
              'is_active': i != 200,
            });
          }
        });
      });
      await tester.pumpWidget(MaterialApp(home: StaffDirectoryPage(session)));
      await settleStorage(tester);
      expect(find.text('201 staff'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Staff 200');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(Card, 'Staff 200'), findsOneWidget);
      expect(find.text('Inactive'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Active'));
      await tester.pumpAndSettle();
      expect(find.text('No matching staff'), findsOneWidget);
      await closeSession(tester, session);
    },
  );

  testWidgets(
    'profile edit and payments refresh totals, expanded attendance scrolls on mobile',
    (tester) async {
      mobile(tester);
      final session = (await tester.runAsync(createSession))!;
      final staff = employee();
      await tester.runAsync(
        () => LocalStore.put(session.local!.db, 'staff', staff),
      );
      await tester.pumpWidget(MaterialApp(home: StaffPage(session, staff)));
      await settleStorage(tester);
      await tester.tap(find.byTooltip('Edit staff'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).first, 'Aman Updated');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Save changes'),
        250,
        scrollable: find
            .byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            )
            .last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save changes'));
      await settleStorage(tester);
      expect(
        find.text('Aman Updated'),
        findsOneWidget,
        reason: tester.allWidgets
            .whereType<Text>()
            .map((text) => text.data)
            .join(' | '),
      );
      await tester.runAsync(
        () => session.mutate('payments', {
          'staff_id': 'employee',
          'amount_minor': 250000,
          'date': day(indiaNow()),
          'payment_mode': 'cash',
        }),
      );
      await settleStorage(tester);
      await tester.tap(find.text('Staff account & attendance'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Paid all time:').evaluate().single.widget,
        isA<Text>(),
      );
      final paid = tester.widget<Text>(find.textContaining('Paid all time:'));
      expect(paid.data, contains(money(250000)));
      await tester.ensureVisible(
        find.text('P Present · A Absent · H Half day · L Leave'),
      );
      await settleStorage(tester);
      expect(tester.takeException(), isNull);
      await closeSession(tester, session);
    },
  );

  testWidgets(
    'payment requires employee and rejects zero amount and invalid calendar dates',
    (tester) async {
      final session = (await tester.runAsync(createSession))!;
      await tester.pumpWidget(
        MaterialApp(home: RecordEditor(session, 'payments')),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (₹)'),
        '0',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Payment date'),
        '2026-02-31',
      );
      await tester.ensureVisible(find.text('Save changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(find.text('Staff member is required'), findsOneWidget);
      expect(find.text('Use YYYY-MM-DD'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: RecordEditor(
            session,
            'payments',
            key: const ValueKey('fixed-staff'),
            initial: {'staff_id': 'employee'},
            hiddenFields: const {'staff_id'},
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount (₹)'),
        '0',
      );
      await tester.ensureVisible(find.text('Save changes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Payment must be greater than'),
        findsOneWidget,
      );
      expect(
        await tester.runAsync(() => session.local!.listAll('payments')),
        isEmpty,
      );
      await closeSession(tester, session);
    },
  );

  testWidgets(
    'late attendance read cannot overwrite the newly selected month',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = (await tester.runAsync(createSession))!;
      final store = DelayedAttendanceStore(session.local!.db);
      session.local = store;
      final staff = employee();
      await tester.runAsync(() => LocalStore.put(store.db, 'staff', staff));
      await tester.pumpWidget(MaterialApp(home: StaffPage(session, staff)));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byIcon(Icons.chevron_left));
      await settleStorage(tester);
      expect(find.text('A'), findsOneWidget);
      store.firstRead.complete([
        {
          'date': day(DateTime(indiaNow().year, indiaNow().month)),
          'status': 'present',
          'staff_id': 'employee',
        },
      ]);
      await settleStorage(tester);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('P'), findsNothing);
      expect(tester.takeException(), isNull);
      await closeSession(tester, session);
    },
  );
  testWidgets('blank staff name stays required after scrolling it off screen', (
    tester,
  ) async {
    mobile(tester);
    final session = (await tester.runAsync(createSession))!;
    await tester.pumpWidget(MaterialApp(home: RecordEditor(session, 'staff')));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Phone'),
      '9876543210',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final vertical = find
        .byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        )
        .last;
    await tester.scrollUntilVisible(
      find.widgetWithText(TextFormField, 'Monthly salary (₹)'),
      250,
      scrollable: vertical,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Monthly salary (₹)'),
      '15000',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save changes'),
      250,
      scrollable: vertical,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.text('Name: Name is required'), findsOneWidget);
    expect(
      await tester.runAsync(() => session.local!.listAll('staff')),
      isEmpty,
    );
    await closeSession(tester, session);
  });
}
