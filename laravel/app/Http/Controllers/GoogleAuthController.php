<?php

namespace App\Http\Controllers;

use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Laravel\Socialite\Facades\Socialite;
use Laravel\Socialite\Two\InvalidStateException;
use Laravel\Socialite\Two\User as GoogleUser;
use Symfony\Component\HttpFoundation\RedirectResponse;

class GoogleAuthController extends Controller
{
    public function redirect(): RedirectResponse
    {
        abort_unless(config('services.google.client_id') && config('services.google.client_secret'), 404);

        return Socialite::driver('google')->redirect();
    }

    public function callback(Request $request): RedirectResponse
    {
        abort_unless(config('services.google.client_id') && config('services.google.client_secret'), 404);

        if ($request->has('error')) {
            return to_route('login')->with('status', 'No se ha completado el acceso con Google.');
        }

        try {
            $google = Socialite::driver('google')->user();
        } catch (InvalidStateException) {
            return to_route('login')->withErrors(['email' => 'La sesión de Google ha caducado. Inténtalo de nuevo.']);
        }

        // Solo cuentas preexistentes verificadas; no vincular ni crear usuarios por email.
        // Google es autoritativo para Gmail y para Workspace con dominio alojado.
        $authoritative = $google instanceof GoogleUser
            && ($google->user['email_verified'] ?? false) === true
            && (str_ends_with(strtolower((string) $google->getEmail()), '@gmail.com')
                || ! empty($google->user['hd']));
        $user = $authoritative ? User::where('email', $google->getEmail())->first() : null;

        if (! $user || ! $user->hasVerifiedEmail()) {
            return to_route('login')->withErrors(['email' => 'No se puede acceder con esta cuenta de Google.']);
        }

        if ($user->hasEnabledTwoFactorAuthentication()) {
            $request->session()->put(['login.id' => $user->getKey(), 'login.remember' => false]);

            return to_route('two-factor.login');
        }

        Auth::login($user);
        $request->session()->regenerate();

        return redirect()->intended(route('dashboard'));
    }
}
