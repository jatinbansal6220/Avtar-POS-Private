import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/shared.dart';

enum PremiumFeature { dishProfit, upselling, loyalty, staffLogin }

extension PremiumFeatureDetails on PremiumFeature {
  String get title => switch (this) {
    PremiumFeature.dishProfit => 'Dish-wise profit',
    PremiumFeature.upselling => 'Smart upselling',
    PremiumFeature.loyalty => 'Customer loyalty',
    PremiumFeature.staffLogin => 'Staff login',
  };
  IconData get icon => switch (this) {
    PremiumFeature.dishProfit => Icons.insights_outlined,
    PremiumFeature.upselling => Icons.auto_awesome_outlined,
    PremiumFeature.loyalty => Icons.loyalty_outlined,
    PremiumFeature.staffLogin => Icons.badge_outlined,
  };
  String get benefit => switch (this) {
    PremiumFeature.dishProfit =>
      'Know which dishes earn more, not just which dishes sell more.',
    PremiumFeature.upselling =>
      'Suggest the right add-on while your team takes an order.',
    PremiumFeature.loyalty =>
      'Give customers a reason to choose your restaurant again.',
    PremiumFeature.staffLogin =>
      'Give each staff member their own sign-in and permissions.',
  };
  String get example => switch (this) {
    PremiumFeature.dishProfit => 'Selling price ₹200 → ingredient margin ₹130',
    PremiumFeature.upselling => 'Burger ₹149 → suggested combo ₹249',
    PremiumFeature.loyalty => 'Earn points → redeem rewards → return again',
    PremiumFeature.staffLogin => 'Waiter / Cashier / Manager access',
  };
  List<String> get capabilities => switch (this) {
    PremiumFeature.dishProfit => [
      'Set a recipe and ingredient quantities for each dish.',
      'Calculate ingredient cost, selling price and ingredient margin per dish.',
      'Compare popular dishes with high-margin dishes and review cost changes.',
      'Ingredient margin is before wages, rent, tax and other operating costs; it is not net profit.',
    ],
    PremiumFeature.upselling => [
      'Configure add-ons and combo offers for selected dishes.',
      'Show the suggestion to the cashier or waiter during order entry.',
      'Staff accepts or skips the suggestion; nothing is added automatically.',
      'Track accepted suggestions and the extra sales they generate.',
    ],
    PremiumFeature.loyalty => [
      'Link a customer profile to bills with the customer’s permission.',
      'Configure points earned per purchase and reward redemption rules.',
      'Show reward balance and repeat-visit history during checkout.',
      'Offer birthday or return-visit rewards; promotional messages require customer consent.',
    ],
    PremiumFeature.staffLogin => [
      'Create an individual staff sign-in and assign a role.',
      'Allow waiters to take orders and cashiers to collect payments.',
      'Keep discounts, refunds and day closing behind configured permissions.',
      'Record which signed-in staff member performed an action. Existing staff records remain separate.',
    ],
  };
}

const _developerPhone = '95307-76295';

Future<void> _contactDeveloper(BuildContext context) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    scrollable: true,
    title: const Text('Contact developer to allow access'),
    content: const Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'These features are locked previews. Contact the developer to discuss availability and activation.',
        ),
        SizedBox(height: 16),
        SelectableText(
          _developerPhone,
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      FilledButton.icon(
        onPressed: () async {
          await Clipboard.setData(const ClipboardData(text: _developerPhone));
          if (context.mounted) message(context, 'Developer contact copied.');
        },
        icon: const Icon(Icons.copy_outlined),
        label: const Text('Copy contact'),
      ),
    ],
  ),
);

Future<void> _openPreview(BuildContext context, PremiumFeature feature) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: const Text('Contact developer to unlock features'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_outline, color: accent, size: 36),
          const SizedBox(height: 16),
          Text(
            '${feature.title} is locked. You can explore a sample of how it would work.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Demo only. It does not change orders, bills, customer points or staff accounts.',
          ),
          const SizedBox(height: 12),
          const Text('Contact developer to allow access: $_developerPhone'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('View demo'),
        ),
      ],
    ),
  );
  if (accepted == true && context.mounted) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: '/premium-preview/${feature.name}'),
        builder: (_) => PremiumFeatureDemoPage(feature: feature),
      ),
    );
  }
}

