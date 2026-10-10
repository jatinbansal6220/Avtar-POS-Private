import 'dart:convert';

import 'package:avtar_pos/core/local_store.dart';
import 'package:avtar_pos/core/models.dart';
import 'package:avtar_pos/features/analytics/analytics_series.dart';
import 'package:avtar_pos/features/analytics/analytics_chart.dart';
import 'package:avtar_pos/features/analytics/local_reports.dart';
import 'package:avtar_pos/ui/analytics.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'pos_usability_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('calendar graph includes gaps, leap day and all 31 days', () {
    final series = dailyAnalyticsSeries('2024-02-01', '2024-03-02', [
      {'day': '2024-02-29', 'revenue_minor': 25000, 'bills': 2},
    ]);
    expect(series.length, 31);
    expect(series[28], {
      'day': '2024-02-29',
      'revenue_minor': 25000,
      'bills': 2,
    });
    expect(series.first['revenue_minor'], 0);
    expect(series.last['day'], '2024-03-02');
    expect(dailyAnalyticsSeries('2024-01-01', '2024-12-31', []).length, 366);
  });

  test('invalid, reversed and excessive ranges cannot produce charts', () {
    for (final range in [
      ('2026-02-30', '2026-03-02'),
      ('2026-03-02', '2026-03-01'),
      ('2024-01-01', '2025-01-01'),
    ]) {
      expect(
        () => dailyAnalyticsSeries(range.$1, range.$2, []),
        throwsA(isA<ApiFailure>()),
      );
    }
  });

  test(
    'hour chart has 24 buckets and preserves exact bill counts and paise',
    () {
      final series = hourlyAnalyticsSeries([
        {'hour': '18:00', 'bills': 3, 'revenue_minor': 12001},
      ]);
      expect(series.length, 24);
      expect(series[18]['revenue_minor'], 12001);
      expect(series[18]['bills'], 3);
      expect(series[0]['bills'], 0);
    },
  );

  test(
    'daily graph sums reconcile with saved bills and exclude open orders',
    () async {
      final session = await fixture.setup();
      for (final bill in [
        {
          'id': 'first',
          'date': '2026-10-01',
          'generated_at': '2026-10-01T10:15:00',
          'total_minor': 15001,
        },
        {
          'id': 'second',
          'date': '2026-10-01',
          'generated_at': '2026-10-01T19:00:00',
          'total_minor': 20000,
        },
        {
          'id': 'third',
          'date': '2026-10-03',
          'generated_at': '2026-10-03T20:00:00',
          'total_minor': 35000,
        },
      ]) {
        await LocalStore.put(session.local!.db, 'bills', bill);
      }
      await LocalStore.put(session.local!.db, 'orders', {
        'id': 'open',
        'status': 'open',
        'total_minor': 999999,
      });
      final report = await LocalReports(session.local!)
          .analytics('2026-10-01', '2026-10-03');
      final rows = dailyAnalyticsSeries(
        '2026-10-01',
        '2026-10-03',
        maps(report['daily']),
      );
      expect(rows[0]['bills'], 2);
      expect(rows[1]['revenue_minor'], 0);
      expect(
        rows.fold<int>(0, (sum, row) => sum + number(row['revenue_minor'])),
        report['summary']['revenue_minor'],
      );
      expect(rows.fold<int>(0, (sum, row) => sum + number(row['bills'])), 3);
      expect(report['summary']['revenue_minor'], 70001);
      await session.local!.db.close();
      session.dispose();
    },
  );

  testWidgets(
    'graph fits 320px and supports bar, bill count and selecting a day',
    (tester) async {
      fixture.mobile(tester);
      String? selected;
      final rows = dailyAnalyticsSeries('2026-10-01', '2026-10-30', [
        {'day': '2026-10-15', 'bills': 2, 'revenue_minor': 12345},
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AnalyticsChart(
                title: 'Daily sales trend',
                rows: rows,
                onOpenDay: (day) => selected = day,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Bars'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bill count'));
      await tester.pumpAndSettle();
      final chart = find.byKey(const ValueKey('Daily sales trend-plot'));
      await tester.tapAt(tester.getTopLeft(chart) + const Offset(54, 80));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('View this day'));
      await tester.tap(find.text('View this day'));
      expect(selected, '2026-10-01');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'analytics retains owner verification and yesterday uses exactly one day',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = (await tester.runAsync(fixture.setup))!;
      await tester.runAsync(
        () => LocalStore.put(session.local!.db, 'settings', {
          'id': 'settings',
          'invoice_delete_code_hash': sha256
              .convert(utf8.encode('1234'))
              .toString(),
        }),
      );
      await tester.pumpWidget(MaterialApp(home: AnalyticsPage(session)));
      await tester.pumpAndSettle();
      expect(find.text('Verify owner code'), findsOneWidget);
      expect(find.text('Daily sales trend'), findsNothing);
      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('Open analytics'));
      await fixture.settleDb(tester);
      expect(find.text('Daily sales trend'), findsOneWidget);
      await tester.tap(find.text('Yesterday'));
      await fixture.settleDb(tester);
      final yesterday = day(indiaNow().subtract(const Duration(days: 1)));
      expect(
        find.text('$yesterday to $yesterday · Asia/Kolkata'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<AnalyticsChart>(find.byType(AnalyticsChart).first)
            .rows
            .length,
        1,
      );
      expect(tester.takeException(), isNull);
      await fixture.close(tester, session);
    },
  );
}
