import 'package:flutter/material.dart';

import 'data/order_controller.dart';
import 'online_platform_picker.dart';
import '../../ui/shared.dart';

class OrderDetailsPage extends StatefulWidget {
  final OrderController controller;
  const OrderDetailsPage(this.controller, {super.key});
  @override
  State<OrderDetailsPage> createState() => _OrderDetailsPageState();
}

class _OrderDetailsPageState extends State<OrderDetailsPage> {
  late final name = TextEditingController(
    text: widget.controller.order['customer_name'] ?? '',
  );
  late final phone = TextEditingController(
    text: widget.controller.order['customer_phone'] ?? '',
  );
  late final notes = TextEditingController(
    text: widget.controller.order['notes'] ?? '',
  );
  bool saving = false;
  late String platform = widget.controller.order['online_platform'] ?? 'direct';
  late final platformName = TextEditingController(
    text: widget.controller.order['online_platform_name'] ?? '',
  );
  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    notes.dispose();
    platformName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Order details')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Customer name'),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone'),
            ),
            const SizedBox(height: 20),
            if (widget.controller.order['order_type'] == 'online') ...[
              DropdownButtonFormField<String>(
                initialValue: platform,
                decoration: const InputDecoration(labelText: 'Order platform'),
                items: ['direct', 'swiggy', 'zomato', 'other']
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) => setState(() => platform = v!),
              ),
              if (platform == 'other') ...[
                const SizedBox(height: 20),
                TextField(
                  controller: platformName,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Platform name'),
                ),
              ],
              const SizedBox(height: 20),
            ],
            TextField(
              controller: notes,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Kitchen / order notes',
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (saving) return;
                      setState(() => saving = true);
                      FocusScope.of(context).unfocus();
                      try {
                        widget.controller.change(() {
                          widget.controller.order['customer_name'] = name.text;
                          widget.controller.order['customer_phone'] =
                              phone.text;
                          widget.controller.order['notes'] = notes.text;
                          if (widget.controller.order['order_type'] ==
                              'online') {
                            widget.controller.order['online_platform'] =
                                platform;
                            widget.controller.order['online_platform_name'] =
                                platform == 'other'
                                ? platformName.text.trim()
                                : switch (platform) {
                                    'zomato' => 'Zomato',
                                    'swiggy' => 'Swiggy',
                                    'direct' => 'Direct online order',
                                    _ => platformName.text.trim(),
                                  };
                          }
                        });
                        if (widget.controller.order['order_type'] == 'online' &&
                            platform == 'other') {
                          await rememberOnlinePlatform(
                            widget.controller.session,
                            platformName.text,
                          );
                        }
                        await widget.controller.flush();
                        if (context.mounted) Navigator.pop(context);
                      } catch (error) {
                        if (context.mounted) message(context, error);
                      } finally {
                        if (mounted) setState(() => saving = false);
                      }
                    },
              child: Text(saving ? 'Saving details…' : 'Save details'),
            ),
          ],
        ),
      ),
    ),
  );
}
