import 'package:flutter/material.dart';
import 'package:purchases_flutter/purchases_flutter.dart' show StoreProduct;

import '../core/api_client.dart';
import '../core/session.dart';
import '../services/purchases_service.dart';

/// Donate screen. Amounts come from `GET /donations/options`; the store takes
/// the payment and `POST /donations/sync` records it on the backend.
class DonateScreen extends StatefulWidget {
  const DonateScreen({super.key});

  @override
  State<DonateScreen> createState() => _DonateScreenState();
}

class _DonateScreenState extends State<DonateScreen> {
  final _api = ApiClient.instance;
  final _purchases = PurchasesService.instance;

  List<_Option> _options = const [];
  _Option? _selected;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final items = await _api.donationOptions();
      final ids = [for (final o in items) o['productId'] as String];
      var products = const <StoreProduct>[];
      try {
        products = await _purchases.consumables(ids);
      } catch (e) {
        debugPrint('getProducts failed: $e');
      }
      final byId = {for (final p in products) p.identifier: p};
      _options = [
        for (final o in items)
          _Option(
            productId: o['productId'] as String,
            amount: o['amount'] as num,
            product: byId[o['productId']],
          ),
      ];
      if (_options.isEmpty) _error = 'GET /donations/options returned no items';
      if (products.isEmpty && _purchases.isAvailable && _options.isNotEmpty) {
        _error = 'Store returned no products for $ids';
      }
    } catch (e) {
      _error = 'Could not load donation options: $e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _donate() async {
    final option = _selected;
    final product = option?.product;
    final userId = Session.instance.userId;
    if (_busy || option == null || product == null) return;
    if (userId == null) return _toast('Not logged in');

    setState(() => _busy = true);
    try {
      final txId = await _purchases.purchaseConsumable(product, userId: userId);
      if (txId == null) return; // Cancelled: no API call.
      debugPrint('donation transactionId: $txId');

      final donation = await _syncWithRetry(txId);
      if (donation == null) {
        _toast('Payment done, but the backend does not see it yet. '
            'transactionId: $txId');
        return;
      }
      if (mounted) await _showThankYou(donation['amount'] as num? ?? option.amount);
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// RevenueCat can lag a moment behind the store, so retry a `null` result.
  Future<Map<String, dynamic>?> _syncWithRetry(String txId) async {
    for (var attempt = 1;; attempt++) {
      final donation = await _api.syncDonation(txId);
      if (donation != null || attempt >= 3) return donation;
      await Future<void>.delayed(Duration(seconds: 2 * attempt));
    }
  }

  Future<void> _showThankYou(num amount) => showModalBottomSheet<void>(
        context: context,
        builder: (context) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.favorite, size: 48, color: Colors.pink.shade400),
              const SizedBox(height: 12),
              Text('Thank you!', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'Your ${_usd(amount)} donation helps keep Haven running.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Donate')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Card(
                      color: theme.colorScheme.errorContainer,
                      child: ListTile(
                        leading: const Icon(Icons.error_outline),
                        title: Text(_error!),
                        trailing: IconButton(
                          tooltip: 'Retry',
                          icon: const Icon(Icons.refresh),
                          onPressed: _load,
                        ),
                      ),
                    ),
                  Text('Choose an amount', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final o in _options)
                        ChoiceChip(
                          label: Text(_usd(o.amount)),
                          tooltip: o.product?.priceString ?? '${o.productId} not in store',
                          selected: _selected == o,
                          onSelected: _busy || o.product == null
                              ? null
                              : (_) => setState(() => _selected = o),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  if (_purchases.isAvailable)
                    SizedBox(
                      height: 48,
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy || _selected == null ? null : _donate,
                        child: _busy
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(_selected == null
                                ? 'Donate Now'
                                : 'Donate Now (${_selected!.product?.priceString ?? _usd(_selected!.amount)})'),
                      ),
                    )
                  else
                    Text(
                      _purchases.unavailableReason ?? 'In-app purchases are not available.',
                      textAlign: TextAlign.center,
                    ),
                ],
              ),
            ),
    );
  }
}

class _Option {
  const _Option({required this.productId, required this.amount, this.product});

  final String productId;
  final num amount;
  final StoreProduct? product;
}

String _usd(num amount) =>
    '\$${amount == amount.roundToDouble() ? amount.toInt() : amount.toStringAsFixed(2)}';
