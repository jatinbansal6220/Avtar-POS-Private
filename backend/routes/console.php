<?php

use App\Models\User;
use Illuminate\Support\Facades\Validator;
use Illuminate\Support\Facades\Artisan;

Artisan::command('restaurant:create {email} {restaurant}', function () {
    $values=['email'=>$this->argument('email'),'restaurant_name'=>$this->argument('restaurant'),'password'=>$this->secret('Owner password (at least 12 characters)')];
    $validator=Validator::make($values,['email'=>'required|email|unique:users,email','restaurant_name'=>'required|string|max:160','password'=>'required|string|min:12']);
    if ($validator->fails()) { $this->error($validator->errors()->first()); return 1; }
    User::create($values+['name'=>$values['restaurant_name'],'role'=>'owner']);
    $this->info('Owner created. Sign in and complete settings. No sample data inserted.');
})->purpose('Create a real restaurant owner');

Artisan::command('restaurant:login {owner_email} {email} {role}', function () {
    $owner=User::where('email',$this->argument('owner_email'))->whereNull('owner_id')->firstOrFail();
    $values=['email'=>$this->argument('email'),'role'=>$this->argument('role'),'password'=>$this->secret('Password (at least 12 characters)')];
    $validator=Validator::make($values,['email'=>'required|email|unique:users,email','role'=>'required|in:manager,cashier,waiter','password'=>'required|string|min:12']);
    if ($validator->fails()) { $this->error($validator->errors()->first()); return 1; }
    User::create($values+['name'=>$this->ask('Staff name'),'owner_id'=>$owner->id,'restaurant_name'=>$owner->restaurant_name]);
    $this->info('Staff login created. HR profiles and login access are separate.');
})->purpose('Provision a role-scoped restaurant login');
