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

        Route::get('/_proxy-test', fn (Request $request) => response()->json([
            'ip' => $request->ip(),
            'secure' => $request->isSecure(),
        ]));
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
}
