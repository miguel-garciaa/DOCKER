import { createInertiaApp } from '@inertiajs/react';
import { Toaster } from '@/components/ui/sonner';
import { TooltipProvider } from '@/components/ui/tooltip';
import { initializeTheme } from '@/hooks/use-appearance';
import AppLayout from '@/layouts/app-layout';
import AuthLayout from '@/layouts/auth-layout';
import SettingsLayout from '@/layouts/settings/layout';
import { configureEcho } from '@laravel/echo-react';

const metaContent = (name: string): string =>
    document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content ??
    '';

const reverbPort = Number(metaContent('reverb-port')) || 443;

configureEcho({
    broadcaster: 'reverb',
    key: metaContent('reverb-app-key'),
    wsHost: metaContent('reverb-host'),
    wsPort: reverbPort,
    wssPort: reverbPort,
    forceTLS: metaContent('reverb-scheme') === 'https',
    enabledTransports: ['ws', 'wss'],
});

const appName = metaContent('app-name') || 'Laravel';

void createInertiaApp({
    title: (title) => (title ? `${title} - ${appName}` : appName),
    layout: (name) => {
        switch (true) {
            case name === 'welcome':
                return null;
            case name.startsWith('auth/'):
                return AuthLayout;
            case name.startsWith('settings/'):
                return [AppLayout, SettingsLayout];
            default:
                return AppLayout;
        }
    },
    strictMode: true,
    withApp(app) {
        return (
            <TooltipProvider delayDuration={0}>
                {app}
                <Toaster />
            </TooltipProvider>
        );
    },
    progress: {
        color: '#4B5563',
    },
});

// This will set light / dark mode on load...
initializeTheme();
