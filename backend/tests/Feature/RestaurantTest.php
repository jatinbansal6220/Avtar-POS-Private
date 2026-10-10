<?php
namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

class RestaurantTest extends TestCase {
    use RefreshDatabase;
    private User $owner;
    protected function setUp(): void {
        parent::setUp(); $this->owner=User::factory()->create(['role'=>'owner']); Sanctum::actingAs($this->owner);
    }
    private function write(string $method,string $path,array $body,?string $key=null) {
        return $this->json($method,'/api/'.$path,$body,['Idempotency-Key'=>$key??(string)Str::uuid()]);
    }
    private function setupRestaurant(): array {
        $this->write('POST','settings',['restaurant_name'=>'Test kitchen','printer_port'=>9100,'printer_paper_width'=>'80mm','is_tax_enabled'=>true,'tax_basis_points'=>500,'default_discount_basis_points'=>0,'timezone'=>'Asia/Kolkata'])->assertCreated();
        $table=$this->write('POST','tables',['table_number'=>'T1','section'=>'Main','capacity'=>4])->assertCreated()->json();
        $item=$this->write('POST','menu_items',['name'=>'Test item','price_minor'=>10001,'category'=>'Main','is_active'=>true,'is_veg'=>true])->assertCreated()->json();
        return [$table,$item];
    }
    private function order(array $table,array $item): array {
        return $this->write('POST','orders',['order_type'=>'dine_in','table_id'=>$table['id'],'items'=>[['menu_item_id'=>$item['id'],'quantity'=>2]]])->assertCreated()->json();
    }
    public function test_empty_production_seed(): void {
        $this->seed(); $this->assertDatabaseCount('menu_items',0);$this->assertDatabaseCount('orders',0);$this->assertDatabaseCount('users',1);
    }
    public function test_auth_and_tenant_isolation(): void {
        [$table,$item]=$this->setupRestaurant(); $other=User::factory()->create(); Sanctum::actingAs($other);
        $this->getJson('/api/menu_items/'.$item['id'])->assertNotFound();
        $this->write('POST','orders',['order_type'=>'dine_in','table_id'=>$table['id'],'items'=>[['menu_item_id'=>$item['id'],'quantity'=>1]]])->assertNotFound();
        $this->getJson('/api/tables')->assertJsonCount(0,'data');
    }
    public function test_atomic_bill_rounding_price_snapshot_and_retry(): void {
        [$table,$item]=$this->setupRestaurant();$order=$this->order($table,$item);
        $item['price_minor']=90000;$this->write('PUT','menu_items/'.$item['id'],$item)->assertOk();
        $key=(string)Str::uuid();$payload=['order_id'=>$order['id'],'version'=>1,'discount_basis_points'=>1000,'payment_method'=>'cash'];
        $bill=$this->write('POST','bills/generate',$payload,$key)->assertCreated()->json();
        $this->assertSame(20002,$bill['subtotal_minor']);$this->assertSame(2000,$bill['discount_minor']);$this->assertSame(900,$bill['tax_minor']);$this->assertSame(18902,$bill['total_minor']);
        $this->write('POST','bills/generate',$payload,$key)->assertCreated()->assertJsonPath('id',$bill['id']);
        $this->assertDatabaseCount('bills',1);$this->assertDatabaseHas('tables',['id'=>$table['id'],'status'=>'empty','current_order_id'=>null]);
        $this->write('POST','bills/generate',$payload)->assertConflict();
        $this->write('PUT','orders/'.$order['id'],['order_type'=>'dine_in','table_id'=>$table['id'],'version'=>2,'items'=>[['menu_item_id'=>$item['id'],'quantity'=>3]]])->assertConflict();
    }
    public function test_offline_audit_discounts_and_mixed_payment_are_preserved(): void {
        [$table,$item]=$this->setupRestaurant();
        $bank=$this->write('POST','banks',['account_name'=>'Default UPI','bank_name'=>'Kitchen Bank','account_type'=>'upi_merchant','initial_balance_minor'=>0,'is_default'=>true,'is_active'=>true])->assertCreated()->json();
        $void=['item_name'=>'Removed item','quantity'=>1,'price_minor'=>500,'reason'=>'Customer changed mind','voided_at'=>now()->toIso8601String(),'actor'=>'Cashier'];
        $order=$this->write('POST','orders',['order_type'=>'dine_in','table_id'=>$table['id'],'voids'=>[$void],
            'items'=>[['menu_item_id'=>$item['id'],'quantity'=>2,'discount_type'=>'percent','discount_value'=>1000]]])->assertCreated()->json();
        $invalid=['order_id'=>$order['id'],'version'=>1,'discount_basis_points'=>500,'payment_method'=>'mixed',
            'payments'=>[['method'=>'cash','amount_minor'=>10000],['method'=>'upi','amount_minor'=>7000]]];
        $this->write('POST','bills/generate',$invalid)->assertUnprocessable();
        $valid=array_merge($invalid,['bank_account_id'=>$bank['id'],'payments'=>[['method'=>'cash','amount_minor'=>10000],['method'=>'upi','amount_minor'=>7957]],'split_amounts'=>[9000,8957]]);
        $bill=$this->write('POST','bills/generate',$valid)->assertCreated()
            ->assertJsonPath('receipt.voids.0.reason','Customer changed mind')
            ->assertJsonPath('receipt.item_discount_minor',2000)
            ->assertJsonPath('receipt.bill_discount_minor',900)
            ->assertJsonPath('receipt.total_minor',17957)
            ->assertJsonPath('receipt.payments.1.amount_minor',7957)
            ->json();
        $this->assertSame(17957,$bill['total_minor']);
        $this->assertDatabaseHas('bills',['id'=>$bill['id'],'item_discount_minor'=>2000,'bill_discount_minor'=>900,'payment_method'=>'mixed']);
    }
    public function test_stale_edit_table_collision_and_untrusted_price(): void {
        [$table,$item]=$this->setupRestaurant();$order=$this->order($table,$item);
        $this->write('POST','orders',['order_type'=>'dine_in','table_id'=>$table['id'],'items'=>[['menu_item_id'=>$item['id'],'quantity'=>1]]])->assertConflict();
        $payload=['order_type'=>'dine_in','table_id'=>$table['id'],'version'=>1,'items'=>[['menu_item_id'=>$item['id'],'quantity'=>3,'price_minor'=>1]]];
        $this->write('PUT','orders/'.$order['id'],$payload)->assertOk()->assertJsonPath('subtotal_minor',30003);
        $this->write('PUT','orders/'.$order['id'],$payload)->assertConflict();
        $this->assertDatabaseCount('orders',1);
    }
    public function test_idempotency_fingerprint_and_delete_delta(): void {
        $key=(string)Str::uuid();$v=['table_number'=>'A','section'=>'Main','capacity'=>2];
        $table=$this->write('POST','tables',$v,$key)->assertCreated()->json();
        $this->write('POST','tables',$v+['id'=>(string)Str::uuid()],$key)->assertConflict();
        $cursor=$this->getJson('/api/sync/cursor')->json('cursor');
        $this->write('DELETE','tables/'.$table['id'],['version'=>1])->assertOk();
        $this->getJson('/api/updates?last_checked='.$cursor)->assertOk()->assertJsonPath('changes.0.operation','delete');
        $this->getJson('/api/updates?last_checked=0')->assertJsonCount(2,'changes');
    }
    public function test_role_restrictions_and_salary_privacy(): void {
        $waiter=User::factory()->create(['owner_id'=>$this->owner->id,'role'=>'waiter']);Sanctum::actingAs($waiter);
        $this->getJson('/api/payments')->assertForbidden();
        $this->getJson('/api/analytics?from=2026-09-01&to=2026-09-17')->assertForbidden();
        $this->write('POST','tables',['table_number'=>'B','section'=>'Main','capacity'=>2])->assertForbidden();
        $this->write('POST','bills/generate',[])->assertForbidden();
    }
    public function test_pagination_and_analytics_zero_sellers(): void {
        [$table,$item]=$this->setupRestaurant();$order=$this->order($table,$item);
        $bank=$this->write('POST','banks',['account_name'=>'Default UPI','bank_name'=>'Kitchen Bank','account_type'=>'upi_merchant','initial_balance_minor'=>0,'is_default'=>true,'is_active'=>true])->assertCreated()->json();
        $this->write('POST','bills/generate',['order_id'=>$order['id'],'version'=>1,'discount_basis_points'=>0,'payment_method'=>'upi','bank_account_id'=>$bank['id']])->assertCreated();
        $this->write('POST','menu_items',['name'=>'Unsold','price_minor'=>100,'category'=>'Main','is_active'=>true,'is_veg'=>true])->assertCreated();
        $page=$this->getJson('/api/menu_items?limit=1')->assertJsonCount(1,'data')->json();
        $this->getJson('/api/menu_items?limit=1&after='.$page['next_cursor'])->assertJsonCount(1,'data');
        $date=now('Asia/Kolkata')->toDateString();
        $this->getJson('/api/analytics?from='.$date.'&to='.$date)->assertOk()->assertJsonPath('summary.bills',1)->assertJsonPath('least_today.name','Unsold');
    }
    public function test_failed_combo_rolls_back(): void {
        $this->write('POST','combos',['name'=>'Invalid','price_minor'=>100,'is_active'=>true,'items'=>[['menu_item_id'=>(string)Str::uuid(),'quantity'=>1]]])->assertUnprocessable();
        $this->assertDatabaseCount('combos',0);$this->assertDatabaseCount('changes',0);
    }
    public function test_inventory_count_history_updates_current_quantity_and_expenses_sync(): void {
        $item=$this->write('POST','inventory_items',[
            'name'=>'Steel serving spoon','unit'=>'pcs','current_quantity'=>24,
            'last_recorded_at'=>'2026-09-24T09:00:00+05:30',
        ])->assertCreated()->json();
        $cursor=$this->getJson('/api/sync/cursor')->json('cursor');
        $entry=$this->write('POST','inventory_entries',[
            'inventory_item_id'=>$item['id'],'quantity'=>18,
            'recorded_at'=>'2026-09-24T20:30:00+05:30','note'=>'After dinner service',
        ])->assertCreated()->json();
        $this->assertSame(18,$entry['quantity']);
        $this->assertDatabaseHas('inventory_items',['id'=>$item['id'],'current_quantity'=>18]);
        $expense=$this->write('POST','expenses',[
            'title'=>'Gas cylinder refill','amount_minor'=>85000,
            'expense_date'=>'2026-09-24','notes'=>'Kitchen supply',
        ])->assertCreated()->json();
        $this->assertSame(85000,$expense['amount_minor']);
        $this->getJson('/api/inventory_entries?inventory_item_id='.$item['id'])
            ->assertOk()->assertJsonCount(1,'data')->assertJsonPath('data.0.note','After dinner service');
        $changes=$this->getJson('/api/updates?last_checked='.$cursor)->assertOk()->json('changes');
        $this->assertTrue(collect($changes)->contains('resource','inventory_items'));
        $this->assertTrue(collect($changes)->contains('resource','inventory_entries'));
        $this->assertTrue(collect($changes)->contains('resource','expenses'));
    }
    public function test_gst_off_additional_amount_and_selected_bank_are_saved_on_final_bill(): void {
        [$table,$item]=$this->setupRestaurant();
        DB::table('settings')->where('user_id',$this->owner->id)->update(['is_tax_enabled'=>'false']);
        $bank=$this->write('POST','banks',['account_name'=>'Main UPI','bank_name'=>'Kitchen Bank','account_type'=>'upi_merchant','initial_balance_minor'=>0,'is_default'=>true,'is_active'=>true])->assertCreated()->json();
        $order=$this->order($table,$item);
        $bill=$this->write('POST','bills/generate',[
            'order_id'=>$order['id'],'version'=>1,'discount_basis_points'=>0,'payment_method'=>'upi','bank_account_id'=>$bank['id'],
            'additional_charges'=>[['amount_minor'=>1000,'note'=>'Packing charge'],['amount_minor'=>500]],
        ])->assertCreated()
            ->assertJsonPath('tax_minor',0)
            ->assertJsonPath('additional_amount_minor',1500)
            ->assertJsonPath('total_minor',21502)
            ->assertJsonPath('receipt.bank_account_name','Main UPI')
            ->assertJsonPath('receipt.additional_charges.0.note','Packing charge')
            ->json();
        $this->assertDatabaseHas('bills',['id'=>$bill['id'],'tax_minor'=>0,'additional_amount_minor'=>1500,'bank_account_id'=>$bank['id']]);
    }
    public function test_upi_requires_a_default_bank_but_online_can_use_any_active_bank(): void {
        [$table,$item]=$this->setupRestaurant();
        $order=$this->order($table,$item);
        $payload=['order_id'=>$order['id'],'version'=>1,'discount_basis_points'=>0,'payment_method'=>'upi'];
        $this->write('POST','bills/generate',$payload)->assertUnprocessable();
        $bank=$this->write('POST','banks',['account_name'=>'Secondary account','bank_name'=>'Kitchen Bank','account_type'=>'current','initial_balance_minor'=>0,'is_default'=>false,'is_active'=>true])->assertCreated()->json();
        $this->write('POST','bills/generate',$payload+['bank_account_id'=>$bank['id']])->assertUnprocessable();
        $bill=$this->write('POST','bills/generate',array_merge($payload,['payment_method'=>'online','bank_account_id'=>$bank['id']]))->assertCreated()->json();
        $this->assertSame('online',$bill['payment_method']);
        $this->assertSame($bank['id'],$bill['bank_account_id']);
    }
}