/// Owner-facing previews only. No Session, database or API access is used here.
class LockedFeaturesPage extends StatelessWidget {
  const LockedFeaturesPage({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      _Entrance(
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              colors: [deepIndigo, Color(0xFF111827)],
            ),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Badge('OWNER EXCLUSIVES', dark: true),
              SizedBox(height: 18),
              Text(
                'See what your restaurant\ncould do next.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
              SizedBox(height: 14),
              Text(
                'Four locked features. Four interactive previews. Explore the workflow before requesting access.',
                style: TextStyle(color: Color(0xFFCBD5E1), height: 1.5),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      Text(
        'Premium feature previews',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 8),
      const Text(
        'Sample data only · All four features remain locked',
        style: TextStyle(color: secondaryText),
      ),
      const SizedBox(height: 20),
      LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth >= 700
              ? (box.maxWidth - 16) / 2
              : box.maxWidth;
          return Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final feature in PremiumFeature.values)
                SizedBox(
                  width: width,
                  child: _Entrance(
                    child: Card(
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: lightIndigo,
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  child: Icon(
                                    feature.icon,
                                    color: accent,
                                    size: 28,
                                  ),
                                ),
                                const Spacer(),
                                const _Badge(
                                  'LOCKED',
                                  icon: Icons.lock_outline,
                                ),
                              ],
                            ),
                            const SizedBox(height: 20),
                            Text(
                              feature.title,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              feature.benefit,
                              style: const TextStyle(
                                color: secondaryText,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              feature.example,
                              style: const TextStyle(
                                color: darkIndigo,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () => _openPreview(context, feature),
                                icon: const Icon(Icons.play_circle_outline),
                                label: Text('Preview ${feature.title}'),
                              ),
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
      ),
      const SizedBox(height: 24),
      _ContactCard(),
    ],
  );
}

class PremiumFeatureDemoPage extends StatefulWidget {
  final PremiumFeature feature;
  const PremiumFeatureDemoPage({super.key, required this.feature});
  @override
  State<PremiumFeatureDemoPage> createState() => _PremiumFeatureDemoPageState();
}

class _PremiumFeatureDemoPageState extends State<PremiumFeatureDemoPage> {
  bool combo = false, staffSignedIn = false;
  int loyaltyStep = 0;
  String role = 'Waiter';

  Widget _metrics(List<(String, String)> values) => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      for (final item in values)
        Container(
          width: 185,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: lightIndigo,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.$1, style: const TextStyle(color: secondaryText)),
              const SizedBox(height: 8),
              Text(
                item.$2,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: deepIndigo,
                ),
              ),
            ],
          ),
        ),
    ],
  );

  Widget _sample() => switch (widget.feature) {
    PremiumFeature.dishProfit => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Sample dish · Paneer tikka',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        _metrics([
          ('Selling price', '₹200'),
          ('Ingredient cost', '₹70'),
          ('Ingredient margin', '₹130'),
        ]),
        const SizedBox(height: 20),
        const Text(
          '65% ingredient margin',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: .65),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 650),
          builder: (_, value, _) => LinearProgressIndicator(
            value: value,
            minHeight: 10,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Example: ₹200 − ₹70 = ₹130 before other costs. Recipe costs would be configured by the restaurant; these numbers are illustrative.',
        ),
      ],
    ),
    PremiumFeature.upselling => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Sample ticket · Burger ₹149',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        _metrics([
          ('Ticket total', combo ? '₹249' : '₹149'),
          ('Added sale', combo ? '+₹100' : '₹0'),
        ]),
        const SizedBox(height: 16),
        const Text(
          'Suggested offer: add fries and a drink for a ₹249 combo. Separate example prices total ₹267; the combo saves ₹18.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => setState(() => combo = !combo),
          icon: Icon(combo ? Icons.undo : Icons.add),
          label: Text(combo ? 'Reset sample ticket' : 'Try combo suggestion'),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Text(
            combo
                ? 'DEMO: fries + drink added to the sample ticket.'
                : 'DEMO: cashier chooses whether to offer the combo.',
            key: ValueKey(combo),
            style: const TextStyle(color: darkIndigo),
          ),
        ),
      ],
    ),
    PremiumFeature.loyalty => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Sample customer · Demo Guest',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        _metrics([
          ('Reward balance', '${[120, 170, 70][loyaltyStep]} points'),
          ('Sample bill', '₹500'),
        ]),
        const SizedBox(height: 16),
        const Text(
          'Example rules: earn 1 point per ₹10 spent; redeem 100 points for a ₹50 reward. Rules would be set by the owner.',
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton(
              onPressed: loyaltyStep == 0
                  ? () => setState(() => loyaltyStep = 1)
                  : null,
              child: const Text('Try earning 50 points'),
            ),
            OutlinedButton(
              onPressed: loyaltyStep == 1
                  ? () => setState(() => loyaltyStep = 2)
                  : null,
              child: const Text('Try ₹50 reward'),
            ),
            TextButton(
              onPressed: () => setState(() => loyaltyStep = 0),
              child: const Text('Reset demo'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          'DEMO: no real bill is discounted, no customer balance is saved and no messages are sent.',
          style: TextStyle(color: darkIndigo),
        ),
      ],
    ),
    PremiumFeature.staffLogin => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Sample staff sign-in',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final choice in ['Waiter', 'Cashier', 'Manager'])
              ChoiceChip(
                label: Text(choice),
                selected: role == choice,
                onSelected: (_) => setState(() {
                  role = choice;
                  staffSignedIn = false;
                }),
              ),
          ],
        ),
        const SizedBox(height: 18),
        const Text(
          'Demo staff · PIN ••••',
          style: TextStyle(color: secondaryText),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => setState(() => staffSignedIn = true),
          icon: const Icon(Icons.login),
          label: const Text('Preview staff sign-in'),
        ),
        const SizedBox(height: 16),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: Text(
            staffSignedIn
                ? 'DEMO: signed in as $role'
                : 'Choose a role to preview its access.',
            key: ValueKey('$role/$staffSignedIn'),
            style: const TextStyle(
              color: darkIndigo,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(switch (role) {
          'Waiter' => 'Sample access: take orders and send KOTs. No payment collection, discounts or refunds.',
          'Cashier' => 'Sample access: collect payments and view bills. Discounts and refunds need manager permission.',
          _ => 'Sample access: approve discounts and refunds, review staff actions and close the day.',
        }),
        const SizedBox(height: 12),
        const Text(
          'This is a simulated sign-in. It does not authenticate staff or grant access to the POS.',
          style: TextStyle(color: secondaryText),
        ),
      ],
    ),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.feature.title)),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _Entrance(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Badge(
                    'LOCKED · INTERACTIVE DEMO',
                    icon: Icons.lock_outline,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    widget.feature.benefit,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Preview only. Actual access is locked. Contact developer to allow access.',
                    style: TextStyle(color: secondaryText, height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: _sample(),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'What this feature would include',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            for (final (index, text) in widget.feature.capabilities.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: lightIndigo,
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(color: darkIndigo, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(text, style: const TextStyle(height: 1.5)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            _ContactCard(),
          ],
        ),
      ),
    ),
  );
}

class _ContactCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: lightIndigo,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Contact developer to allow access',
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 17,
            color: deepIndigo,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Software enquiry · $_developerPhone',
          style: TextStyle(color: darkIndigo),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _contactDeveloper(context),
          icon: const Icon(Icons.support_agent),
          label: const Text('Contact developer'),
        ),
      ],
    ),
  );
}

class _Badge extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool dark;
  const _Badge(this.label, {this.icon, this.dark = false});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: dark ? Colors.white.withValues(alpha: .12) : lightIndigo,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: dark ? Colors.white : darkIndigo),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: .8,
              color: dark ? Colors.white : darkIndigo,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Entrance extends StatelessWidget {
  final Widget child;
  const _Entrance({required this.child});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 450),
    child: child,
    builder: (_, value, child) => Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(0, 14 * (1 - value)),
        child: child,
      ),
    ),
  );
}
