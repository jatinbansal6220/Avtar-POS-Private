import 'package:flutter/material.dart';

import '../core/session.dart';
import '../features/auth/reauth_page.dart';
import '../features/tables/floor_page.dart';
import '../features/orders/data/order_draft.dart';
import '../features/orders/order_workspace_page.dart';
import '../features/staff/staff_directory_page.dart';
import '../features/menu/menu_catalog_page.dart';
import '../features/purchases/purchase_dashboard.dart';
import '../features/inventory/inventory_page.dart';
import '../features/sync/sync_page.dart';
import 'records_page.dart';
import 'settings_page.dart';
import 'analytics.dart';
import '../features/analytics/closing_page.dart';
import 'shared.dart';
import 'brand_splash.dart';
import '../features/developer/feature_access.dart';
import '../features/premium/locked_features_page.dart';

class HomePage extends StatefulWidget {
  final Session session;
  const HomePage(this.session, {super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selected = 0;

  Future<void> _openLogoutMenu(Session session) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Account'),
        content: const Text('Choose an account action.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Back'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await _showUnderMaintenance('Change Gmail address');
            },
            child: const Text('Change Gmail address'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await _showUnderMaintenance('Change password');
            },
            child: const Text('Change password'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              try {
                await session.logout();
                if (mounted) {
                  await openPage(context, const BrandSplash(closing: true));
                }
              } catch (error) {
                if (mounted) message(context, error);
              }
            },
            child: const Text('Logout'),
          ),
        ],
      ),
    );
  }

  Future<void> _showUnderMaintenance(String action) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(action),
      content: const Text('This option is under maintenance.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Back'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    return LayoutBuilder(
      builder: (context, box) {
        final desktop = box.maxWidth >= 1000;
        final allEntries = <(String, IconData, Widget)>[
          ('Tables', Icons.grid_view_outlined, FloorPage(s)),
          (
            'Menu POS',
            Icons.restaurant_menu_outlined,
            OrderWorkspacePage(s, newOrder(channel: 'pos'), embedded: true),
          ),
          ('Invoices', Icons.receipt_outlined, RecordsPage(s, 'bills')),
          if (s.manager)
            ('Purchases', Icons.shopping_bag_outlined, PurchaseDashboard(s)),
          if (s.manager)
            ('Inventory', Icons.inventory_2_outlined, InventoryPage(s)),
          if (s.manager) ('Catalog', Icons.layers_outlined, MenuCatalogPage(s)),
          if (s.manager)
            ('Staff', Icons.groups_outlined, StaffDirectoryPage(s)),
          if (s.manager)
            (
              'Day closing',
              Icons.account_balance_wallet_outlined,
              ClosingPage(s),
            ),
          if (s.manager)
            ('Analytics', Icons.bar_chart_outlined, AnalyticsPage(s)),
          if (s.manager) ('Settings', Icons.settings_outlined, SettingsPage(s)),
          if (s.user?['role'] == 'owner')
            (
              'Premium previews',
              Icons.workspace_premium_outlined,
              const LockedFeaturesPage(),
            ),
        ];
        const entryFeatures = {
          'Tables': 'tables',
          'Menu POS': 'pos',
          'Invoices': 'invoices',
          'Purchases': 'purchases',
          'Inventory': 'inventory',
          'Catalog': 'catalog',
          'Staff': 'staff',
          'Day closing': 'closing',
          'Analytics': 'analytics',
          'Settings': 'settings',
        };
        final entries = allEntries;
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: 52,
            title: Row(
              children: [
                const CircleAvatar(
                  radius: 16,
                  backgroundColor: accent,
                  child: Text(
                    'RP',
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    s.user?['restaurant_name'] ?? 'Avtar POS',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: ink,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton.icon(
                onPressed: () =>
                    openPage(context, s.expired ? ReauthPage(s) : SyncPage(s)),
                icon: Icon(
                  s.expired
                      ? Icons.lock_clock_outlined
                      : s.conflicts > 0
                      ? Icons.warning_amber_rounded
                      : s.online
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off,
                  size: 18,
                ),
                label: Text(
                  s.expired
                      ? 'Sign in again'
                      : s.conflicts > 0
                      ? '${s.conflicts} need review'
                      : s.queued > 0
                      ? '${s.queued} pending'
                      : s.online
                      ? 'Synced'
                      : 'Offline',
                ),
              ),
              IconButton(
                tooltip: 'Sign out',
                onPressed: () => _openLogoutMenu(s),
                icon: const Icon(Icons.logout, size: 19),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Row(
            children: [
              if (desktop) ...[
                NavigationRail(
                  scrollable: true,
                  trailingAtBottom: true,
                  extended: box.maxWidth > 1300,
                  minExtendedWidth: 190,
                  backgroundColor: Colors.white,
                  unselectedIconTheme: const IconThemeData(
                    color: secondaryText,
                  ),
                  unselectedLabelTextStyle: const TextStyle(
                    color: secondaryText,
                  ),
                  selectedIconTheme: const IconThemeData(color: accent),
                  selectedLabelTextStyle: const TextStyle(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                  selectedIndex: selected,
                  onDestinationSelected: (v) => setState(() => selected = v),
                  destinations: entries
                      .map(
                        (e) => NavigationRailDestination(
                          icon: Icon(e.$2),
                          label: Text(e.$1),
                        ),
                      )
                      .toList(),
                  trailing: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      '${s.user?['role']}'.toUpperCase(),
                      style: const TextStyle(fontSize: 10, letterSpacing: 2),
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
              ],
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: KeyedSubtree(
                    key: ValueKey(selected),
                    child: entryFeatures[entries[selected].$1] == null
                        ? entries[selected].$3
                        : FeatureAccess(
                            session: s,
                            feature: entryFeatures[entries[selected].$1]!,
                            child: entries[selected].$3,
                          ),
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: desktop
              ? null
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: entries.length * 88.0,
                    child: NavigationBar(
                      selectedIndex: selected,
                      onDestinationSelected: (v) =>
                          setState(() => selected = v),
                      destinations: entries
                          .map(
                            (e) => NavigationDestination(
                              icon: Icon(e.$2),
                              label: e.$1,
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
