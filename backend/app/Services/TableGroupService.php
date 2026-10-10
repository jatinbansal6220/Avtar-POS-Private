<?php

namespace App\Services;

use Illuminate\Support\Facades\DB;

/**
 * Keeps dining-table transfers and joins atomic. A joined party deliberately
 * owns one shared cart, regardless of which joined table the cashier opens.
 */
final class TableGroupService
{
    private function ids(array $order, string $field, string $ownId): array
    {
        $value = $order[$field] ?? [];
        if (is_string($value)) $value = json_decode($value, true) ?: [];
        return array_values(array_unique(array_filter([
            $ownId,
            ...(is_array($value) ? $value : []),
        ], fn ($id) => is_string($id) && $id !== '')));
    }

    private function primary(int $tenant, array $order): array
    {
        if (!empty($order['merged_into_order_id'])) {
            return Records::get('orders', $tenant, $order['merged_into_order_id']);
        }
        return $order;
    }

    private function requireOpenDining(array $order, int $version): void
    {
        abort_unless($order['status'] === 'open', 409, 'Order changed or closed.');
        abort_unless((int) $order['version'] === $version, 409, 'Order changed on another device. Refresh and try again.');
        abort_unless($order['order_type'] === 'dine_in' && !empty($order['table_id']), 422, 'Only a dining-table order can use this action.');
    }

    /** Combine matching catalog lines so a shared cart never bills a dish twice. */
    private function sharedCartLines(array $members, string $primaryOrderId, string $sourceTableNumber): array
    {
        $lines=[];
        foreach ($members as $member) foreach ($member['items'] as $item) {
            $key=(!empty($item['combo_id']) ? 'combo:' : 'menu:').($item['combo_id'] ?? $item['menu_item_id']).'|'.($item['price_minor'] ?? 0).'|'.($item['notes'] ?? '').'|'.($item['discount_type'] ?? 'percent').'|'.($item['discount_value'] ?? 0);
            if (isset($lines[$key])) {
                $lines[$key]['quantity']+=(int)$item['quantity'];
                continue;
            }
            $lines[$key]=[
                'id'=>$item['id'], 'order_id'=>$primaryOrderId,
                'menu_item_id'=>$item['menu_item_id'] ?? null, 'combo_id'=>$item['combo_id'] ?? null,
                'item_name'=>$item['item_name'], 'source_table_number'=>$sourceTableNumber,
                'quantity'=>(int)$item['quantity'], 'price_minor'=>(int)$item['price_minor'],
                'notes'=>$item['notes'] ?? null, 'discount_type'=>$item['discount_type'] ?? 'percent',
                'discount_value'=>(int)($item['discount_value'] ?? 0), 'components'=>$item['components'] ?? null,
            ];
        }
        return array_values($lines);
    }

    public function transfer(int $tenant, string $id, array $input): array
    {
        return DB::transaction(function () use ($tenant, $id, $input): array {
            $order = $this->primary($tenant, Records::get('orders', $tenant, $id));
            $this->requireOpenDining($order, (int) $input['version']);
            abort_if(count($this->ids($order, 'merged_table_ids', $order['table_id'])) > 1, 422, 'Separate the joined tables before changing the table.');

            $source = Records::get('tables', $tenant, $order['table_id']);
            $target = Records::get('tables', $tenant, $input['target_table_id']);
            abort_if($source['id'] === $target['id'], 422, 'This order is already on this table.');
            abort_if(!empty($target['current_order_id']) || $target['status'] !== 'empty', 409, 'The destination table already has an active order.');

            DB::table('orders')->where('id', $order['id'])->update([
                'table_id' => $target['id'],
                'table_number' => $target['table_number'],
                'version' => $order['version'] + 1,
                'updated_at' => now(),
            ]);
            DB::table('order_items')->where('order_id', $order['id'])->update([
                'source_table_number' => $target['table_number'],
            ]);
            DB::table('tables')->where('id', $source['id'])->update([
                'status' => 'empty', 'current_order_id' => null,
                'version' => DB::raw('version + 1'), 'updated_at' => now(),
            ]);
            DB::table('tables')->where('id', $target['id'])->update([
                'status' => 'occupied', 'current_order_id' => $order['id'],
                'version' => DB::raw('version + 1'), 'updated_at' => now(),
            ]);
            Records::emit('tables', $tenant, $source['id']);
            Records::emit('tables', $tenant, $target['id']);
            Records::emit('orders', $tenant, $order['id']);
            return Records::get('orders', $tenant, $order['id']);
        });
    }

