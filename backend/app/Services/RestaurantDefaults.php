<?php

namespace App\Services;

use App\Models\User;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Installs the starter catalog for a restaurant without replacing anything
 * the owner has already created. New accounts call this automatically; the
 * artisan command can safely run it for an existing empty account as well.
 */
final class RestaurantDefaults
{
    public static function installFor(User $owner): void
    {
        DB::transaction(function () use ($owner): void {
            $tenant = $owner->tenantId();
            $now = now();

            for ($number = 1; $number <= 16; $number++) {
                $tableNumber = 'T'.str_pad((string) $number, 2, '0', STR_PAD_LEFT);
                $exists = DB::table('tables')
                    ->where('user_id', $tenant)
                    ->where('table_number', $tableNumber)
                    ->whereNull('deleted_at')
                    ->exists();

                if ($exists) {
                    continue;
                }

                $id = (string) Str::uuid();
                DB::table('tables')->insert([
                    'id' => $id,
                    'user_id' => $tenant,
                    'table_number' => $tableNumber,
                    'section' => 'Ground Floor',
                    'capacity' => 4,
                    'status' => 'empty',
                    'current_order_id' => null,
                    'version' => 1,
                    'created_at' => $now,
                    'updated_at' => $now,
                ]);
                Records::emit('tables', $tenant, $id);
            }

            $catalog = json_decode(
                file_get_contents(base_path('database/data/avtar_cooks_menu.json')),
                true,
                512,
                JSON_THROW_ON_ERROR,
            );
            // Keep this as a separate category so bottled water and cold
            // drinks are quick to find at the POS. Existing owner items are
            // never replaced by the installer.
            $catalog[] = [
                'name' => 'Water Bottle (1 L)',
                'price_minor' => 2000,
                'category' => 'Water & Cold Drinks',
            ];
            $catalog[] = [
                'name' => 'Cold Drink - Add MRP',
                'price_minor' => 0,
                'category' => 'Water & Cold Drinks',
            ];

            foreach ($catalog as $index => $item) {
                $exists = DB::table('menu_items')
                    ->where('user_id', $tenant)
                    ->where('name', $item['name'])
                    ->where('category', $item['category'])
                    ->whereNull('deleted_at')
                    ->exists();

                if ($exists) {
                    continue;
                }

                $id = (string) Str::uuid();
                DB::table('menu_items')->insert([
                    'id' => $id,
                    'user_id' => $tenant,
                    'name' => $item['name'],
                    'price_minor' => (int) $item['price_minor'],
                    'category' => $item['category'],
                    'short_code' => 'M'.str_pad((string) ($index + 1), 3, '0', STR_PAD_LEFT),
                    'is_active' => true,
                    'is_veg' => true,
                    'version' => 1,
                    'created_at' => $now,
                    'updated_at' => $now,
                ]);
                Records::emit('menu_items', $tenant, $id);
            }

            if (!DB::table('settings')->where('user_id', $tenant)->exists()) {
                $id = (string) Str::uuid();
                DB::table('settings')->insert([
                    'id' => $id,
                    'user_id' => $tenant,
                    'restaurant_name' => $owner->restaurant_name ?: $owner->name,
                    'printer_port' => 9100,
                    'printer_paper_width' => '80mm',
                    'is_tax_enabled' => false,
                    'tax_basis_points' => 0,
                    'default_discount_basis_points' => 0,
                    'timezone' => 'Asia/Kolkata',
                    'version' => 1,
                    'created_at' => $now,
                    'updated_at' => $now,
                ]);
                Records::emit('settings', $tenant, $id);
            }
        });
    }
}
