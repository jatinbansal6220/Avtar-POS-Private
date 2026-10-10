<?php
namespace App\Http\Controllers;

use App\Services\Records;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;

final class ResourceController {
    public function index(Request $r, string $resource) {
        $this->authorizeRead($resource);
        $r->validate(['limit'=>'sometimes|integer|min:1|max:100','after'=>'nullable|uuid','cursor'=>'nullable|string|max:100','q'=>'nullable|string|max:100','status'=>'nullable|string|max:20','staff_id'=>'nullable|uuid','inventory_item_id'=>'nullable|uuid','order_id'=>'nullable|uuid','from'=>'nullable|date_format:Y-m-d','to'=>'nullable|date_format:Y-m-d']);
        $q=Records::query($resource,$r->user()->tenantId());
        if ($resource==='bills' && $r->filled('cursor')) {
            [$timestamp,$id]=array_pad(explode('|',$r->cursor,2),2,null);
            abort_unless($timestamp && $id,422,'Invalid bill history cursor.');
            $q->where(function($query) use($timestamp,$id) {
                $query->where('generated_at','<',$timestamp)
                    ->orWhere(function($same) use($timestamp,$id) {$same->where('generated_at','=',$timestamp)->where('id','<',$id);});
            });
        } elseif ($r->filled('after')) $q->where('id','>',$r->after);
        if ($r->filled('status') && in_array($resource,['orders','tables','attendance'])) $q->where('status',$r->status);
        if ($r->filled('staff_id') && in_array($resource,['attendance','payments','staff_salary_adjustments'])) $q->where('staff_id',$r->staff_id);
        if ($r->filled('inventory_item_id') && $resource==='inventory_entries') $q->where('inventory_item_id',$r->inventory_item_id);
        // A bill retry can race with another terminal settling the same
        // table. Allow the client to retrieve that authoritative receipt by
        // its immutable order id instead of leaving a duplicate local bill
        // permanently pending.
        if ($r->filled('order_id') && $resource==='bills') $q->where('order_id',$r->order_id);
        $date=match($resource) {'bills'=>'generated_at','purchases'=>'purchase_date','expenses'=>'expense_date','inventory_entries'=>'recorded_at','attendance','payments'=>'date',default=>'created_at'};
        if ($r->filled('from')) $q->where($date,'>=',$r->from);
        if ($r->filled('to')) $q->where($date,'<',\Carbon\Carbon::parse($r->to)->addDay()->toDateString());
        if ($r->filled('q')) {
            $field=match($resource) {'tables'=>'table_number','bills'=>'bill_number','purchases'=>'item_name','banks'=>'account_name','orders'=>'customer_name','settings'=>'restaurant_name', 'attendance'=>'status','payments'=>'note','expenses'=>'title',default=>'name'};
            $q->where($field,'like','%'.str_replace(['%','_'],['\\%','\\_'],$r->q).'%');
        }
        $limit=(int)$r->input('limit',50);
        if ($resource==='bills') $q->orderByDesc('generated_at')->orderByDesc('id'); else $q->orderBy('id');
        $rows=$q->limit($limit+1)->get(); $more=$rows->count()>$limit;
        $rows=$rows->take($limit);
        // Batch children to avoid one query per order/combo on history pages.
        $children=match($resource) {'orders'=>['order_items','order_id'],'combos'=>['combo_items','combo_id'],default=>null};
        $grouped=$children?DB::table($children[0])->whereIn($children[1],$rows->pluck('id'))->get()->groupBy($children[1]):null;
        $data=$rows->map(function($row) use($resource,$children,$grouped) {
            if ($children) return [...(array)$row,'items'=>($grouped[$row->id]??collect())->map(fn($i)=>(array)$i)->all()];
            return Records::decode($resource,$row);
        })->values();
        $next=$more?($resource==='bills'?$rows->last()->generated_at.'|'.$rows->last()->id:$rows->last()->id):null;
        return response()->json(['data'=>$data,'next_cursor'=>$next]);
    }
    public function show(Request $r,string $resource,string $id) {
        $this->authorizeRead($resource); return response()->json(Records::get($resource,$r->user()->tenantId(),$id));
    }

