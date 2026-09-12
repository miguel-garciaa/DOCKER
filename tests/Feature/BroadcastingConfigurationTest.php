<?php

namespace Tests\Feature;

use Tests\TestCase;

class BroadcastingConfigurationTest extends TestCase
{
    public function test_reverb_never_accepts_a_wildcard_origin(): void
    {
        $origins = config('reverb.apps.apps.0.allowed_origins');

        $this->assertIsArray($origins);
        $this->assertNotContains('*', $origins);
    }

    public function test_reverb_rejects_events_sent_directly_by_clients(): void
    {
        $acceptedClients = config('reverb.apps.apps.0.accept_client_events_from');

        $this->assertNotContains($acceptedClients, ['all', 'members']);
    }

    public function test_the_browser_receives_public_reverb_settings_at_runtime(): void
    {
        config()->set('broadcasting.connections.reverb.key', 'public-runtime-key');
        config()->set('reverb.public', [
            'host' => 'calendar.example.com',
            'port' => 443,
            'scheme' => 'https',
        ]);

        $this->get(route('home'))
            ->assertOk()
            ->assertSee('name="csrf-token"', false)
            ->assertSee('<meta name="reverb-app-key" content="public-runtime-key">', false)
            ->assertSee('<meta name="reverb-host" content="calendar.example.com">', false)
            ->assertSee('<meta name="reverb-port" content="443">', false)
            ->assertSee('<meta name="reverb-scheme" content="https">', false);
    }

    public function test_a_guest_cannot_authorize_a_private_channel(): void
    {
        $this->post('/broadcasting/auth', [
            'channel_name' => 'private-App.Models.User.1',
            'socket_id' => '1.1',
        ])->assertRedirect(route('login'));
    }
}
