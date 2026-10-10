import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../core/models.dart';
import '../features/developer/feature_access.dart';

const ink = Color(0xFF111827);
const accent = Color(0xFF4F46E5);
const canvas = Color(0xFFF6F7FC);
const line = Color(0xFFE5E7EF);
const darkIndigo = Color(0xFF3730A3);
const deepIndigo = Color(0xFF312E81);
const lightIndigo = Color(0xFFEEF2FF);
const secondaryText = Color(0xFF64748B);
const focusIndigo = Color(0xFF818CF8);

class DesktopScrollBehavior extends MaterialScrollBehavior {
  const DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

ThemeData appTheme() => ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: canvas,
  colorScheme: ColorScheme.fromSeed(
    seedColor: accent,
    primary: accent,
    surface: Colors.white,
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.white,
    foregroundColor: ink,
    centerTitle: false,
    scrolledUnderElevation: 0,
  ),
  dividerTheme: const DividerThemeData(color: line, space: 1),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: line),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: focusIndigo, width: 2),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 50),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
  ),
  textTheme: const TextTheme(
    headlineMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    titleLarge: TextStyle(
      fontSize: 21,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: ink,
    ),
    bodyMedium: TextStyle(fontSize: 14, color: ink),
  ),
);

Future<T?> openPage<T>(BuildContext context, Widget page) {
  final session = ControlScope.maybeOf(context);
  final feature = pageFeature(page);
  return Navigator.of(context).push<T>(
    MaterialPageRoute(
      builder: (_) => session == null || feature == null
          ? page
          : FeatureAccess(session: session, feature: feature, child: page),
    ),
  );
}

void message(BuildContext context, Object error) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(error.toString()),
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

class EmptyState extends StatelessWidget {
  final String title, detail;
  final IconData icon;
  final Widget? action;
  const EmptyState(
    this.title,
    this.detail, {
    super.key,
    this.icon = Icons.inbox_outlined,
    this.action,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final content = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: accent),
            const SizedBox(height: 20),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54, height: 1.6),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      );

      // Narrow screens can wrap the message beyond the available height.
      // Keep it centred when it fits and allow scrolling when it does not.
      if (constraints.hasBoundedHeight) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(constraints.maxHeight < 240 ? 16 : 32),
                child: content,
              ),
            ),
          ),
        );
      }

      return Center(
        child: Padding(padding: const EdgeInsets.all(32), child: content),
      );
    },
  );
}

class StatusPill extends StatelessWidget {
  final String status;
  const StatusPill(this.status, {super.key});
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'occupied' => darkIndigo,
      'bill_pending' => deepIndigo,
      _ => accent,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status.replaceAll('_', ' ').toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class Metric extends StatelessWidget {
  final String label, value;
  const Metric(this.label, this.value, {super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 10),
        Text(value, style: Theme.of(context).textTheme.titleLarge),
      ],
    ),
  );
}

String recordTitle(String resource, Json row) =>
    '${row['name'] ?? row['account_name'] ?? row['item_name'] ?? row['bill_number'] ?? row['table_number'] ?? row['date'] ?? row['restaurant_name'] ?? resource}';
