<?php
namespace App\Services;

use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\DB;

final class DeveloperControls {
    public static function defaults(): array {
        return ['app_enabled' => true, 'message' => 'Please contact the software developer.',
            'features' => array_fill_keys(array_keys(config('developer.features')), true)];
    }
    public static function read(string $scope): array {
        $row = DB::table('developer_controls')->where('scope', $scope)->first();
        return ['scope' => $scope, 'revision' => $row?->revision ?? 0,
            'policy' => $row ? array_replace_recursive(self::defaults(), json_decode(Crypt::decryptString($row->encrypted_policy), true, 512, JSON_THROW_ON_ERROR)) : self::defaults()];
    }
    public static function effective(int $tenant): array {
        $global = self::read('global');
        $local = self::read('tenant:'.$tenant);
        $policy = $local['policy'];
        $policy['app_enabled'] = $global['policy']['app_enabled'] && $policy['app_enabled'];
        if (!$global['policy']['app_enabled']) $policy['message'] = $global['policy']['message'];
        foreach (array_keys(config('developer.features')) as $key) {
            $policy['features'][$key] = $global['policy']['features'][$key] && $local['policy']['features'][$key];
        }
        return ['policy' => $policy, 'revision' => $global['revision'].':'.$local['revision']];
    }
}
