<?php

namespace Tests\Feature\Auth;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Socialite\Facades\Socialite;
use Laravel\Socialite\Two\InvalidStateException;
use Laravel\Socialite\Two\User as GoogleUser;
use Tests\TestCase;

class GoogleAuthenticationTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        config(['services.google.client_id' => 'test', 'services.google.client_secret' => 'test']);
    }

    private function google(string $email, bool $verified = true): void
    {
        $identity = (new GoogleUser)->setRaw(['email_verified' => $verified])
            ->map(['id' => 'google-id', 'email' => $email]);
        Socialite::shouldReceive('driver->user')->once()->andReturn($identity);
    }

    public function test_existing_verified_gmail_user_can_login(): void
    {
        $user = User::factory()->create(['email' => 'client@gmail.com']);
        $this->google($user->email);
        $this->get('/auth/google/callback')->assertRedirect(route('dashboard'));
        $this->assertAuthenticatedAs($user);
    }

    public function test_google_cannot_bypass_local_two_factor(): void
    {
        $user = User::factory()->withTwoFactor()->create(['email' => 'client@gmail.com']);
        $this->google($user->email);
        $this->get('/auth/google/callback')->assertRedirect(route('two-factor.login'))
            ->assertSessionHas('login.id', $user->id);
        $this->assertGuest();
    }

    public function test_google_cannot_create_accounts_implicitly(): void
    {
        $this->google('unknown@gmail.com');
        $this->get('/auth/google/callback')->assertSessionHasErrors('email');
        $this->assertDatabaseCount('users', 0);
        $this->assertGuest();
    }

    public function test_google_rejects_unverified_identity(): void
    {
        $user = User::factory()->create(['email' => 'client@gmail.com']);
        $this->google($user->email, false);
        $this->get('/auth/google/callback')->assertSessionHasErrors('email');
        $this->assertGuest();
    }

    public function test_google_rejects_third_party_email_without_workspace_authority(): void
    {
        $user = User::factory()->create(['email' => 'client@example.com']);
        $this->google($user->email);
        $this->get('/auth/google/callback')->assertSessionHasErrors('email');
        $this->assertGuest();
    }

    public function test_google_rejects_invalid_oauth_state(): void
    {
        Socialite::shouldReceive('driver->user')->once()->andThrow(new InvalidStateException);
        $this->get('/auth/google/callback')->assertRedirect(route('login'))->assertSessionHasErrors('email');
        $this->assertGuest();
    }

    public function test_google_can_be_disabled(): void
    {
        config(['services.google.client_id' => null]);
        $this->get('/auth/google')->assertNotFound();
        $this->get('/auth/google/callback')->assertNotFound();
    }

    public function test_cancelled_google_login_keeps_user_logged_out(): void
    {
        $this->get('/auth/google/callback?error=access_denied')->assertRedirect(route('login'));
        $this->assertGuest();
    }
}
