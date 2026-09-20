import type { ExpoConfig } from 'expo/config';

const packageName = process.env.EXPO_PUBLIC_PACKAGE_NAME ?? 'dev.grego5.inksignpdf';
const appName = process.env.EXPO_PUBLIC_APP_NAME ?? 'Inksign PDF';
const slug = process.env.EXPO_PUBLIC_SLUG ?? 'inksign-pdf-test';
const scheme = process.env.EXPO_PUBLIC_URL_SCHEME ?? 'inksign-pdf';

const config: ExpoConfig = {
  name: appName,
  slug,
  scheme,
  version: process.env.npm_package_version ?? '58.0.0',
  orientation: 'portrait',
  icon: './assets/icon.png',
  userInterfaceStyle: 'automatic',
  plugins: [
    'expo-dev-client',
    'expo-sharing',
    'expo-asset',
    'expo-system-ui',
  ],
  ios: {
    bundleIdentifier: packageName,
    supportsTablet: true,
    infoPlist: {
      ITSAppUsesNonExemptEncryption: false,
    },
  },
  android: {
    package: packageName,
    adaptiveIcon: {
      backgroundColor: '#E6F4FE',
      foregroundImage: './assets/android-icon-foreground.png',
      backgroundImage: './assets/android-icon-background.png',
      monochromeImage: './assets/android-icon-monochrome.png',
    },
  },
  web: {
    favicon: './assets/favicon.png',
  },
  extra: {
    eas: {
      projectId: 'b825bd4f-2e41-4778-994e-119dac0fc512',
    },
  },
};

export default config;