    public function setBillDeleteCode(Request $r) {
        Records::requireManager();
        $v=$r->validate([
            'current_code_hash'=>['nullable','regex:/^[a-f0-9]{64}$/i'],
            'new_code_hash'=>['required','regex:/^[a-f0-9]{64}$/i'],
        ]);
        $tenant=$r->user()->tenantId();
        $settings=Records::query('settings',$tenant)->first();
        abort_unless($settings,422,'Complete restaurant settings before setting an invoice deletion code.');
        $configured=(string)($settings->invoice_delete_code_hash ?? '');
        if ($configured!=='') {
            abort_unless(!empty($v['current_code_hash']) && hash_equals($configured,strtolower($v['current_code_hash'])),403,'Current invoice deletion code is incorrect.');
        }
        DB::table('settings')->where('id',$settings->id)->where('user_id',$tenant)->update([
            'invoice_delete_code_hash'=>strtolower($v['new_code_hash']),
            'version'=>$settings->version+1,
            'updated_at'=>now(),
        ]);
        Records::emit('settings',$tenant,$settings->id);
        return response()->json(Records::get('settings',$tenant,$settings->id));
    }
    private function authorizeRead(string $resource): void {
        if (in_array($resource,['purchase_suppliers','purchase_bills','purchase_events'])) Records::requireManager();
        if (in_array($resource,['staff','attendance','staff_salary_adjustments','payments','banks','purchases','table_bookings','purchase_categories','purchase_items','inventory_items','inventory_entries','expenses'])) Records::requireManager();
    }
    public function save(Request $r,string $resource,?string $id=null) {
        if (in_array($resource,['purchase_suppliers','purchase_bills','purchase_events'])) return app(PurchaseLedgerController::class)->save($r,$resource,$id);
        Records::requireManager();
        abort_if(in_array($resource,['orders','bills']),405);
        $tenant=$r->user()->tenantId();
        $rules=$this->rules($resource,$tenant);
        $v=$r->validate($rules+['id'=>'sometimes|uuid','version'=>$id?'required|integer|min:1':'sometimes|integer']);
        abort_if($resource==='inventory_entries' && $id,405);
        $old=$id?Records::get($resource,$tenant,$id):null;
        if ($old) abort_unless($old['version']==$v['version'],409,'This record changed on another device. Reload before saving.');
        if ($resource==='settings' && !$id) abort_if(Records::query('settings',$tenant)->exists(),409,'Settings already exist.');
        if ($resource==='attendance' && !$id) {
            $existing=Records::query('attendance',$tenant)->where('staff_id',$v['staff_id'])->where('date',$v['date'])->first();
            abort_if($existing,409,'Attendance already marked. Open the existing entry to edit.');
        }
        if ($resource==='staff_salary_adjustments' && !$id) {
            $existing=Records::query('staff_salary_adjustments',$tenant)->where('staff_id',$v['staff_id'])->where('month_start',$v['month_start'])->first();
            abort_if($existing,409,'This staff month already has a confirmed salary cut.');
        }
        $items=$v['items']??[]; unset($v['items'],$v['version'],$v['id']);
        if ($resource==='purchase_items' && array_key_exists('reorder_levels',$v)) $v['reorder_levels']=json_encode($v['reorder_levels']);
        if ($resource==='tables') {
            abort_if($old && $old['status']!=='empty',409,'An occupied table cannot be edited.');
            abort_if(Records::query('tables',$tenant)->where('table_number',$v['table_number'])->when($id,fn($q)=>$q->where('id','!=',$id))->exists(),422,'Table number already exists.');
        }
        if ($resource==='purchases') $v['total_minor']=(int)round((float)$v['quantity']*$v['unit_price_minor']);
        if ($resource==='inventory_entries') {
            abort_if(!Records::query('inventory_items',$tenant)->where('id',$v['inventory_item_id'])->exists(),422,'The inventory item was not found.');
        }
        if ($resource==='table_bookings') {
            abort_if(\Carbon\Carbon::parse($v['end_at'])->lessThanOrEqualTo(\Carbon\Carbon::parse($v['start_at'])),422,'Booking end time must be after its start time.');
            $clash=Records::query('table_bookings',$tenant)->where('table_id',$v['table_id'])->when($id,fn($q)=>$q->where('id','!=',$id))->where('start_at','<',$v['end_at'])->where('end_at','>',$v['start_at'])->exists();
            abort_if($clash,422,'This table is already booked for the selected time.');
        }
        if ($resource==='settings' && array_key_exists('online_platforms',$v)) {
            $v['online_platforms']=json_encode($v['online_platforms'] ?? []);
        }
        // GST off is authoritative for all clients, including offline devices.
        if ($resource==='settings' && !in_array($v['is_tax_enabled'] ?? false,[true,1,'1','true'],true)) {
            $v['tax_basis_points']=0;
        }
        if ($resource==='banks' && ($v['is_default']??false)) {
            foreach(Records::query('banks',$tenant)->where('is_default',true)->get() as $bank) {
                DB::table('banks')->where('id',$bank->id)->update(['is_default'=>false,'version'=>$bank->version+1,'updated_at'=>now()]);
                Records::emit('banks',$tenant,$bank->id);
            }
        }
        if ($resource==='banks' && ($v['is_default_qr']??false)) {
            foreach(Records::query('banks',$tenant)->where('is_default_qr',true)->get() as $bank) {
                DB::table('banks')->where('id',$bank->id)->update(['is_default_qr'=>false,'version'=>$bank->version+1,'updated_at'=>now()]);
                Records::emit('banks',$tenant,$bank->id);
            }
        }
        $id??=$r->input('id',(string)Str::uuid());
        if ($old) DB::table($resource)->where('id',$id)->where('user_id',$tenant)->update($v+['version'=>$old['version']+1,'updated_at'=>now()]);
        else DB::table($resource)->insert($v+['id'=>$id,'user_id'=>$tenant,'created_at'=>now(),'updated_at'=>now()]);
        if ($resource==='inventory_entries') {
            $item=Records::query('inventory_items',$tenant)->where('id',$v['inventory_item_id'])->first();
            DB::table('inventory_items')->where('id',$item->id)->where('user_id',$tenant)->update([
                'current_quantity'=>$v['quantity'],
                'last_recorded_at'=>$v['recorded_at'],
                'version'=>$item->version+1,
                'updated_at'=>now(),
            ]);
            Records::emit('inventory_items',$tenant,$item->id);
        }
        if ($resource==='combos') {
            DB::table('combo_items')->where('combo_id',$id)->delete();
            foreach($items as $item) DB::table('combo_items')->insert(['combo_id'=>$id,'menu_item_id'=>$item['menu_item_id'],'quantity'=>$item['quantity']]);
        }
        Records::emit($resource,$tenant,$id);
        return response()->json(Records::get($resource,$tenant,$id),$old?200:201);
    }
    public function delete(Request $r,string $resource,string $id) {
        Records::requireManager(); abort_unless(in_array($resource,['tables','menu_items','combos','staff','banks','purchases','purchase_categories','purchase_items','inventory_items','expenses','bills']),405);
        $v=$r->validate(['version'=>'required|integer','delete_code_hash'=>'nullable|regex:/^[a-f0-9]{64}$/i']); $tenant=$r->user()->tenantId(); $row=Records::get($resource,$tenant,$id);
        abort_unless($row['version']==$v['version'],409,'Record changed. Reload first.');
        if ($resource==='bills') {
            $settings=Records::query('settings',$tenant)->first();
            $configured=(string)($settings->invoice_delete_code_hash ?? '');
            abort_if($configured==='',422,'Set an invoice deletion code before deleting an invoice.');
            abort_unless(!empty($v['delete_code_hash']) && hash_equals($configured,strtolower($v['delete_code_hash'])),403,'Invoice deletion code is incorrect.');
        }
        if ($resource==='tables') abort_unless($row['status']==='empty',409,'Cannot delete an occupied table.');
        if ($resource==='menu_items') abort_if(DB::table('combo_items')->join('combos','combos.id','=','combo_items.combo_id')->where('menu_item_id',$id)->whereNull('combos.deleted_at')->exists(),409,'Remove this item from combos first.');
        DB::table($resource)->where('id',$id)->where('user_id',$tenant)->update(['deleted_at'=>now(),'updated_at'=>now(),'version'=>$row['version']+1]);
        Records::emit($resource,$tenant,$id,true); return response()->json(['id'=>$id,'deleted'=>true]);
    }
    private function rules(string $resource,int $tenant): array {
        return match($resource) {
            'tables' => \App\Modules\Tables\TablesRules::forTenant($tenant),
            'menu_items' => \App\Modules\Menu\MenuRules::forTenant($tenant),
            'combos' => \App\Modules\Combos\CombosRules::forTenant($tenant),
            'staff' => \App\Modules\Staff\StaffRules::forTenant($tenant),
            'attendance' => \App\Modules\Attendance\AttendanceRules::forTenant($tenant),
            'staff_salary_adjustments' => ['staff_id'=>['required','uuid',Rule::exists('staff','id')->where('user_id',$tenant)->whereNull('deleted_at')],'month_start'=>'required|date_format:Y-m-d','absent_days'=>'required|integer|min:0|max:31','half_days'=>'required|integer|min:0|max:31','deduction_minor'=>'required|integer|min:0|max:100000000','reason'=>'required|string|max:500'],
            'payments' => \App\Modules\Payments\PaymentsRules::forTenant($tenant),
            'banks' => \App\Modules\Banks\BanksRules::forTenant($tenant),
            'purchases' => \App\Modules\Purchases\PurchasesRules::forTenant($tenant),
            'purchase_categories' => ['name'=>'required|string|max:80'],
            'purchase_items' => ['name'=>'required|string|max:160','category_id'=>['required','uuid',Rule::exists('purchase_categories','id')->where('user_id',$tenant)->whereNull('deleted_at')],'category_name'=>'required|string|max:80','is_active'=>'required|boolean','reorder_levels'=>'sometimes|array|max:20','reorder_levels.*'=>'integer|min:0|max:100000000'],
            'inventory_items' => ['name'=>'required|string|max:160','unit'=>'required|string|max:20','current_quantity'=>'required|integer|min:0|max:100000000','last_recorded_at'=>'required|date'],
            'inventory_entries' => ['inventory_item_id'=>['required','uuid',Rule::exists('inventory_items','id')->where('user_id',$tenant)->whereNull('deleted_at')],'quantity'=>'required|integer|min:0|max:100000000','recorded_at'=>'required|date','note'=>'nullable|string|max:2000'],
            'expenses' => ['title'=>'required|string|max:160','amount_minor'=>'required|integer|min:0|max:100000000','expense_date'=>'required|date_format:Y-m-d','notes'=>'nullable|string|max:2000'],
            'table_bookings' => ['table_id'=>['required','uuid',Rule::exists('tables','id')->where('user_id',$tenant)->whereNull('deleted_at')],'table_number'=>'required|string|max:40','start_at'=>'required|date','end_at'=>'required|date','customer_name'=>'nullable|string|max:160','customer_phone'=>'nullable|string|max:30'],
            'settings' => \App\Modules\Settings\SettingsRules::forTenant($tenant),
            default => abort(404),
        };
    }
}
