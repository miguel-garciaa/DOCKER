<?php

namespace Tests\Feature;

use App\Models\User;
use Filament\Panel;
use Laravel\Fortify\Features;
use Tests\TestCase;

class FilamentAccessTest extends TestCase
{
    public function test_only_the_verified_exact_email_can_access_the_admin_panel(): void
    {
        config()->set('filament-access.admin_email', 'admin@example.com');
        Features::twoFactorAuthentication(['confirm' => true]);

        $adminPanel = Panel::make()->id('admin');
        $admin = User::factory()->withTwoFactor()->make(['email' => 'admin@example.com']);
        $adminWithoutTwoFactor = User::factory()->make(['email' => 'admin@example.com']);
        $caseVariant = (new User)->forceFill(['email' => 'ADMIN@example.com', 'email_verified_at' => now()]);
        $unverifiedAdmin = new User(['email' => 'admin@example.com']);
        $anotherUser = new User(['email' => 'user@example.com']);

        $this->assertTrue($admin->canAccessPanel($adminPanel));
        $this->assertFalse($adminWithoutTwoFactor->canAccessPanel($adminPanel));
        $this->assertFalse($caseVariant->canAccessPanel($adminPanel));
        $this->assertFalse($unverifiedAdmin->canAccessPanel($adminPanel));
        $this->assertFalse($anotherUser->canAccessPanel($adminPanel));
        $this->assertFalse($admin->canAccessPanel(Panel::make()->id('staff')));
    }

    public function test_two_factor_feature_must_be_enabled_for_admin_access(): void
    {
        config()->set('filament-access.admin_email', 'admin@example.com');
        config()->set('fortify.features', []);

        $admin = User::factory()->withTwoFactor()->make(['email' => 'admin@example.com']);

        $this->assertFalse($admin->canAccessPanel(Panel::make()->id('admin')));
    }

    public function test_an_empty_admin_email_denies_access(): void
    {
        config()->set('filament-access.admin_email', null);

        $this->assertFalse(
            (new User(['email' => 'admin@example.com']))
                ->canAccessPanel(Panel::make()->id('admin')),
        );
    }

    public function test_filament_login_redirects_to_the_fortify_login_and_uses_the_global_rate_limit(): void
    {
        config(['app.rate_limit_per_minute' => 1]);

        $this->get('/admin/login')->assertRedirect(route('login'));
        $this->get('/admin/login')->assertTooManyRequests();
    }
}
