<?php
namespace App\Http\Controllers;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
final class SyncController {
    public function cursor(Request $r) {
        return response()->json(['cursor'=>(int)DB::table('users')->where('id',$r->user()->tenantId())->value('sync_version')]);
    }
    public function updates(Request $r) {
        // Monotonic cursor avoids timestamp ties, clock drift and late commits.
        $v=$r->validate(['last_checked'=>'required|integer|min:0']);
        $rows=DB::table('changes')->where('user_id',$r->user()->tenantId())->where('sequence','>',$v['last_checked'])->orderBy('sequence')->limit(201)->get();
        $more=$rows->count()>200; $rows=$rows->take(200);
        $manager=in_array($r->user()->role,['owner','manager']);
        $events=$rows->filter(fn($row)=>$manager || !in_array($row->resource,['staff','attendance','staff_salary_adjustments','payments','banks','purchases','purchase_categories','purchase_items','purchase_suppliers','purchase_bills','purchase_events','inventory_items','inventory_entries','expenses']))->map(fn($row)=>[
            'sequence'=>$row->sequence,'resource'=>$row->resource,'id'=>$row->entity_id,'operation'=>$row->operation,'data'=>json_decode($row->payload,true)])->values();
        return response()->json(['changes'=>$events,'next_cursor'=>$rows->last()->sequence??(int)$v['last_checked'],'has_more'=>$more]);
    }
}
