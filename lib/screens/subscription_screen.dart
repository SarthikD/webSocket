import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/subscription.dart';
import '../services/purchases_service.dart';
import '../services/subscription_controller.dart';
import 'format.dart';

/// Subscription Plan screen. State comes from the backend through
/// [SubscriptionController]; the store handles payment, cancel and resume.
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  final _controller = SubscriptionController.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller.load();
  }

  /// Runs [action] with the buttons disabled and reports errors.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _upgrade() async {
    switch (await _controller.buyPremium()) {
      case PurchaseOutcome.purchased:
        if (_controller.state.isPremium) _toast('Premium is active');
      case PurchaseOutcome.pending:
        _toast('Payment pending. Premium unlocks when the store confirms it.');
      case PurchaseOutcome.cancelled:
        break;
    }
  }

  Future<void> _restore() async {
    await _controller.restore();
    _toast(_controller.state.isPremium ? 'Premium restored' : 'No purchases to restore');
  }

  Future<void> _openStore() async {
    final uri = await _controller.storeManagementUri();
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _controller.cancelStoreReturn();
      _toast('Could not open the store');
    }
  }

  Future<void> _confirmCancel() async {
    final sub = _controller.state.subscription;
    final until = sub?.renewsAt ?? sub?.cancelsAt;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: CircleAvatar(
          backgroundColor: Colors.red.shade50,
          child: Icon(Icons.close, color: Colors.red.shade700),
        ),
        title: const Text('Cancel Premium?'),
        content: Text(
          "You'll keep Premium features until ${until == null ? 'the end of this period' : mdy(until)}, "
          'then your account moves to Free.',
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep Premium'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel Premium'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _openStore();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Subscription Plan')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final c = _controller;
          if (c.loading && c.plans.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          final state = c.state;
          final sub = state.subscription;
          return RefreshIndicator(
            onRefresh: c.load,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (c.error != null) _ErrorCard(message: c.error!, onRetry: c.load),
                if (sub?.status == SubscriptionInfo.billingIssue)
                  _BillingIssueBanner(onTap: _busy ? null : () => _run(_openStore)),
                if (c.premiumPlan != null)
                  _PremiumCard(plan: c.premiumPlan!, state: state, storePrice: c.storePrice),
                if (c.freePlan != null) _FreeCard(plan: c.freePlan!, isCurrent: !state.isPremium),
                const SizedBox(height: 8),
                if (c.canPurchase) ...[
                  _bottomButton(state),
                  TextButton(
                    onPressed: _busy ? null : () => _run(_restore),
                    child: const Text('Restore purchases'),
                  ),
                ] else
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      c.purchasesUnavailableReason ?? 'In-app purchases are not available.',
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Button per backend state: Free or EXPIRED, ACTIVE, CANCELLED, BILLING_ISSUE.
  Widget _bottomButton(SubscriptionState state) {
    final status = state.status;
    final Widget button;
    if (!state.isPremium || status == SubscriptionInfo.expired) {
      button = FilledButton(
        onPressed: _busy ? null : () => _run(_upgrade),
        child: const Text('Upgrade to Premium'),
      );
    } else if (status == SubscriptionInfo.cancelled) {
      button = FilledButton(
        style: FilledButton.styleFrom(backgroundColor: Colors.deepPurple),
        onPressed: _busy ? null : () => _run(_openStore),
        child: const Text('Resume subscription'),
      );
    } else if (status == SubscriptionInfo.billingIssue) {
      button = FilledButton(
        onPressed: _busy ? null : () => _run(_openStore),
        child: const Text('Update payment'),
      );
    } else {
      button = OutlinedButton(
        onPressed: _busy ? null : () => _run(_confirmCancel),
        child: const Text('Cancel subscription'),
      );
    }
    return SizedBox(height: 48, width: double.infinity, child: button);
  }
}

class _PremiumCard extends StatelessWidget {
  const _PremiumCard({required this.plan, required this.state, this.storePrice});

  final Plan plan;
  final SubscriptionState state;
  final String? storePrice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = state.subscription;
    final price = storePrice ?? _backendPrice(plan);
    final Widget? badge;
    if (sub?.status == SubscriptionInfo.cancelled && sub?.cancelsAt != null) {
      badge = _Badge(
        'Cancels on ${mdy(sub!.cancelsAt!)}',
        background: Colors.amber.shade100,
        foreground: Colors.brown.shade800,
      );
    } else if (state.isPremium && sub?.willRenew == true) {
      badge = const _Badge('Active Plan');
    } else {
      badge = null;
    }
    final showPeriod = state.isPremium && sub != null && sub.status != SubscriptionInfo.expired;

    return _PlanCard(
      highlighted: state.isPremium,
      title: plan.name,
      price: '$price / ${plan.interval}',
      badge: badge,
      features: plan.features,
      children: [
        if (showPeriod && sub.daysRemaining != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  sub.renewsAt == null
                      ? 'Remaining Days'
                      : 'Remaining Days (Renews on ${mdy(sub.renewsAt!)})',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              Text('${sub.daysRemaining}', style: theme.textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: sub.progress ?? 0, minHeight: 6),
          ),
        ],
      ],
    );
  }
}

class _FreeCard extends StatelessWidget {
  const _FreeCard({required this.plan, required this.isCurrent});

  final Plan plan;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) => _PlanCard(
        highlighted: isCurrent,
        title: plan.name,
        price: plan.priceAmount == 0 ? 'Free' : '${_backendPrice(plan)} / ${plan.interval}',
        badge: isCurrent ? const _Badge('Active Plan') : null,
        features: plan.features,
      );
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.highlighted,
    required this.title,
    required this.price,
    required this.features,
    this.badge,
    this.children = const [],
  });

  final bool highlighted;
  final String title;
  final String price;
  final Widget? badge;
  final List<PlanFeature> features;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: highlighted
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide(color: theme.dividerColor),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: theme.textTheme.titleLarge)),
                ?badge,
              ],
            ),
            Text(price, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final f in features)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Icon(_featureIcon(f.key), size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(f.label)),
                  ],
                ),
              ),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.background, this.foreground});

  final String text;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background ?? scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: foreground ?? scheme.onPrimaryContainer),
      ),
    );
  }
}

class _BillingIssueBanner extends StatelessWidget {
  const _BillingIssueBanner({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
        color: Colors.orange.shade50,
        child: ListTile(
          leading: Icon(Icons.warning_amber, color: Colors.orange.shade800),
          title: const Text('Payment problem'),
          subtitle: const Text('Update your payment method to keep Premium.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: Text(message),
          trailing: IconButton(tooltip: 'Retry', icon: const Icon(Icons.refresh), onPressed: onRetry),
        ),
      );
}

String _backendPrice(Plan plan) =>
    plan.currency == 'USD' ? '\$${plan.priceAmount}' : '${plan.currency} ${plan.priceAmount}';

IconData _featureIcon(String key) {
  final k = key.toUpperCase();
  if (k.contains('CONTACT')) return Icons.group;
  if (k.contains('VIDEO') || k.contains('STREAM')) return Icons.videocam;
  if (k.contains('CLOUD') || k.contains('RECORD') || k.contains('STORAGE')) return Icons.cloud_upload;
  if (k.contains('GPS') || k.contains('LOCATION')) return Icons.location_on;
  if (k.contains('EVIDENCE') || k.contains('VAULT')) return Icons.lock;
  if (k.contains('AUTOMATION')) return Icons.auto_mode;
  if (k.contains('PANIC') || k.contains('SOS')) return Icons.sos;
  return Icons.check_circle;
}
