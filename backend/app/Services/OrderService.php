<?php
namespace App\Services;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

final class OrderService {
    public function save(int $tenant,array $v,?string $id=null): array {
        $old=$id?Records::get('orders',$tenant,$id):null;
        if ($old) {
            abort_unless($old['status']==='open',409,'A finalized order cannot be edited.');
            abort_unless($old['version']==$v['version'],409,'Order changed on another device. Your local draft is preserved.');
            abort_unless(($v['table_id']??null)===$old['table_id'] && $v['order_type']===$old['order_type'],422,'Order channel and table cannot change after saving.');
        }
        $id??=$v['id']??(string)Str::uuid(); $table=null;
        if ($v['order_type']==='dine_in') {
            abort_unless(!empty($v['table_id']),422,'Select a table.');
            $table=Records::get('tables',$tenant,$v['table_id']);
            abort_if($table['current_order_id'] && $table['current_order_id']!==$id,409,'This table already has an open order.');
        } else abort_if(!empty($v['table_id']),422,'Takeaway, Menu POS and online orders cannot occupy a table.');
        $lines=[]; $seen=[]; $subtotal=0;
        foreach($v['items'] as $item) {
            $combo=!empty($item['combo_id']);
            abort_if($combo === !empty($item['menu_item_id']),422,'Choose exactly one menu item or combo.');
            $field=$combo?'combo_id':'menu_item_id'; $ref=$item[$field]; $key=$field.$ref;
            abort_if(isset($seen[$key]),422,'Combine duplicate items into one quantity.'); $seen[$key]=true;
            $previous=collect($old['items']??[])->first(fn($line)=>$line[$field]===$ref);
            // Existing lines retain the agreed price, even after catalog price changes.
            if ($previous) { $price=$previous['price_minor']; $name=$previous['item_name']; $components=$previous['components']; }
            else {
                $catalog=Records::get($combo?'combos':'menu_items',$tenant,$ref);
                abort_unless($catalog['is_active'],422,'This item is currently unavailable.');
                if ($combo) foreach($catalog['items'] as $component) {
                    $part=Records::get('menu_items',$tenant,$component['menu_item_id']);
                    abort_unless($part['is_active'],422,'A combo component is unavailable.');
                }
                $price=$catalog['price_minor']; $name=$catalog['name']; $components=$combo?json_encode($catalog['items']):null;
            }
            $discountType=$item['discount_type']??'percent'; $discountValue=(int)($item['discount_value']??0);
            abort_if($discountType==='percent' && $discountValue>10000,422,'Item discount cannot exceed 100%.');
            abort_if($discountType==='fixed' && $discountValue>$price*$item['quantity'],422,'Item discount exceeds the line amount.');
            $lines[]=['id'=>$previous['id']??(string)Str::uuid(),'order_id'=>$id,'menu_item_id'=>$combo?null:$ref,'combo_id'=>$combo?$ref:null,
                'item_name'=>$name,'quantity'=>$item['quantity'],'price_minor'=>$price,'notes'=>$item['notes']??null,
                'discount_type'=>$discountType,'discount_value'=>$discountValue,'components'=>$components,
                'source_table_number'=>$previous['source_table_number']??($item['source_table_number']??($table['table_number']??null))];
            $subtotal+=$price*$item['quantity'];
        }
        $data=['table_id'=>$v['table_id']??null,'table_number'=>$table['table_number']??($v['order_type']==='online'?'Online':($v['order_type']==='pos'?'Menu POS':'Takeaway')),
            'order_type'=>$v['order_type'],'online_platform'=>$v['online_platform']??null,'online_platform_name'=>$v['online_platform_name']??null,'customer_name'=>$v['customer_name']??null,
            'customer_phone'=>$v['customer_phone']??null,'notes'=>$v['notes']??null,'voids'=>json_encode($v['voids']??($old['voids']??[])),
            'subtotal_minor'=>$subtotal,'updated_at'=>now()];
        if ($old) DB::table('orders')->where('id',$id)->update($data+['version'=>$old['version']+1]);
        else DB::table('orders')->insert($data+['id'=>$id,'user_id'=>$tenant,'created_at'=>now()]);
        DB::table('order_items')->where('order_id',$id)->delete();
        if ($lines) DB::table('order_items')->insert($lines);
        if ($table) {
            DB::table('tables')->where('id',$table['id'])->update(['status'=>'occupied','current_order_id'=>$id,'version'=>$table['version']+1,'updated_at'=>now()]);
            Records::emit('tables',$tenant,$table['id']);
        }
        Records::emit('orders',$tenant,$id); return Records::get('orders',$tenant,$id);
    }
}
