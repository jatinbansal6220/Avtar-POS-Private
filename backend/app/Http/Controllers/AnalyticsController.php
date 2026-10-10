<?php
namespace App\Http\Controllers;
use App\Services\Records;
use Carbon\CarbonImmutable;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
final class AnalyticsController {
    public function index(Request $r) {
        Records::requireManager(); $tenant=$r->user()->tenantId();
        $v=$r->validate(['from'=>'required|date_format:Y-m-d','to'=>'required|date_format:Y-m-d|after_or_equal:from']);
        // The DATETIME columns intentionally hold restaurant wall-clock time.
        // Do not convert these bounds back to UTC or reports near midnight
        // shift into the previous/next business day.
        $tz='Asia/Kolkata';
        $from=CarbonImmutable::parse($v['from'],$tz)->startOfDay(); $to=CarbonImmutable::parse($v['to'],$tz)->addDay()->startOfDay();
        abort_if($from->diffInDays($to)>366,422,'Select at most one year.');
        $query=fn($start,$end)=>DB::table('bills')->where('bills.user_id',$tenant)->where('generated_at','>=',$start)->where('generated_at','<',$end);
        $base=$query($from,$to);
        $summary=(clone $base)->selectRaw('COUNT(*) AS bills, COALESCE(SUM(total_minor),0) AS revenue_minor, COALESCE(SUM(tax_minor),0) AS tax_minor, COALESCE(SUM(discount_minor),0) AS discount_minor')->first();
        $sales=function($start,$end) use($query) {
            return $query($start,$end)->join('order_items','order_items.order_id','=','bills.order_id')
                ->selectRaw('COALESCE(menu_item_id, combo_id) AS item_id, MAX(item_name) AS name, SUM(quantity) AS quantity, SUM(quantity * price_minor) AS revenue_minor')
                ->groupByRaw('COALESCE(menu_item_id, combo_id)')->orderByDesc('quantity')->limit(100)->get();
        };
        $today=CarbonImmutable::now($tz)->startOfDay(); $todaySales=$sales($today,$today->addDay());
        $quantities=$query($today,$today->addDay())->join('order_items','order_items.order_id','=','bills.order_id')
            ->whereNotNull('menu_item_id')->selectRaw('menu_item_id, SUM(quantity) AS quantity')->groupBy('menu_item_id');
        $least=DB::table('menu_items')->leftJoinSub($quantities,'sold','sold.menu_item_id','=','menu_items.id')
            ->where('menu_items.user_id',$tenant)->whereNull('menu_items.deleted_at')->where('is_active',true)
            ->selectRaw('menu_items.name, COALESCE(sold.quantity,0) AS quantity')->orderBy('quantity')->orderBy('menu_items.name')->first();
        return response()->json(['summary'=>$summary,'top_today'=>$todaySales->first(),'least_today'=>$least,
            'top_week'=>$sales($today->startOfWeek(),$today->addDay())->first(),'items'=>$sales($from,$to),
            'tables'=>(clone $base)->selectRaw('table_number, COUNT(*) AS orders, SUM(total_minor) AS revenue_minor')->groupBy('table_number')->orderByDesc('revenue_minor')->limit(100)->get(),
            'daily'=>(clone $base)->selectRaw('DATE(generated_at) AS day, SUM(total_minor) AS revenue_minor')->groupByRaw('DATE(generated_at)')->orderBy('day')->get(),
            'daily_timezone'=>$tz,'timezone'=>$tz]);
    }
}
