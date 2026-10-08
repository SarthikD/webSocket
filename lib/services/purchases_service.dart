import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../config.dart';

/// Thin wrapper around the RevenueCat SDK.
///
/// Only iOS and Android are wired up. On other platforms, or when no key is
/// passed via `--dart-define`, [isAvailable] is false and every call is a
/// no-op, so the rest of the app still runs.
///
/// The RevenueCat app user ID is always our user ID, so store webhooks map to
/// our user on the backend.
class PurchasesService {
  PurchasesService._();
  static final PurchasesService instance = PurchasesService._();

  bool _configured = false;

  String? _unavailableReason = 'Purchases not configured yet';

  bool get isAvailable => _configured;

  /// Why [isAvailable] is false, for the UI. `null` when available.
  String? get unavailableReason => _unavailableReason;

  /// Call once at app start. Pass [userId] when a session already exists so
  /// the SDK starts identified instead of anonymous.
  Future<void> configure({String? userId}) async {
    if (_configured) return;
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.android)) {
      _unavailableReason = 'In-app purchases need iOS or Android.';
      return;
    }
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    final apiKey = isIos ? kRevenueCatAppleKey : kRevenueCatGoogleKey;
    if (apiKey.isEmpty) {
      _unavailableReason = 'Missing RevenueCat key. Run with '
          '--dart-define=${isIos ? 'REVENUECAT_APPLE_KEY' : 'REVENUECAT_GOOGLE_KEY'}=<public key>.';
      return;
    }
    // The Test Store fakes payments: debug only, never in a shipped build.
    if (apiKey.startsWith('test_') && !kDebugMode) {
      _unavailableReason = 'RevenueCat Test Store key is not allowed in release builds. '
          'Use the real ${isIos ? 'appl_' : 'goog_'} public key.';
      return;
    }
    try {
      if (kDebugMode) await Purchases.setLogLevel(LogLevel.debug);
      await Purchases.configure(PurchasesConfiguration(apiKey)..appUserID = userId);
      _configured = true;
      _unavailableReason = null;
    } catch (e) {
      debugPrint('Purchases.configure failed: $e');
      _unavailableReason = 'RevenueCat setup failed: $e';
    }
  }

  /// Call after our login.
  Future<void> logIn(String userId) async {
    if (!_configured) return;
    try {
      await Purchases.logIn(userId);
    } catch (e) {
      debugPrint('Purchases.logIn failed: $e');
    }
  }

  /// Call on logout. The SDK throws if the current user is already anonymous.
  Future<void> logOut() async {
    if (!_configured) return;
    try {
      if (!await Purchases.isAnonymous) await Purchases.logOut();
    } catch (e) {
      debugPrint('Purchases.logOut failed: $e');
    }
  }

  /// The monthly package of the current offering, for the localized price
  /// and the purchase. `null` when the store has nothing to sell.
  Future<Package?> monthlyPackage() async {
    if (!_configured) return null;
    final offerings = await Purchases.getOfferings();
    return offerings.current?.monthly;
  }

  /// Opens the Apple or Google payment sheet as [userId]. Never buys as an
  /// anonymous RevenueCat user: the backend ignores `$RCAnonymousID:` users.
  /// Store errors other than cancel and pending are rethrown.
  Future<PurchaseOutcome> purchase(Package package, {required String userId}) async {
    if (await Purchases.appUserID != userId) await Purchases.logIn(userId);
    try {
      await Purchases.purchase(PurchaseParams.package(package));
      return PurchaseOutcome.purchased;
    } on PlatformException catch (e) {
      return switch (PurchasesErrorHelper.getErrorCode(e)) {
        PurchasesErrorCode.purchaseCancelledError => PurchaseOutcome.cancelled,
        PurchasesErrorCode.paymentPendingError => PurchaseOutcome.pending,
        _ => throw e,
      };
    }
  }

  /// One-time (consumable) products, for donations. Missing IDs are left out.
  Future<List<StoreProduct>> consumables(List<String> productIds) async {
    if (!_configured || productIds.isEmpty) return const [];
    return Purchases.getProducts(productIds, productCategory: ProductCategory.nonSubscription);
  }

  /// Buys a consumable as [userId]. Returns the store transaction ID, or
  /// `null` when the user cancels. Other store errors are rethrown.
  Future<String?> purchaseConsumable(StoreProduct product, {required String userId}) async {
    if (await Purchases.appUserID != userId) await Purchases.logIn(userId);
    try {
      final result = await Purchases.purchase(PurchaseParams.storeProduct(product));
      return result.storeTransaction.transactionIdentifier;
    } on PlatformException catch (e) {
      if (PurchasesErrorHelper.getErrorCode(e) == PurchasesErrorCode.purchaseCancelledError) {
        return null;
      }
      rethrow;
    }
  }

  Future<void> restore() async {
    if (!_configured) return;
    await Purchases.restorePurchases();
  }

  /// Store page where the user cancels or resumes the subscription.
  Future<String?> managementUrl() async {
    if (!_configured) return null;
    return (await Purchases.getCustomerInfo()).managementURL;
  }

  /// Fires on renewals and purchases finished in the background.
  void addCustomerInfoListener(void Function() listener) {
    if (_configured) Purchases.addCustomerInfoUpdateListener((_) => listener());
  }
}

enum PurchaseOutcome { purchased, cancelled, pending }
