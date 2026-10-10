<?php
namespace App\Http\Controllers;

use App\Services\DeveloperControls;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\DB;

final class DeveloperController {
    public function policy(Request $request) {
        return response()->json(DeveloperControls::effective($request->user()->tenantId()));
    }
    public function unlock(Request $request) {
        $value = $request->validate(['password' => 'required|string|max:72']);
        abort_unless($request->user()->currentAccessToken() instanceof \Laravel\Sanctum\PersonalAccessToken, 403, 'Use an authenticated app API session.');
        $hash = (string) config('developer.password_hash');
        abort_if($hash === '', 503, 'Developer access has not been configured on the server.');
        abort_unless(strlen($value['password']) <= 72 && password_verify($value['password'], $hash), 403, 'Developer password is incorrect.');
        $expires = now()->addMinutes(10)->timestamp;
        return response()->json(['developer_token' => Crypt::encryptString(json_encode([
            'user' => $request->user()->id,
            'token' => (string) $request->user()->currentAccessToken()?->getKey(),
            'expires' => $expires, 'credential' => hash('sha256', $hash),
        ], JSON_THROW_ON_ERROR)), 'expires_at' => $expires]);
    }
    public function index() {
        return response()->json(['catalog' => config('developer.features'),
            'global' => DeveloperControls::read('global'),
            'tenants' => DB::table('users')->whereNull('owner_id')->orderBy('id')->get(['id', 'restaurant_name', 'name'])->map(fn($row) => [
                'id' => $row->id, 'name' => $row->restaurant_name ?: $row->name,
                'control' => DeveloperControls::read('tenant:'.$row->id),
            ])]);
    }
    public function save(Request $request, string $scope) {
        abort_unless($scope === 'global' || preg_match('/^tenant:[1-9][0-9]*$/D', $scope), 422, 'Invalid control scope.');
        if ($scope !== 'global') abort_unless(DB::table('users')->where('id', substr($scope, 7))->whereNull('owner_id')->exists(), 404);
        $keys = array_keys(config('developer.features'));
        $rules = ['revision' => 'required|integer|min:0', 'policy' => 'required|array:app_enabled,message,features',
            'policy.app_enabled' => 'required|boolean', 'policy.message' => 'required|string|max:240',
            'policy.features' => 'required|array:'.implode(',', $keys)];
        foreach ($keys as $key) $rules['policy.features.'.$key] = 'required|boolean';
        $value = $request->validate($rules);
        $value['revision'] = (int) $value['revision'];
        $value['policy']['app_enabled'] = (bool) $value['policy']['app_enabled'];
        $value['policy']['features'] = array_map(fn($flag) => (bool) $flag, $value['policy']['features']);
        return DB::transaction(function () use ($request, $scope, $value) {
            DB::table('developer_controls')->insertOrIgnore(['scope' => $scope,
                'encrypted_policy' => Crypt::encryptString(json_encode(DeveloperControls::defaults(), JSON_THROW_ON_ERROR)),
                'revision' => 0, 'created_at' => now(), 'updated_at' => now()]);
            $row = DB::table('developer_controls')->where('scope', $scope)->lockForUpdate()->first();
            abort_unless($row->revision === $value['revision'], 409, 'Controls changed in another panel. Reload before saving.');
            DB::table('developer_controls')->where('scope', $scope)->update([
                'encrypted_policy' => Crypt::encryptString(json_encode($value['policy'], JSON_THROW_ON_ERROR)),
                'revision' => $row->revision + 1, 'updated_by' => $request->user()->id, 'updated_at' => now()]);
            DB::table('developer_control_audits')->insert(['scope' => $scope, 'actor_id' => $request->user()->id,
                'encrypted_change' => Crypt::encryptString(json_encode(['before' => json_decode(Crypt::decryptString($row->encrypted_policy), true),
                    'after' => $value['policy']], JSON_THROW_ON_ERROR)), 'created_at' => now()]);
            return response()->json(DeveloperControls::read($scope));
        }, 3);
    }
}
