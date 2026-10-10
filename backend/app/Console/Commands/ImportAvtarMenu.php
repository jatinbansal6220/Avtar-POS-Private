<?php
namespace App\Console\Commands;
use App\Models\User;
use App\Services\Records;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

class ImportAvtarMenu extends Command {
    protected $signature='restaurant:import-avtar-menu {owner_email} {--replace}';
    protected $description='Import the supplied Avtar Cooks menu pricing without demo orders';
    public function handle(): int {
        $owner=User::where('email',$this->argument('owner_email'))->whereNull('owner_id')->first();
        if(!$owner){$this->error('Owner account not found.');return self::FAILURE;}
        $items=json_decode(file_get_contents(base_path('database/data/avtar_cooks_menu.json')),true,flags:JSON_THROW_ON_ERROR);
        if($this->option('replace')) DB::table('menu_items')->where('user_id',$owner->id)->whereNull('deleted_at')->update(['deleted_at'=>now(),'updated_at'=>now()]);
        foreach($items as $item){
            $existing=DB::table('menu_items')->where('user_id',$owner->id)->where('name',$item['name'])->whereNull('deleted_at')->first();
            $id=$existing->id??(string)Str::uuid();$data=['name'=>$item['name'],'price_minor'=>$item['price_minor'],'category'=>$item['category'],'is_active'=>true,'is_veg'=>true,'updated_at'=>now()];
            if($existing)DB::table('menu_items')->where('id',$id)->update($data+['version'=>$existing->version+1]);else DB::table('menu_items')->insert($data+['id'=>$id,'user_id'=>$owner->id,'version'=>1,'created_at'=>now()]);Records::emit('menu_items',$owner->id,$id);
        }
        $this->info('Avtar Cooks menu imported. No demo orders or bills were created.');return self::SUCCESS;
    }
}
