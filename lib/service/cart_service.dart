import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../model/cart_item_model.dart';
import '../model/deal_model.dart';
import '../model/reservation_model.dart';
import '../repository/order_repo.dart';
import '../util/log_service.dart';
import 'api_exception.dart';
import 'flash_sale_service.dart';

enum AddToBagResult { added, expired, outOfStock, checkoutInProgress }

/// Session-wide owner of optimistic additions, holds and checkout ownership.
class CartService extends GetxService {
  CartService({
    required this.flashSales,
    required this.orderRepo,
    this.onExpired,
    this.onNotice,
  });

  final FlashSaleService flashSales;
  final OrderRepo orderRepo;
  final void Function(List<DealModel> deals)? onExpired;
  final void Function(String title, String message)? onNotice;
  final items = <CartItemModel>[].obs;
  final itemCount = 0.obs;
  final isCheckingOut = false.obs;
  List<CartItemModel> _submitted = const [];
  final _deferredReleases = <String, ReservationModel>{};
  final _releases = <String, _ReleaseTask>{};
  VoidCallback? _stopExpiryWatch;
  bool _disposed = false;

  bool get hasPending => items.any((item) => item.pendingCount > 0);
  bool get canCheckout =>
      !isCheckingOut.value && items.isNotEmpty && !hasPending;
  num get total => items.fold(0, (sum, item) => sum + item.lineTotal);

  AddToBagResult add(DealModel deal) {
    if (_disposed || isCheckingOut.value) {
      return AddToBagResult.checkoutInProgress;
    }
    removeExpired();
    if (flashSales.isExpired(deal.flashSaleEndsAt)) {
      return AddToBagResult.expired;
    }
    final existing = _line(deal.id);
    if (deal.quantityLeft <= (existing?.quantity ?? 0)) {
      return AddToBagResult.outOfStock;
    }
    final unit = CartUnitModel(token: Object());
    _replace(deal, [...?existing?.units, unit]);
    _changed();
    unawaited(_reserve(deal, unit.token));
    return AddToBagResult.added;
  }

  Future<void> _reserve(DealModel deal, Object token) async {
    try {
      final hold = await orderRepo.reserve(deal.id);
      if (hold.id.isEmpty || hold.dealId != deal.id || hold.quantity != 1) {
        if (hold.id.isNotEmpty) _release(hold);
        throw const FormatException('Invalid reservation response');
      }
      if (!_disposed) removeExpired();
      final line = _line(deal.id);
      if (_disposed ||
          line == null ||
          !line.units.any((unit) => identical(unit.token, token))) {
        _release(hold);
        return;
      }
      if (hold.isExpiredAt(flashSales.now())) {
        _dropUnit(line, token);
        _release(hold);
        _changed();
        _notice('Hold expired',
            'The hold for ${deal.name} has ended. Add it again to try for another.');
        return;
      }
      _replace(line.deal, [
        for (final unit in line.units)
          if (identical(unit.token, token))
            CartUnitModel(token: token, reservation: hold)
          else
            unit,
      ]);
      _changed();
    } catch (error) {
      LogService.log('reserve deal ${deal.id} failed: $error');
      if (_disposed) return;
      final line = _line(deal.id);
      if (line == null ||
          !line.units.any((unit) => identical(unit.token, token))) {
        return;
      }
      _dropUnit(line, token);
      _changed();
      _notice(
          'Couldn’t hold this bag',
          error is ApiException && error.statusCode == 409
              ? '${deal.name} is no longer available in that quantity. Your bag was updated.'
              : 'We couldn’t hold ${deal.name}. Please try adding it again.');
    }
  }

  void decrement(int dealId) {
    if (_disposed || isCheckingOut.value) return;
    removeExpired();
    final line = _line(dealId);
    if (line == null) return;
    // Cancel optimistic intent first; otherwise keep the longer-lived holds.
    final pending = line.units.firstWhereOrNull((u) => u.reservation == null);
    final unit = pending ??
        (line.units.toList()
              ..sort((a, b) =>
                  a.reservation!.expiresAt.compareTo(b.reservation!.expiresAt)))
            .first;
    _dropUnit(line, unit.token);
    if (unit.reservation != null) _release(unit.reservation!);
    _changed();
  }

  void remove(int dealId) {
    if (_disposed || isCheckingOut.value) return;
    final line = _line(dealId);
    if (line == null) return;
    _replace(line.deal, const []);
    _releaseUnits(line.units);
    _changed();
  }

  void clear() {
    if (_disposed || isCheckingOut.value) return;
    final previous = items.toList();
    items.clear();
    for (final line in previous) {
      _releaseUnits(line.units);
    }
    _changed();
  }

  /// Returns changed line count so checkout can stop for review of a new total.
  int removeExpired() {
    if (_disposed) return 0;
    final flashExpired = <DealModel>[];
    var expiredUnits = 0;
    var changedLines = 0;
    for (final line in items.toList()) {
      if (flashSales.isExpired(line.deal.flashSaleEndsAt)) {
        flashExpired.add(line.deal);
        _replace(line.deal, const []);
        _releaseUnits(line.units);
        changedLines++;
      } else {
        final expired = line.units
            .where((unit) =>
                unit.reservation?.isExpiredAt(flashSales.now()) ?? false)
            .toList();
        if (expired.isEmpty) continue;
        final tokens = expired.map((unit) => unit.token).toSet();
        _replace(line.deal,
            line.units.where((unit) => !tokens.contains(unit.token)));
        _releaseUnits(expired);
        expiredUnits += expired.length;
        changedLines++;
      }
    }
    if (changedLines == 0) return 0;
    _changed();
    if (flashExpired.isNotEmpty) {
      if (onExpired != null) {
        onExpired!(flashExpired);
      } else {
        _notice(
            'Flash sale expired',
            flashExpired.length == 1
                ? '${flashExpired.single.name} expired and was removed from your bag.'
                : '${flashExpired.length} expired deals were removed from your bag.');
      }
    }
    if (expiredUnits > 0) {
      _notice(
          'Hold expired',
          isCheckingOut.value
              ? 'Your hold time ended while checkout was processing. Please wait for the result.'
              : '$expiredUnits ${expiredUnits == 1 ? 'bag was' : 'bags were'} removed because the hold ended. Add again to reserve.');
    }
    return changedLines;
  }

