<?php
namespace App\Services;

use Illuminate\Support\Facades\DB;

final class Records {
    public const RESOURCES = ['tables','table_bookings','purchase_categories','purchase_items','purchase_suppliers','purchase_bills','purchase_events','menu_items','combos','orders','bills','staff','attendance','staff_salary_adjustments','payments','settings','banks','purchases','inventory_items','inventory_entries','expenses'];
    public static function query(string $resource, int $tenant) {
        abort_unless(in_array($resource,self::RESOURCES,true),404);
        return DB::table($resource)->where('user_id',$tenant)->whereNull('deleted_at');
    }
    public static function get(string $resource, int $tenant, string $id): array {
        $row = self::query($resource,$tenant)->where('id',$id)->first();
        abort_unless($row,404,'Record not found.');
        return self::decode($resource,$row);
    }
    public static function decode(string $resource, object $row): array {
        $data = (array)$row;
        if ($resource === 'purchase_items' && is_string($data['reorder_levels'] ?? null)) $data['reorder_levels']=json_decode($data['reorder_levels'],true) ?: [];
        if (in_array($resource,['purchase_suppliers','purchase_bills','purchase_events'],true)) {
            $body=json_decode($data['data'],true); unset($data['data']);
            return array_merge($body,$data);
        }
        if ($resource === 'settings' && is_string($data['online_platforms'] ?? null)) {
            $data['online_platforms'] = json_decode($data['online_platforms'], true) ?: [];
        }
        if ($resource === 'orders') {
            $data['items'] = DB::table('order_items')->where('order_id',$row->id)->get()->map(fn($v)=>(array)$v)->all();
            if (is_string($data['voids'] ?? null)) $data['voids'] = json_decode($data['voids'], true) ?: [];
            foreach (['merged_table_ids','merged_table_numbers','merged_order_ids'] as $field) {
                if (is_string($data[$field] ?? null)) $data[$field] = json_decode($data[$field], true) ?: [];
            }
        }
        if ($resource === 'combos') $data['items'] = DB::table('combo_items')->where('combo_id',$row->id)->get()->map(fn($v)=>(array)$v)->all();
        if ($resource === 'bills') $data['receipt'] = json_decode($row->receipt,true);
        return $data;
    }
    public static function emit(string $resource, int $tenant, string $id, bool $deleted = false): void {
        DB::table('users')->where('id',$tenant)->increment('sync_version');
        $sequence = DB::table('users')->where('id',$tenant)->value('sync_version');
        DB::table('changes')->insert(['user_id'=>$tenant,'sequence'=>$sequence,'resource'=>$resource,'entity_id'=>$id,
            'operation'=>$deleted?'delete':'upsert','payload'=>json_encode($deleted?['id'=>$id]:self::get($resource,$tenant,$id)), 'created_at'=>now()]);
    }
    public static function requireManager(): void {
        abort_unless(in_array(request()->user()->role,['owner','manager'],true),403,'Manager access required.');
    }
}
