<?php
namespace Tests\Feature;

use App\Models\User;
use App\Services\DeveloperControls;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Crypt;
use Illuminate\Support\Facades\DB;
use Tests\TestCase;

class DeveloperControlsTest extends TestCase {
    use RefreshDatabase;
    private User $owner;
    private string $bearer;
    protected function migrateDatabases(): void {
        // Existing terminal-number migration uses MySQL SHOW INDEX. These
        // integration tests use an isolated in-memory SQLite database and
        // all other migrations; production migrations remain unchanged.
        $paths = array_values(array_filter(glob(database_path('migrations/*.php')),
            fn($path) => basename($path) !== '2026_09_30_000010_make_bill_numbers_terminal_scoped.php'));
        $this->artisan('migrate:fresh', ['--path' => $paths, '--realpath' => true]);
    }
    protected function setUp(): void {
        parent::setUp();
        config(['app.key' => 'base64:'.base64_encode(random_bytes(32)),
            'developer.password_hash' => password_hash('test-only-password', PASSWORD_BCRYPT)]);
        $this->owner = User::factory()->create(['role' => 'owner']);
        $this->bearer = $this->owner->createToken('test')->plainTextToken;
    }
    private function headers(?string $grant = null): array {
        $this->app['auth']->forgetGuards();
        return ['Authorization' => 'Bearer '.$this->bearer] + ($grant ? ['X-Developer-Token' => $grant] : []);
    }
    private function unlock(): string {
        return $this->postJson('/api/developer/unlock', ['password' => 'test-only-password'], $this->headers())
            ->assertOk()->json('developer_token');
    }
    private function save(string $grant, array $policy, string $scope = 'global', int $revision = 0) {
        return $this->putJson('/api/developer/controls/'.$scope, compact('policy', 'revision'), $this->headers($grant));
    }
    public function test_password_required_and_default_policy_has_no_secrets(): void {
        $this->getJson('/api/control-policy')->assertUnauthorized();
        $this->getJson('/api/developer/controls', $this->headers())->assertForbidden();
        $this->postJson('/api/developer/unlock', ['password' => 'wrong'], $this->headers())->assertForbidden();
        $this->getJson('/api/control-policy', $this->headers())->assertOk()->assertJsonPath('policy.app_enabled', true);
        $this->assertStringNotContainsString('password', $this->getJson('/api/control-policy', $this->headers())->getContent());
        config(['developer.password_hash' => '']);
        $this->postJson('/api/developer/unlock', ['password' => 'test-only-password'], $this->headers())->assertStatus(503);
    }
    public function test_encrypted_policy_audit_and_optimistic_revision(): void {
        $grant = $this->unlock(); $policy = DeveloperControls::defaults();
        $policy['message'] = 'Private control notice'; $policy['features']['kot'] = false;
        $this->save($grant, $policy)->assertOk()->assertJsonPath('revision', 1);
        $row = DB::table('developer_controls')->first();
        $this->assertStringNotContainsString('Private control notice', $row->encrypted_policy);
        $this->assertSame($policy, json_decode(Crypt::decryptString($row->encrypted_policy), true));
        $audit = DB::table('developer_control_audits')->first();
        $this->assertStringNotContainsString('Private control notice', $audit->encrypted_change);
        $this->assertSame($this->owner->id, $audit->actor_id);
        $this->save($grant, $policy)->assertConflict();
        $this->assertDatabaseCount('developer_control_audits', 1);
    }
    public function test_global_disable_cannot_be_overridden_and_tenant_isolation(): void {
        $grant = $this->unlock(); $policy = DeveloperControls::defaults();
        $policy['features']['printing'] = false;
        $this->save($grant, $policy)->assertOk();
        $other = User::factory()->create(['role' => 'owner']);
        $tenant = DeveloperControls::defaults(); $tenant['app_enabled'] = false;
        $this->save($grant, $tenant, 'tenant:'.$other->id)->assertOk();
        $this->assertTrue(DeveloperControls::effective($this->owner->id)['policy']['app_enabled']);
        $this->assertFalse(DeveloperControls::effective($other->id)['policy']['app_enabled']);
        $this->assertFalse(DeveloperControls::effective($other->id)['policy']['features']['printing']);
        $this->save($grant, DeveloperControls::defaults(), 'tenant:'.$this->owner->id)->assertOk();
        $this->assertFalse(DeveloperControls::effective($this->owner->id)['policy']['features']['printing']);
    }
    public function test_grant_expiry_rotation_and_token_binding(): void {
        $grant = $this->unlock();
        $this->getJson('/api/developer/controls', $this->headers($grant))->assertOk();
        $original = $this->bearer;
        $this->bearer = $this->owner->createToken('other terminal')->plainTextToken;
        $this->getJson('/api/developer/controls', $this->headers($grant))->assertForbidden();
        $this->bearer = $original;
        $this->travel(11)->minutes();
        $this->getJson('/api/developer/controls', $this->headers($grant))->assertForbidden();
        $this->travelBack();
        config(['developer.password_hash' => password_hash('rotated-password', PASSWORD_BCRYPT)]);
        $this->getJson('/api/developer/controls', $this->headers($grant))->assertForbidden();
    }
    public function test_unknown_flags_invalid_scope_and_partial_policy_rejected(): void {
        $grant = $this->unlock(); $policy = DeveloperControls::defaults();
        $policy['features']['unknown'] = false;
        $this->save($grant, $policy)->assertUnprocessable();
        $this->save($grant, [], 'tenant:999999')->assertNotFound();
        $this->save($grant, [], 'anything')->assertUnprocessable();
        $this->save($grant, ['app_enabled' => true])->assertUnprocessable();
        $this->assertDatabaseCount('developer_controls', 0);
    }
    public function test_pause_preserves_existing_sync_api_for_durable_uploads(): void {
        $grant = $this->unlock(); $policy = DeveloperControls::defaults(); $policy['app_enabled'] = false;
        $this->save($grant, $policy)->assertOk();
        $this->getJson('/api/updates?last_checked=0', $this->headers())->assertOk();
        $this->getJson('/api/auth/me', $this->headers())->assertOk();
        $this->getJson('/api/control-policy', $this->headers())->assertOk()->assertJsonPath('policy.app_enabled', false);
    }
}