  /// Locks mutations across every route, not just the mounted cart controller.
  List<CartItemModel>? beginCheckout() {
    if (_disposed || isCheckingOut.value) return null;
    if (removeExpired() > 0 || !canCheckout) return null;
    _submitted = List.unmodifiable(items);
    isCheckingOut.value = true;
    return _submitted;
  }

  /// A submitted hold must not be released while the server may still use it.
  /// A 410 lacks an offending ID, so invalidate the complete submitted set.
  void finishCheckout({bool purchased = false, bool invalidate = false}) {
    if (!isCheckingOut.value) return;
    if (purchased || invalidate) {
      for (final submitted in _submitted) {
        final line = _line(submitted.deal.id);
        final tokens = submitted.units.map((unit) => unit.token).toSet();
        if (line != null) {
          _replace(line.deal,
              line.units.where((unit) => !tokens.contains(unit.token)));
        }
        _releaseUnits(submitted.units);
      }
    }
    _submitted = const [];
    final deferred = _deferredReleases.values.toList();
    _deferredReleases.clear();
    for (final hold in deferred) {
      _release(hold);
    }
    removeExpired();
    _changed();
    isCheckingOut.value = false;
  }

  CartItemModel? _line(int id) =>
      items.firstWhereOrNull((line) => line.deal.id == id);

  void _dropUnit(CartItemModel line, Object token) => _replace(
      line.deal, line.units.where((unit) => !identical(unit.token, token)));

  void _replace(DealModel deal, Iterable<CartUnitModel> units) {
    final replacement = CartItemModel(deal: deal, units: units);
    final index = items.indexWhere((line) => line.deal.id == deal.id);
    if (replacement.units.isEmpty) {
      if (index >= 0) items.removeAt(index);
    } else if (index < 0) {
      items.add(replacement);
    } else {
      items[index] = replacement;
    }
  }

  void _releaseUnits(Iterable<CartUnitModel> units) {
    for (final unit in units) {
      final hold = unit.reservation;
      if (hold != null) _release(hold);
    }
  }

  void _release(ReservationModel hold) {
    if (_submitted.any(
        (line) => line.units.any((unit) => unit.reservation?.id == hold.id))) {
      _deferredReleases[hold.id] = hold;
      return;
    }
    final task = _releases.putIfAbsent(hold.id, () => _ReleaseTask(hold));
    if (!task.inFlight) unawaited(_attemptRelease(task));
  }

  Future<void> _attemptRelease(_ReleaseTask task) async {
    task.inFlight = true;
    task.attempts++;
    try {
      await orderRepo.releaseReservation(task.hold.id);
      _releases.remove(task.hold.id);
    } catch (error) {
      LogService.log('release ${task.hold.id} failed: $error');
      if (_disposed ||
          task.attempts >= 3 ||
          task.hold.isExpiredAt(flashSales.now())) {
        _releases.remove(task.hold.id);
      } else {
        task.retryAt = flashSales.now().add(Duration(seconds: task.attempts));
      }
    } finally {
      task.inFlight = false;
      _syncExpiryWatch();
    }
  }

  void _tick() {
    removeExpired();
    for (final task in _releases.values.toList()) {
      if (task.inFlight) continue;
      if (task.hold.isExpiredAt(flashSales.now())) {
        _releases.remove(task.hold.id);
      } else if (task.retryAt != null &&
          !flashSales.now().isBefore(task.retryAt!)) {
        unawaited(_attemptRelease(task));
      }
    }
    _syncExpiryWatch();
  }

  void _changed() {
    itemCount.value = items.fold(0, (sum, item) => sum + item.quantity);
    _syncExpiryWatch();
  }

  void _syncExpiryWatch() {
    _stopExpiryWatch?.call();
    _stopExpiryWatch = null;
    if (_disposed) return;
    DateTime? next;
    void consider(DateTime? deadline) {
      if (deadline != null && (next == null || deadline.isBefore(next!))) {
        next = deadline;
      }
    }

    for (final line in items) {
      consider(line.deal.flashSaleEndsAt);
      consider(line.nextExpiry);
    }
    for (final task in _releases.values) {
      if (!task.inFlight) {
        consider(task.retryAt);
        consider(task.hold.expiresAt);
      }
    }
    if (next != null) _stopExpiryWatch = flashSales.watch(next!, _tick);
  }

  void _notice(String title, String message) {
    if (_disposed) return;
    if (onNotice != null) {
      onNotice!(title, message);
    } else {
      Get.snackbar(title, message, snackPosition: SnackPosition.BOTTOM);
    }
  }

  @override
  void onClose() {
    if (_disposed) return;
    _disposed = true;
    _stopExpiryWatch?.call();
    for (final line in items) {
      _releaseUnits(line.units);
    }
    super.onClose();
  }
}

class _ReleaseTask {
  _ReleaseTask(this.hold);

  final ReservationModel hold;
  int attempts = 0;
  bool inFlight = false;
  DateTime? retryAt;
}
