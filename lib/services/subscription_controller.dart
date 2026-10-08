import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:purchases_flutter/purchases_flutter.dart' show Package;

import '../config.dart';
import '../core/api_client.dart';
import '../core/session.dart';
import '../models/subscription.dart';
import '../screens/format.dart';
import 'purchases_service.dart';

/// App-wide subscription state. The backend is the source of truth; the
/// RevenueCat SDK is only used to buy, restore and find the store page.
class SubscriptionController extends ChangeNotifier {
  SubscriptionController._();
  static final SubscriptionController instance = SubscriptionController._();

  static const _resumeSyncInterval = Duration(minutes: 5);

  final _api = ApiClient.instance;
  final _purchases = PurchasesService.instance;

  SubscriptionState? _state;
  List<Plan> _plans = const [];
  Package? _monthly;
  bool _loading = false;
  String? _error;
  DateTime? _lastSync;
  Timer? _debounce;
  bool _awaitingStoreReturn = false;

  /// Shows a short message to the user (set by the app to a snackbar).
  ValueChanged<String>? onNotice;

  SubscriptionState get state => _state ?? SubscriptionState.free;
  bool get hasState => _state != null;
  List<Plan> get plans => _plans;
  bool get loading => _loading;
  String? get error => _error;
  bool get canPurchase => _purchases.isAvailable;
  String? get purchasesUnavailableReason => _purchases.unavailableReason;

  Plan? get premiumPlan => _plans.where((p) => !p.isFree).firstOrNull;
  Plan? get freePlan => _plans.where((p) => p.isFree).firstOrNull;

  /// Localized store price, for example "$0.99". Null when the store has no
  /// offering; the UI then shows the backend price.
  String? get storePrice => _monthly?.storeProduct.priceString;

  /// Call once after the SDK is configured.
  void init() {
    _purchases.addCustomerInfoListener(() {
      if (!Session.instance.isLoggedIn) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 2), () => sync().catchError((_) => state));
    });
  }

  /// Loads plans, state and the store package. Used when the screen opens.
  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final results = await Future.wait<Object?>([
        _api.subscriptionPlans(),
        _api.subscription(),
        _purchases.monthlyPackage().catchError((Object e) {
          debugPrint('getOfferings failed: $e');
          return null;
        }),
      ]);
      _plans = results[0] as List<Plan>;
      _state = results[1] as SubscriptionState;
      _monthly = results[2] as Package?;
      if (_plans.isEmpty) _error = 'GET /subscription/plans returned no plans';
    } catch (e) {
      debugPrint('subscription load failed: $e');
      _error = 'Could not load subscription: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// `POST /subscription/sync`. Retries network errors a few times; the
  /// webhook also updates the backend within seconds.
  Future<SubscriptionState> sync([Map<String, dynamic>? plan]) async {
    for (var attempt = 1;; attempt++) {
      try {
        _state = await _api.syncSubscription(plan);
        _lastSync = DateTime.now();
        _error = null;
        notifyListeners();
        return _state!;
      } on ApiException {
        rethrow;
      } catch (e) {
        if (attempt >= 3) rethrow;
        debugPrint('sync failed ($e), retry $attempt');
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
    }
  }

  /// After our login: tie the RevenueCat user to our user, then sync.
  Future<void> onLogin(String userId) async {
    await _purchases.logIn(userId);
    try {
      await sync();
    } catch (e) {
      debugPrint('sync after login failed: $e');
    }
  }

  /// Before our logout clears the tokens.
  Future<void> onLogout() async {
    _debounce?.cancel();
    _state = null;
    _lastSync = null;
    _awaitingStoreReturn = false;
    notifyListeners();
    await _purchases.logOut();
  }

  /// App came to the foreground. Forced sync after the store page, else at
  /// most once per [_resumeSyncInterval].
  Future<void> onResume() async {
    if (!Session.instance.isLoggedIn) return;
    if (_awaitingStoreReturn) {
      _awaitingStoreReturn = false;
      final before = _state?.subscription;
      try {
        final after = (await sync()).subscription;
        if (before?.willRenew == true && after?.status == SubscriptionInfo.cancelled) {
          final until = after?.cancelsAt;
          onNotice?.call('Subscription cancelled. Premium features stay active'
              '${until == null ? '' : ' until ${mdy(until)}'}.');
        } else if (before?.status == SubscriptionInfo.cancelled && after?.willRenew == true) {
          onNotice?.call('Subscription resumed.');
        }
      } catch (e) {
        debugPrint('sync after store return failed: $e');
      }
      return;
    }
    final last = _lastSync;
    if (last != null && DateTime.now().difference(last) < _resumeSyncInterval) return;
    try {
      await sync();
    } catch (e) {
      debugPrint('resume sync failed: $e');
    }
  }

  /// Buys the monthly package. The UI unlocks Premium only from the synced
  /// backend state, never from the SDK result alone.
  Future<PurchaseOutcome> buyPremium() async {
    final package = _monthly ?? await _purchases.monthlyPackage();
    if (package == null) throw Exception('Premium is not available in the store right now');
    final userId = Session.instance.userId;
    if (userId == null) throw Exception('Not logged in');

    final outcome = await _purchases.purchase(package, userId: userId);
    if (outcome != PurchaseOutcome.purchased) return outcome;

    final product = package.storeProduct;
    final plan = premiumPlan;
    await sync({
      'planId': plan?.id ?? 'PREMIUM',
      'planName': plan?.name ?? 'Premium',
      'price': product.price,
      'currency': product.currencyCode,
      'productId': product.identifier,
    });
    return outcome;
  }

  Future<void> restore() async {
    await _purchases.restore();
    await sync();
  }

  /// Store page where the user cancels, resumes or fixes payment. Sets the
  /// flag that [onResume] uses to sync on return.
  Future<Uri> storeManagementUri() async {
    final sub = _state?.subscription;
    var url = sub?.managementUrl ?? await _purchases.managementUrl();
    if (url == null) {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        url = 'https://apps.apple.com/account/subscriptions';
      } else {
        final sku = sub?.productId ?? premiumPlan?.googleProductId;
        url = 'https://play.google.com/store/account/subscriptions'
            '?package=$kAndroidPackageId${sku == null ? '' : '&sku=$sku'}';
      }
    }
    _awaitingStoreReturn = true;
    return Uri.parse(url);
  }

  /// Opening the store page failed; do not sync on the next resume.
  void cancelStoreReturn() => _awaitingStoreReturn = false;
}
