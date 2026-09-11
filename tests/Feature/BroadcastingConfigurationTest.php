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

    public function test_a_guest_cannot_authorize_a_private_channel(): void
    {
        $this->post('/broadcasting/auth', [
            'channel_name' => 'private-App.Models.User.1',
            'socket_id' => '1.1',
        ])->assertRedirect(route('login'));
    }
}
