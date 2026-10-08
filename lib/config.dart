import 'package:flutter/foundation.dart';

/// Backend base URL.
///
/// A physical phone cannot reach `localhost` on your dev machine. Pass your
/// LAN IP or a tunnel URL at build time:
///
/// ```sh
/// flutter run --dart-define=BASE_URL=http://192.168.1.10:3300
/// ```
const String kBaseUrl = String.fromEnvironment(
  'BASE_URL',
  defaultValue: 'https://smasher-strung-wages.ngrok-free.dev', // Android emulator -> host machine
);

/// Socket.IO namespace exposed by the NestJS gateway.
const String kWsNamespace = '/ws';

/// How often GPS fixes are pushed over the socket while streaming.
const Duration kLocationSendInterval = Duration(seconds: 3);

/// Refresh the access token this long before its `exp` claim.
const Duration kTokenRefreshLeeway = Duration(seconds: 60);

/// Google OAuth **Web** client ID. Used as `serverClientId` so the ID token's
/// `aud` matches the backend's `GOOGLE_CLIENT_IDS` on Android and iOS.
///
/// ```sh
/// flutter run \
///   --dart-define=GOOGLE_WEB_CLIENT_ID=xxx.apps.googleusercontent.com \
///   --dart-define=GOOGLE_IOS_CLIENT_ID=yyy.apps.googleusercontent.com
/// ```
/// Client IDs are public (not secrets), so a default is safe to commit.
const String kGoogleWebClientId = String.fromEnvironment(
  'GOOGLE_WEB_CLIENT_ID',
  defaultValue: '715352002331-ar5dtgkltr8pojc72ajh998kagv4ivji.apps.googleusercontent.com',
);

/// Google OAuth **iOS** client ID. Only used on iOS/macOS.
const String kGoogleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');

/// RevenueCat **public** SDK keys (per store). Public keys are safe in the app.
/// A real key opens the App Store / Google Play payment sheet (sandbox for
/// testers):
///
/// ```sh
/// flutter run \
///   --dart-define=REVENUECAT_APPLE_KEY=appl_xxx \
///   --dart-define=REVENUECAT_GOOGLE_KEY=goog_xxx
/// ```
///
/// Without a real key, debug builds fall back to the RevenueCat **Test
/// Store** key: a popup fakes the payment, but the purchase still reaches
/// RevenueCat, so backend sync works. Release builds never use it:
/// `PurchasesService` refuses `test_` keys outside debug.
const String kRevenueCatAppleKey = String.fromEnvironment(
  'REVENUECAT_APPLE_KEY',
  defaultValue: kDebugMode ? _kRevenueCatTestStoreKey : '',
);
const String kRevenueCatGoogleKey = String.fromEnvironment(
  'REVENUECAT_GOOGLE_KEY',
  defaultValue: kDebugMode ? _kRevenueCatTestStoreKey : '',
);
const String _kRevenueCatTestStoreKey = 'test_pVVIhhIarUqhpDqduGBQBMPpeyw';

/// Android `applicationId`, for the Play Store subscriptions link fallback.
/// Keep in sync with `android/app/build.gradle.kts`.
const String kAndroidPackageId = 'com.example.web_socket';
