<?php
namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Tests\TestCase;

class PurchaseLedgerTest extends TestCase {
    use RefreshDatabase;
    private User $owner; private string $token; private string $supplier; private string $item;
    protected function migrateDatabases(): void {
        $paths=array_values(array_filter(glob(database_path('migrations/*.php')),fn($p)=>basename($p)!=='2026_09_30_000010_make_bill_numbers_terminal_scoped.php'));
        $this->artisan('migrate:fresh',['--path'=>$paths,'--realpath'=>true]);
    }
    protected function setUp(): void {
        parent::setUp();$this->owner=User::factory()->create(['role'=>'owner']);$this->token=$this->owner->createToken('test')->plainTextToken;
        $this->supplier=(string)Str::uuid();$this->item=(string)Str::uuid();$category=(string)Str::uuid();
        $this->writeLedger('purchase_suppliers',['id'=>$this->supplier,'name'=>'Fresh Foods','is_active'=>true])->assertCreated();
        $this->writeLedger('purchase_categories',['id'=>$category,'name'=>'Vegetables'])->assertCreated();
        $this->writeLedger('purchase_items',['id'=>$this->item,'name'=>'Tomato','category_id'=>$category,'category_name'=>'Vegetables','is_active'=>true])->assertCreated();
    }
    private function headers(?string $key=null): array {$this->app['auth']->forgetGuards();return ['Authorization'=>'Bearer '.$this->token,'Idempotency-Key'=>$key??(string)Str::uuid()];}
    private function writeLedger(string $path,array $body,?string $key=null){return $this->postJson('/api/'.$path,$body,$this->headers($key));}
    private function bill(string $status='received'): array {return ['id'=>(string)Str::uuid(),'name'=>'Invoice T-001','supplier_id'=>$this->supplier,'supplier_name'=>'Spoofed','purchase_date'=>'2026-10-07','due_date'=>'2026-10-14','invoice_number'=>'T-001','status'=>$status,'freight_minor'=>1000,'paid_minor'=>$status==='received'?50000:0,'payment_mode'=>'cash','lines'=>[['id'=>(string)Str::uuid(),'purchase_item_id'=>$this->item,'item_name'=>'Spoofed','unit'=>'kg','quantity_milli'=>5000,'unit_price_minor'=>20000,'discount_minor'=>1000,'tax_basis_points'=>500,'total_minor'=>1]]];}
    private function event(string $kind,array $bill,int $amount=0,int $quantity=0): array {return ['id'=>(string)Str::uuid(),'name'=>$kind,'kind'=>$kind,'bill_id'=>$bill['id'],'date'=>'2026-10-07','amount_minor'=>$amount,'payment_mode'=>'cash','note'=>'Test reason','lines'=>$quantity?[['line_id'=>$bill['lines'][0]['id'],'purchase_item_id'=>$this->item,'item_name'=>'Tomato','unit'=>'kg','quantity_milli'=>$quantity]]:[]];}
    public function test_server_recalculates_totals_and_isolates_tenants(): void {
        $bill=$this->bill();$this->writeLedger('purchase_bills',$bill)->assertCreated()->assertJsonPath('total_minor',104950)->assertJsonPath('lines.0.total_minor',103950)->assertJsonPath('supplier_name','Fresh Foods')->assertJsonPath('lines.0.item_name','Tomato');
        $other=User::factory()->create(['role'=>'owner']);$this->token=$other->createToken('other')->plainTextToken;
        $this->getJson('/api/purchase_bills/'.$bill['id'],$this->headers())->assertNotFound();
        $this->writeLedger('purchase_bills',$this->bill())->assertUnprocessable();
    }
    public function test_order_receive_once_and_posted_bill_is_immutable(): void {
        $bill=$this->bill('ordered');$this->writeLedger('purchase_bills',$bill)->assertCreated();
        $bill['status']='received';$bill['version']=1;
        $this->putJson('/api/purchase_bills/'.$bill['id'],$bill,$this->headers())->assertOk()->assertJsonPath('version',2);
        $bill['version']=2;
        $this->putJson('/api/purchase_bills/'.$bill['id'],$bill,$this->headers())->assertConflict();
        $this->deleteJson('/api/purchase_bills/'.$bill['id'],['version'=>2],$this->headers())->assertStatus(405);
        $this->assertDatabaseCount('purchase_bills',1);
    }
    public function test_payment_retry_and_overpayment_protection(): void {
        $bill=$this->bill();$this->writeLedger('purchase_bills',$bill)->assertCreated();
        $event=$this->event('payment',$bill,54950);$key=(string)Str::uuid();
        $this->writeLedger('purchase_events',$event,$key)->assertCreated();$this->writeLedger('purchase_events',$event,$key)->assertCreated();
        $this->assertDatabaseCount('purchase_events',1);
        $this->writeLedger('purchase_events',$this->event('payment',$bill,1))->assertUnprocessable();
        $this->writeLedger('purchase_events',$event)->assertConflict();
    }
    public function test_return_credit_refund_and_stock_limits(): void {
        $bill=$this->bill();$bill['paid_minor']=104950;$this->writeLedger('purchase_bills',$bill)->assertCreated();
        $return=$this->event('return',$bill,999999,1000);
        $this->writeLedger('purchase_events',$return)->assertCreated()->assertJsonPath('amount_minor',20790);
        $this->writeLedger('purchase_events',$this->event('refund',$bill,20791))->assertUnprocessable();
        $this->writeLedger('purchase_events',$this->event('refund',$bill,20790))->assertCreated();
        $this->writeLedger('purchase_events',$this->event('return',$bill,0,5000))->assertUnprocessable();
        $usage=$this->event('usage',$bill,0,4000);$usage['bill_id']=null;
        $this->writeLedger('purchase_events',$usage)->assertCreated();
        $this->writeLedger('purchase_events',$this->event('return',$bill,0,1))->assertUnprocessable();
    }
    public function test_duplicate_invoice_dates_and_version_conflicts(): void {
        $bill=$this->bill('draft');$this->writeLedger('purchase_bills',$bill)->assertCreated();
        $this->writeLedger('purchase_bills',$this->bill())->assertUnprocessable();
        $bill['version']=99;$this->putJson('/api/purchase_bills/'.$bill['id'],$bill,$this->headers())->assertConflict();
        $bad=$this->bill();$bad['invoice_number']='NEW';$bad['purchase_date']='2026-02-31';$this->writeLedger('purchase_bills',$bad)->assertUnprocessable();
        $this->writeLedger('purchase_events',$this->event('payment',$bill,100))->assertUnprocessable();
    }
    public function test_staff_cannot_read_or_sync_purchase_records(): void {
        $staff=User::factory()->create(['role'=>'waiter','owner_id'=>$this->owner->id]);$this->token=$staff->createToken('staff')->plainTextToken;
        $this->getJson('/api/purchase_suppliers',$this->headers())->assertForbidden();
        $this->getJson('/api/purchase_events',$this->headers())->assertForbidden();
        $this->writeLedger('purchase_bills',$this->bill())->assertForbidden();
        $result=$this->getJson('/api/updates?last_checked=0',$this->headers())->assertOk()->json('changes');
        $this->assertSame([],array_values(array_filter($result,fn($e)=>str_starts_with($e['resource'],'purchase_'))));
    }
    public function test_reorder_levels_round_trip_and_backdated_usage_are_validated(): void {
        $item=\App\Services\Records::get('purchase_items',$this->owner->id,$this->item);
        $item['reorder_levels']=['kg'=>2000];
        $this->putJson('/api/purchase_items/'.$this->item,$item,$this->headers())->assertOk()->assertJsonPath('reorder_levels.kg',2000);
        $bill=$this->bill();$this->writeLedger('purchase_bills',$bill)->assertCreated();
        $bad=$this->event('usage',$bill,0,1000);$bad['date']='2026-10-06';$bad['bill_id']=null;
        $this->writeLedger('purchase_events',$bad)->assertUnprocessable();
        $payment=$this->event('payment',$bill,100);$payment['date']='2026-10-06';
        $this->writeLedger('purchase_events',$payment)->assertUnprocessable();
    }
}
