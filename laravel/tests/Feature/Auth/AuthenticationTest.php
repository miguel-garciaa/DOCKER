<?php

namespace Tests\Feature\Auth;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Fortify\Features;
use Tests\TestCase;

class AuthenticationTest extends TestCase
{
    use RefreshDatabase;

    public function test_login_screen_can_be_rendered()
    {
        $response = $this->get(route('login'));

        $response->assertOk();
    }

    public function test_users_can_authenticate_using_the_login_screen()
    {
        $user = User::factory()->create();

        $response = $this->post(route('login.store'), [
            'email' => $user->email,
            'password' => 'password',
        ]);

        $this->assertAuthenticated();
        $response->assertRedirect(route('dashboard', absolute: false));
    }

    public function test_users_with_two_factor_enabled_are_redirected_to_two_factor_challenge()
    {
        $this->skipUnlessFortifyHas(Features::twoFactorAuthentication());

        Features::twoFactorAuthentication([
            'confirm' => true,
            'confirmPassword' => true,
        ]);

        $user = User::factory()->withTwoFactor()->create();

        $response = $this->post(route('login'), [
            'email' => $user->email,
            'password' => 'password',
        ]);

        $response->assertRedirect(route('two-factor.login'));
        $response->assertSessionHas('login.id', $user->id);
        $this->assertGuest();
    }

    public function test_users_can_not_authenticate_with_invalid_password()
    {
        $user = User::factory()->create();

        $this->post(route('login.store'), [
            'email' => $user->email,
            'password' => 'wrong-password',
        ]);

        $this->assertGuest();
    }

    public function test_users_can_logout()
    {
        $user = User::factory()->create();

        $response = $this->actingAs($user)->post(route('logout'));

        $response->assertRedirect(route('home'));

        $this->assertGuest();
    }

    public function test_users_are_rate_limited()
    {
        $user = User::factory()->create();
        config(['app.rate_limit_per_minute' => 100]);

        foreach (range(1, 5) as $_) {
            $this->post(route('login.store'), [
                'email' => $user->email,
                'password' => 'wrong-password',
            ])->assertStatus(302);
        }

        $response = $this->post(route('login.store'), [
            'email' => $user->email,
            'password' => 'wrong-password',
        ]);

        $response->assertTooManyRequests();
    }

    public function test_login_account_limit_cannot_be_bypassed_by_rotating_ips(): void
    {
        config(['app.rate_limit_per_minute' => 100]);
        $user = User::factory()->create();

        foreach (range(1, 20) as $attempt) {
            $response = $this
                ->withServerVariables(['REMOTE_ADDR' => "203.0.113.{$attempt}"])
                ->post(route('login.store'), [
                    'email' => $user->email,
                    'password' => 'wrong-password',
                ]);

            $this->assertNotSame(429, $response->getStatusCode());
        }

        $this
            ->withServerVariables(['REMOTE_ADDR' => '198.51.100.25'])
            ->post(route('login.store'), [
                'email' => $user->email,
                'password' => 'wrong-password',
            ])
            ->assertTooManyRequests();

        $this
            ->withServerVariables(['REMOTE_ADDR' => '198.51.100.26'])
            ->post(route('login.store'), [
                'email' => 'another@example.com',
                'password' => 'wrong-password',
            ])
            ->assertStatus(302);
    }

    public function test_passkey_rate_limit_cannot_be_bypassed_with_different_credential_ids(): void
    {
        $this->skipUnlessFortifyHas(Features::passkeys());
        config(['app.rate_limit_per_minute' => 100]);

        foreach (range(1, 10) as $attempt) {
            $response = $this->postJson(route('passkey.login'), [
                'credential' => ['id' => "attacker-controlled-{$attempt}"],
            ]);

            $this->assertNotSame(429, $response->getStatusCode());
        }

        $this->postJson(route('passkey.login'), [
            'credential' => ['id' => 'another-attacker-controlled-id'],
        ])->assertTooManyRequests();
    }
}
