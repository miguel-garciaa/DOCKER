<?php

namespace Tests\Feature;

use App\Models\User;
use Filament\Panel;
use Tests\TestCase;

class FilamentAccessTest extends TestCase
{
    public function test_only_the_configured_email_can_access_the_admin_panel(): void
    {
        config()->set('filament-access.admin_email', 'admin@example.com');

        $adminPanel = Panel::make()->id('admin');
        $admin = new User(['email' => 'ADMIN@example.com']);
        $anotherUser = new User(['email' => 'user@example.com']);

        $this->assertTrue($admin->canAccessPanel($adminPanel));
        $this->assertFalse($anotherUser->canAccessPanel($adminPanel));
        $this->assertFalse($admin->canAccessPanel(Panel::make()->id('staff')));
    }

    public function test_an_empty_admin_email_denies_access(): void
    {
        config()->set('filament-access.admin_email', null);

        $this->assertFalse(
            (new User(['email' => 'admin@example.com']))
                ->canAccessPanel(Panel::make()->id('admin')),
        );
    }
}
