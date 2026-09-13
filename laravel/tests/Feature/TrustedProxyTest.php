<?php

namespace Tests\Feature;

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;
use Tests\TestCase;

class TrustedProxyTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        config(['app.trusted_proxy_host' => '172.30.92.2']);

        Route::get('/_proxy-test', fn (Request $request) => response()->json([
            'ip' => $request->ip(),
            'secure' => $request->isSecure(),
        ]))->middleware('web');
    }

    public function test_it_trusts_forwarded_headers_from_the_gateway(): void
    {
        $this->withServerVariables([
            'REMOTE_ADDR' => '172.30.92.2',
            'HTTP_X_FORWARDED_FOR' => '203.0.113.10',
            'HTTP_X_FORWARDED_PROTO' => 'https',
        ])->get('/_proxy-test')->assertExactJson([
            'ip' => '203.0.113.10',
            'secure' => true,
        ]);
    }

    public function test_it_ignores_forwarded_headers_that_bypass_the_gateway(): void
    {
        $this->withServerVariables([
            'REMOTE_ADDR' => '172.30.91.2',
            'HTTP_X_FORWARDED_FOR' => '203.0.113.10',
            'HTTP_X_FORWARDED_PROTO' => 'https',
        ])->get('/_proxy-test')->assertExactJson([
            'ip' => '172.30.91.2',
            'secure' => false,
        ]);
    }

    public function test_it_fails_closed_when_the_proxy_is_not_configured(): void
    {
        config(['app.trusted_proxy_host' => '']);
        $this->withServerVariables([
            'REMOTE_ADDR' => '172.30.92.2',
            'HTTP_X_FORWARDED_FOR' => '203.0.113.10',
        ])->get('/_proxy-test')->assertJsonPath('ip', '172.30.92.2');
    }

    public function test_it_refreshes_the_proxy_between_octane_requests(): void
    {
        $this->withServerVariables([
            'REMOTE_ADDR' => '172.30.92.2',
            'HTTP_X_FORWARDED_FOR' => '203.0.113.10',
        ])->get('/_proxy-test')->assertJsonPath('ip', '203.0.113.10');

        config(['app.trusted_proxy_host' => '172.20.0.9']);
        $this->get('/_proxy-test')->assertJsonPath('ip', '172.30.92.2');
    }

    public function test_it_blocks_configured_client_ips_and_cidr_ranges(): void
    {
        config(['app.blocked_ips' => ['203.0.113.0/24']]);

        $this->withServerVariables([
            'REMOTE_ADDR' => '172.30.92.2',
            'HTTP_X_FORWARDED_FOR' => '203.0.113.10',
            'HTTP_X_FORWARDED_PROTO' => 'https',
        ])->get('/_proxy-test')->assertForbidden();
    }

    public function test_it_rate_limits_web_requests_by_client_ip(): void
    {
        config(['app.rate_limit_per_minute' => 1]);

        $server = [
            'REMOTE_ADDR' => '172.30.92.2',
            'HTTP_X_FORWARDED_FOR' => '198.51.100.20',
            'HTTP_X_FORWARDED_PROTO' => 'https',
        ];

        $this->withServerVariables($server)->get('/_proxy-test')->assertOk();
        $this->withServerVariables($server)->get('/_proxy-test')->assertTooManyRequests();
    }
}