    public function merge(int $tenant, string $id, array $input): array
    {
        return DB::transaction(function () use ($tenant, $id, $input): array {
            $primary = $this->primary($tenant, Records::get('orders', $tenant, $id));
            $this->requireOpenDining($primary, (int) $input['version']);
            $targetTable = Records::get('tables', $tenant, $input['target_table_id']);
            abort_if($targetTable['id'] === $primary['table_id'], 422, 'Choose a different table to merge.');
            // An occupied order may reserve an adjacent empty table for the
            // same party. Such a table joins the group without manufacturing
            // an empty child order or duplicating any receipt items.
            $target = empty($targetTable['current_order_id'])
                ? null
                : $this->primary($tenant, Records::get('orders', $tenant, $targetTable['current_order_id']));
            if ($target !== null) {
                abort_if($target['id'] === $primary['id'], 422, 'These tables are already joined.');
                abort_unless($target['status'] === 'open', 409, 'The selected table order is closed.');
            } else {
                abort_unless(($targetTable['status'] ?? 'empty') === 'empty', 409, 'The selected table is no longer available.');
            }

            $primaryOrders = $this->ids($primary, 'merged_order_ids', $primary['id']);
            $targetOrders = $target === null ? [] : $this->ids($target, 'merged_order_ids', $target['id']);
            abort_if(array_intersect($primaryOrders, $targetOrders), 422, 'These tables are already joined.');
            $tableIds = array_values(array_unique([
                ...$this->ids($primary, 'merged_table_ids', $primary['table_id']),
                ...($target === null ? [$targetTable['id']] : $this->ids($target, 'merged_table_ids', $target['table_id'])),
            ]));
            $orderIds = array_values(array_unique([...$primaryOrders, ...$targetOrders]));
            $tables = [];
            foreach ($tableIds as $tableId) $tables[$tableId] = Records::get('tables', $tenant, $tableId);
            $numbers = array_map(fn (string $tableId): string => $tables[$tableId]['table_number'], $tableIds);
            $members = [];
            foreach ($orderIds as $orderId) {
                $member = Records::get('orders', $tenant, $orderId);
                $members[] = $member;
            }
            $lines=$this->sharedCartLines($members,$primary['id'],$primary['table_number']);
            $subtotal=array_sum(array_map(fn(array $line): int => $line['quantity']*$line['price_minor'],$lines));

            DB::table('orders')->where('id', $primary['id'])->update([
                'merged_table_ids' => json_encode($tableIds),
                'merged_table_numbers' => json_encode($numbers),
                'merged_order_ids' => json_encode($orderIds),
                'merged_into_order_id' => null,
                'subtotal_minor' => $subtotal,
                'version' => $primary['version'] + 1,
                'updated_at' => now(),
            ]);
            // Move every line into the primary once. Child orders remain only
            // as table-membership records, so the same dish cannot appear
            // again when the final invoice loops over merged order ids.
            DB::table('order_items')->whereIn('order_id',$orderIds)->delete();
            if ($lines) DB::table('order_items')->insert($lines);
            foreach (array_values(array_diff($orderIds, [$primary['id']])) as $childId) {
                DB::table('orders')->where('id', $childId)->update([
                    // The child identifies its original table only. All menu
                    // lines live in the primary shared cart.
                    'merged_table_ids' => json_encode($tableIds),
                    'merged_table_numbers' => json_encode($numbers),
                    'merged_order_ids' => json_encode($orderIds),
                    'merged_into_order_id' => $primary['id'],
                    'version' => DB::raw('version + 1'),
                    'updated_at' => now(),
                ]);
            }
            foreach ($tableIds as $tableId) {
                DB::table('tables')->where('id', $tableId)->update([
                    'status' => 'occupied',
                    'current_order_id' => $primary['id'],
                    'version' => DB::raw('version + 1'), 'updated_at' => now(),
                ]);
            }
            foreach ($tableIds as $tableId) Records::emit('tables', $tenant, $tableId);
            foreach ($orderIds as $orderId) Records::emit('orders', $tenant, $orderId);
            return Records::get('orders', $tenant, $primary['id']);
        });
    }

    public function unmerge(int $tenant, string $id, array $input): array
    {
        return DB::transaction(function () use ($tenant, $id, $input): array {
            $primary = $this->primary($tenant, Records::get('orders', $tenant, $id));
            $this->requireOpenDining($primary, (int) $input['version']);
            $orderIds = $this->ids($primary, 'merged_order_ids', $primary['id']);
            abort_if(count($orderIds) < 2, 422, 'These tables are not joined.');
            foreach ($orderIds as $orderId) {
                $order = Records::get('orders', $tenant, $orderId);
                abort_unless($order['status'] === 'open', 409, 'One joined order has already been closed.');
                DB::table('orders')->where('id', $orderId)->update([
                    'merged_table_ids' => null,
                    'merged_table_numbers' => null,
                    'merged_order_ids' => null,
                    'merged_into_order_id' => null,
                    'version' => DB::raw('version + 1'),
                    'updated_at' => now(),
                ]);
                DB::table('tables')->where('id', $order['table_id'])->update([
                    'status' => 'occupied', 'current_order_id' => $orderId,
                    'version' => DB::raw('version + 1'), 'updated_at' => now(),
                ]);
                Records::emit('tables', $tenant, $order['table_id']);
                Records::emit('orders', $tenant, $orderId);
            }
            return Records::get('orders', $tenant, $primary['id']);
        });
    }
}
