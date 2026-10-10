<?php
namespace App\Http\Controllers;

use App\Models\User;
use App\Services\RestaurantDefaults;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Hash;
use Illuminate\Validation\ValidationException;

final class AuthController {
    public function register(Request $r) {
        $v=$r->validate(['name'=>'required|string|max:120','email'=>'required|email|max:255|unique:users,email','password'=>'required|string|min:8|max:255','activation_code'=>'required|digits_between:4,5','device_name'=>'required|string|max:80']);
        $provided=strtoupper(preg_replace('/[^A-Z0-9]/i','',$v['activation_code']));
        $codes=collect([(string) config('app.registration_code')])
            ->merge(explode(',', (string) config('app.registration_codes')))
            ->map(fn(string $code)=>strtoupper(preg_replace('/[^A-Z0-9]/i','',$code)))
            ->filter()
            ->unique();
        if (!$codes->contains($provided)) throw ValidationException::withMessages(['activation_code'=>'Activation code is invalid.']);
        $user=User::create(['name'=>$v['name'],'restaurant_name'=>$v['name'],'email'=>$v['email'],'password'=>$v['password'],'role'=>'owner']);
        RestaurantDefaults::installFor($user);
        return response()->json(['token'=>$user->createToken($v['device_name'],['*'],now()->addDays(30))->plainTextToken,'user'=>$user],201);
    }
    public function login(Request $r) {
        $v=$r->validate(['email'=>'required|email','password'=>'required|string','device_name'=>'required|string|max:80']);
        $user=User::where('email',$v['email'])->first();
        if (!$user || !Hash::check($v['password'],$user->password)) throw ValidationException::withMessages(['email'=>'Email or password is incorrect.']);
        return response()->json(['token'=>$user->createToken($v['device_name'],['*'],now()->addDays(30))->plainTextToken,'user'=>$user]);
    }
    public function me(Request $r) { return response()->json($r->user()); }
    public function logout(Request $r) { $r->user()->currentAccessToken()->delete(); return response()->json(['ok'=>true]); }
}
