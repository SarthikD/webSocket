/// A plan card from `GET /subscription/plans`.
class Plan {
  Plan({
    required this.id,
    required this.code,
    required this.name,
    required this.priceAmount,
    required this.currency,
    required this.interval,
    required this.features,
    this.circleContactLimit,
    this.appleProductId,
    this.googleProductId,
  });

  factory Plan.fromJson(Map<String, dynamic> json) {
    final price = _map(json['price']);
    return Plan(
      id: json['id']?.toString() ?? '',
      code: json['code']?.toString() ?? json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      priceAmount: (price['amount'] as num?)?.toDouble() ?? 0,
      currency: price['currency']?.toString() ?? 'USD',
      interval: (json['interval'] ?? price['interval'])?.toString() ?? 'month',
      features: (json['features'] as List? ?? const [])
          .map((f) => f is Map ? PlanFeature.fromJson(_map(f)) : PlanFeature(key: '', label: f.toString()))
          .toList(),
      circleContactLimit: (json['circleContactLimit'] as num?)?.toInt(),
      appleProductId: json['appleProductId']?.toString(),
      googleProductId: json['googleProductId']?.toString(),
    );
  }

  final String id;

  /// `FREE` or `PREMIUM`.
  final String code;
  final String name;
  final double priceAmount;
  final String currency;
  final String interval;
  final List<PlanFeature> features;

  /// `null` means unlimited.
  final int? circleContactLimit;
  final String? appleProductId;
  final String? googleProductId;

  bool get isFree => code == 'FREE';
}

class PlanFeature {
  PlanFeature({required this.key, required this.label});

  factory PlanFeature.fromJson(Map<String, dynamic> json) =>
      PlanFeature(key: json['key']?.toString() ?? '', label: json['label']?.toString() ?? '');

  /// For example `UNLIMITED_TRUSTED_CONTACTS`; mapped to an icon by the UI.
  final String key;
  final String label;
}

/// Screen state from `GET /subscription` and `POST /subscription/sync`.
class SubscriptionState {
  SubscriptionState({
    required this.currentPlan,
    required this.isPremium,
    this.circleContactLimit,
    this.subscription,
  });

  factory SubscriptionState.fromJson(Map<String, dynamic> json) {
    final sub = json['subscription'];
    return SubscriptionState(
      currentPlan: json['currentPlan']?.toString() ?? 'FREE',
      isPremium: json['isPremium'] == true,
      circleContactLimit: (_map(json['limits'])['circleContacts'] as num?)?.toInt(),
      subscription: sub is Map ? SubscriptionInfo.fromJson(_map(sub)) : null,
    );
  }

  static final free = SubscriptionState(currentPlan: 'FREE', isPremium: false, circleContactLimit: 1);

  final String currentPlan;
  final bool isPremium;

  /// `null` means unlimited.
  final int? circleContactLimit;
  final SubscriptionInfo? subscription;

  String? get status => subscription?.status;
}

class SubscriptionInfo {
  SubscriptionInfo({
    required this.status,
    required this.willRenew,
    this.renewsAt,
    this.cancelsAt,
    this.daysRemaining,
    this.periodDays,
    this.price,
    this.managementUrl,
    this.productId,
  });

  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) => SubscriptionInfo(
        status: json['status']?.toString() ?? '',
        willRenew: json['willRenew'] == true,
        renewsAt: _date(json['renewsAt']),
        cancelsAt: _date(json['cancelsAt']),
        daysRemaining: (json['daysRemaining'] as num?)?.toInt(),
        periodDays: (json['periodDays'] as num?)?.toInt(),
        price: json['price'],
        managementUrl: json['managementUrl']?.toString(),
        productId: json['productId']?.toString(),
      );

  static const active = 'ACTIVE';
  static const cancelled = 'CANCELLED';
  static const billingIssue = 'BILLING_ISSUE';
  static const expired = 'EXPIRED';

  /// `ACTIVE`, `CANCELLED`, `BILLING_ISSUE` or `EXPIRED`.
  final String status;
  final bool willRenew;

  /// Null when cancelled.
  final DateTime? renewsAt;
  final DateTime? cancelsAt;
  final int? daysRemaining;
  final int? periodDays;

  /// Raw backend value; the UI shows the store price instead.
  final Object? price;
  final String? managementUrl;
  final String? productId;

  /// Share of the billing period already used, 0..1.
  double? get progress {
    final left = daysRemaining;
    final total = periodDays;
    if (left == null || total == null || total <= 0) return null;
    return (1 - left / total).clamp(0.0, 1.0);
  }
}

Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

DateTime? _date(dynamic value) =>
    value == null ? null : DateTime.tryParse(value.toString())?.toLocal();
