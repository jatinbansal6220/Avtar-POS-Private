import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../core/feature_policy.dart';
import 'developer_panel.dart';
import '../../ui/records_page.dart';
import '../../ui/record_editor_page.dart';
import '../../ui/settings_page.dart';
import '../../ui/staff.dart';
import '../../ui/analytics.dart';
import '../../ui/receipt.dart';
import '../tables/floor_page.dart';
import '../orders/order_workspace_page.dart';
import '../orders/order_details_page.dart';
import '../orders/item_editor_page.dart';
import '../orders/kot_page.dart';
import '../menu/menu_catalog_page.dart';
import '../staff/staff_directory_page.dart';
import '../purchases/purchases_page.dart';
import '../purchases/purchase_history_page.dart';
import '../inventory/inventory_page.dart';
import '../analytics/closing_page.dart';
import '../billing/checkout_page.dart';
import '../billing/settlement_page.dart';
import '../banks/upi_accounts_page.dart';

class ControlScope extends InheritedWidget {
  final Session session;
  const ControlScope({super.key, required this.session, required super.child});
  static Session? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ControlScope>()?.session;
  @override
  bool updateShouldNotify(ControlScope oldWidget) =>
      oldWidget.session != session;
}

/// Keep the underlying screen mounted so remote policy changes cannot throw
/// away an in-progress draft or its outstanding local SQLite write.
class FeatureAccess extends StatelessWidget {
  final Session session;
  final String feature;
  final Widget child;
  const FeatureAccess({
    super.key,
    required this.session,
    required this.feature,
    required this.child,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: session,
    builder: (context, _) {
      final allowed = session.featureEnabled(feature);
      return Stack(
        children: [
          Positioned.fill(
            child: ExcludeFocus(
              excluding: !allowed,
              child: Offstage(offstage: !allowed, child: child),
            ),
          ),
          if (!allowed)
            Positioned.fill(
              child: Scaffold(
                appBar: AppBar(title: const Text('Feature unavailable')),
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${developerFeatures[feature] ?? feature} is disabled by the developer.',
                          textAlign: TextAlign.center,
                        ),
                        TextButton(
                          onPressed: () => openDeveloperPanel(context, session),
                          child: const Text('Developer access'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

String? pageFeature(Widget page) => switch (page) {
  RecordsPage() => resourceFeature(page.resource),
  RecordEditor() => resourceFeature(page.resource),
  OrderWorkspacePage() => page.session.orderFeature(page.order),
  OrderDetailsPage() || ItemEditorPage() => 'order_edit',
  FloorPage() => 'tables',
  SettingsPage() => 'settings',
  MenuCatalogPage() => 'catalog',
  StaffPage() || StaffDirectoryPage() => 'staff',
  PurchasesPage() || PurchaseHistoryPage() => 'purchases',
  InventoryPage() || InventoryItemPage() => 'inventory',
  AnalyticsPage() => 'analytics',
  ClosingPage() => 'closing',
  KotPage() => 'kot',
  CheckoutPage() || ReceiptPage() || SettlementPage() => 'invoices',
  UpiAccountsPage() => 'banks',
  _ => null,
};
