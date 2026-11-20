import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../model/cart_item_model.dart';
import '../model/deal_model.dart';
import '../util/log_service.dart';
import 'flash_sale_service.dart';

enum AddToBagResult { added, expired, outOfStock }

/// App-wide cart. Lives for the whole session.
///
/// NOTE: the starter cart is purely local — it does not reserve stock on the
/// backend. See the "Reservations" feature task in PROBLEM.md.
class CartService extends GetxService {
  CartService({required this.flashSales, this.onExpired});

  final FlashSaleService flashSales;
  final void Function(List<DealModel> deals)? onExpired;
  VoidCallback? _stopExpiryWatch;
  final items = <CartItemModel>[].obs;
  final itemCount = 0.obs;

  AddToBagResult add(DealModel deal) {
    removeExpired();
    if (flashSales.isExpired(deal.flashSaleEndsAt)) {
      return AddToBagResult.expired;
    }
    final existing = items.firstWhereOrNull((i) => i.deal.id == deal.id);
    if (deal.quantityLeft <= 0) return AddToBagResult.outOfStock;
    if (existing != null) {
      if (existing.quantity >= deal.quantityLeft) {
        LogService.log('cart: cannot add more of deal ${deal.id}');
        return AddToBagResult.outOfStock;
      }
      existing.quantity++;
      items.refresh();
    } else {
      items.add(CartItemModel(deal: deal));
    }
    _recount();
    _syncExpiryWatch();
    return AddToBagResult.added;
  }

  void decrement(int dealId) {
    final existing = items.firstWhereOrNull((i) => i.deal.id == dealId);
    if (existing == null) return;
    existing.quantity--;
    if (existing.quantity <= 0) {
      items.removeWhere((i) => i.deal.id == dealId);
    } else {
      items.refresh();
    }
    _recount();
    _syncExpiryWatch();
  }

  void remove(int dealId) {
    items.removeWhere((i) => i.deal.id == dealId);
    _recount();
    _syncExpiryWatch();
  }

  void clear() {
    items.clear();
    _recount();
    _syncExpiryWatch();
  }

  /// Runs even when no deal widget is mounted. Returns removed line count.
  int removeExpired() {
    final expired = items
        .where((item) => flashSales.isExpired(item.deal.flashSaleEndsAt))
        .map((item) => item.deal)
        .toList();
    if (expired.isEmpty) return 0;
    final ids = expired.map((deal) => deal.id).toSet();
    items.removeWhere((item) => ids.contains(item.deal.id));
    _recount();
    _syncExpiryWatch();
    if (onExpired != null) {
      onExpired!(expired);
    } else {
      Get.snackbar(
        'Flash sale expired',
        expired.length == 1
            ? '${expired.single.name} expired and was removed from your bag.'
            : '${expired.length} expired deals were removed from your bag.',
        snackPosition: SnackPosition.BOTTOM,
      );
    }
    return expired.length;
  }

  void _syncExpiryWatch() {
    _stopExpiryWatch?.call();
    _stopExpiryWatch = null;
    DateTime? next;
    for (final item in items) {
      final deadline = item.deal.flashSaleEndsAt;
      if (deadline != null && (next == null || deadline.isBefore(next))) {
        next = deadline;
      }
    }
    if (next != null) {
      _stopExpiryWatch = flashSales.watch(next, removeExpired);
    }
  }

  @override
  void onClose() {
    _stopExpiryWatch?.call();
    super.onClose();
  }

  num get total => items.fold(0, (sum, i) => sum + i.lineTotal);

  void _recount() {
    itemCount.value = items.fold(0, (sum, i) => sum + i.quantity);
  }
}
