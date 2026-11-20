import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/cart/cart_controller.dart';
import 'package:rescu/feature/cart/cart_screen.dart';
import 'package:rescu/model/cart_item_model.dart';
import 'package:rescu/model/reservation_model.dart';
import 'package:rescu/repository/order_repo.dart';
import 'package:rescu/service/api_exception.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/flash_sale_service.dart';

import 'support/deal_fixture.dart';

class _Api extends FakeApiService {
  final reserves = <({
    int dealId,
    int quantity,
    Completer<Map<String, dynamic>> response
  })>[];
  final releases = <String>[];
  final checkouts = <List<Map<String, dynamic>>>[];
  final responses = <Completer<Map<String, dynamic>>>[];
  int releaseFailures = 0;

  @override
  Future<Map<String, dynamic>> reserveDeal(int dealId, {int quantity = 1}) {
    final response = Completer<Map<String, dynamic>>();
    reserves.add((dealId: dealId, quantity: quantity, response: response));
    return response.future;
  }

  @override
  Future<void> releaseReservation(String reservationId) async {
    releases.add(reservationId);
    if (releaseFailures > 0) {
      releaseFailures--;
      throw const ApiException('Offline');
    }
  }

  @override
  Future<Map<String, dynamic>> checkout(List<Map<String, dynamic>> items) {
    checkouts.add(items);
    final response = Completer<Map<String, dynamic>>();
    responses.add(response);
    return response.future;
  }
}

class _Harness {
  _Harness(this.tester) {
    clock = Get.put(FlashSaleService(now: tester.binding.clock.now));
    repo = OrderRepo(api: api);
    cart = Get.put(CartService(
      flashSales: clock,
      orderRepo: repo,
      onNotice: (title, message) => notices.add((title, message)),
      onExpired: (deals) => flashExpiries.addAll(deals.map((deal) => deal.id)),
    ));
    controller = Get.put(CartController(cartService: cart, orderRepo: repo));
    _activeHarnesses.add(this);
  }

  final WidgetTester tester;
  final api = _Api();
  final notices = <(String, String)>[];
  final flashExpiries = <int>[];
  late final FlashSaleService clock;
  late final OrderRepo repo;
  late final CartService cart;
  late final CartController controller;

  Future<void> confirm(int index,
      {Duration? lifetime, String? id, int? dealId, int quantity = 1}) async {
    api.reserves[index].response.complete({
      'id': id ?? 'hold_$index',
      'dealId': dealId ?? api.reserves[index].dealId,
      'quantity': quantity,
      'expiresAt': clock
          .now()
          .add(lifetime ?? const Duration(minutes: 5))
          .toUtc()
          .toIso8601String(),
    });
    await tester.pump();
  }

  Future<void> screen() =>
      tester.pumpWidget(const GetMaterialApp(home: CartScreen()));

  Map<String, dynamic> get order => {
        'id': 99,
        'pickupStart': '2026-11-20T00:00:00Z',
        'pickupEnd': '2026-11-20T02:30:00Z',
      };

  Future<void> dismiss() async {
    await tester.pump();
    Get.closeAllSnackbars();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  }
}

final _activeHarnesses = <_Harness>[];

// Dispose session services before Flutter verifies that no fake timers remain.
void _reservationTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      debugOnRebuildDirtyWidget = null;
      for (final h in _activeHarnesses) {
        h.cart.onClose();
        h.clock.onClose();
      }
      _activeHarnesses.clear();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      Get.reset();
    }
  });
}

void main() {
  setUp(() => Get.testMode = true);

  _reservationTest(
      'instant add, pending state, confirmation and checkout readiness',
      (tester) async {
    final h = _Harness(tester);
    expect(h.cart.add(dealFixture()), AddToBagResult.added);
    expect(h.cart.itemCount.value, 1);
    expect(h.cart.total, 20);
    expect(h.cart.items.single.pendingCount, 1);
    expect(h.cart.canCheckout, isFalse);
    expect(h.cart.beginCheckout(), isNull);
    expect(h.api.reserves.single.quantity, 1);
    await h.confirm(0);
    expect(h.cart.items.single.pendingCount, 0);
    expect(h.cart.canCheckout, isTrue);
    expect(h.cart.items.single.nextExpiry,
        h.clock.now().add(const Duration(minutes: 5)));
  });

  _reservationTest(
      '409 rolls back only its unit despite out-of-order responses',
      (tester) async {
    final h = _Harness(tester);
    final deal = dealFixture();
    h.cart.add(deal);
    h.cart.add(deal);
    h.cart.add(deal);
    await h.confirm(2);
    await h.confirm(0);
    h.api.reserves[1].response
        .completeError(const ApiException('Stock contention', statusCode: 409));
    await tester.pump();
    expect(h.cart.itemCount.value, 2);
    expect(h.cart.total, 40);
    expect(h.cart.items.single.units.map((u) => u.reservation!.id),
        ['hold_0', 'hold_2']);
    expect(h.notices.single.$1, 'Couldn’t hold this bag');
    expect(h.notices.single.$2, contains('Your bag was updated'));
  });

  _reservationTest(
      'unexpected reservation errors roll back with a plain message',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    h.api.reserves.single.response.completeError(StateError('network failed'));
    await tester.pump();
    expect(h.cart.items, isEmpty);
    expect(h.cart.itemCount.value, 0);
    expect(h.cart.total, 0);
    expect(h.notices.single.$2, contains('try adding it again'));
  });

  _reservationTest(
      'remove and re-add cannot attach the old successful response',
      (tester) async {
    final h = _Harness(tester);
    final deal = dealFixture();
    h.cart.add(deal);
    h.cart.remove(deal.id);
    h.cart.add(deal);
    await h.confirm(0);
    expect(h.api.releases, ['hold_0']);
    expect(h.cart.items.single.pendingCount, 1);
    await h.confirm(1);
    expect(h.cart.items.single.units.single.reservation!.id, 'hold_1');
    expect(h.notices, isEmpty);
  });

  _reservationTest('cancelled failure cannot roll back a replacement addition',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    h.cart.decrement(42);
    h.cart.add(dealFixture());
    h.api.reserves.first.response
        .completeError(const ApiException('No stock', statusCode: 409));
    await tester.pump();
    expect(h.cart.itemCount.value, 1);
    expect(h.notices, isEmpty);
    await h.confirm(1);
    expect(h.cart.canCheckout, isTrue);
  });

  _reservationTest(
      'decrement cancels pending intent before releasing a valid hold',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    await h.confirm(0);
    h.cart.add(dealFixture());
    h.cart.decrement(42);
    expect(h.cart.items.single.units.single.reservation!.id, 'hold_0');
    expect(h.api.releases, isEmpty);
    await h.confirm(1);
    expect(h.api.releases, ['hold_1']);
    h.cart.decrement(42);
    expect(h.cart.items, isEmpty);
    expect(h.api.releases, ['hold_1', 'hold_0']);
  });

  _reservationTest(
      'reducing confirmed quantity releases the earliest hold only',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    h.cart.add(dealFixture());
    await h.confirm(0, lifetime: const Duration(minutes: 3));
    await h.confirm(1);
    h.cart.decrement(42);
    expect(h.api.releases, ['hold_0']);
    expect(h.cart.items.single.units.single.reservation!.id, 'hold_1');
  });

  _reservationTest('clear releases every confirmed and late-arriving hold',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    h.cart.add(dealFixture(id: 43));
    await h.confirm(0);
    h.cart.clear();
    await h.confirm(1);
    expect(h.cart.items, isEmpty);
    expect(h.api.releases, ['hold_0', 'hold_1']);
  });

  _reservationTest(
      'stock limit counts pending units and rejects expired flash deals',
      (tester) async {
    final h = _Harness(tester);
    expect(h.cart.add(dealFixture(quantity: 1)), AddToBagResult.added);
    expect(h.cart.add(dealFixture(quantity: 1)), AddToBagResult.outOfStock);
    expect(h.cart.add(dealFixture(id: 43, quantity: 0)),
        AddToBagResult.outOfStock);
    expect(h.cart.add(dealFixture(id: 44, endsAt: h.clock.now())),
        AddToBagResult.expired);
    expect(h.api.reserves.length, 1);
  });

  _reservationTest(
      'exact expiry removes only expired units and never auto-renews',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    h.cart.add(dealFixture());
    await h.confirm(0, lifetime: const Duration(milliseconds: 1250));
    await h.confirm(1);
    await tester.pump(const Duration(milliseconds: 1249));
    expect(h.cart.itemCount.value, 2);
    await tester.pump(const Duration(milliseconds: 1));
    expect(h.cart.itemCount.value, 1);
    expect(h.cart.total, 20);
    expect(h.cart.items.single.units.single.reservation!.id, 'hold_1');
    expect(h.api.releases, ['hold_0']);
    expect(h.notices.single.$1, 'Hold expired');
    expect(h.api.reserves.length, 2);
  });

  _reservationTest('resume reconciles holds after the app was suspended',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    await h.confirm(0, lifetime: const Duration(seconds: 2));
    h.clock.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 6));
    expect(h.cart.itemCount.value, 1);
    h.clock.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(h.cart.items, isEmpty);
    expect(h.notices.length, 1);
  });

  _reservationTest('flash expiry releases confirmed and late-arriving holds',
      (tester) async {
    final h = _Harness(tester);
    final deal =
        dealFixture(endsAt: h.clock.now().add(const Duration(seconds: 1)));
    h.cart.add(deal);
    h.cart.add(deal);
    await h.confirm(0);
    await tester.pump(const Duration(seconds: 1));
    await h.confirm(1);
    expect(h.cart.items, isEmpty);
    expect(h.api.releases, ['hold_0', 'hold_1']);
    expect(h.flashExpiries, [42]);
  });

  _reservationTest(
      'expired or malformed responses cannot become checkout holds',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    await h.confirm(0, lifetime: Duration.zero);
    expect(h.cart.items, isEmpty);
    h.cart.add(dealFixture());
    await h.confirm(1, dealId: 43);
    expect(h.cart.items, isEmpty);
    expect(h.api.releases, ['hold_0', 'hold_1']);
    expect(h.cart.canCheckout, isFalse);
  });

  _reservationTest(
      'failed release retries are bounded and never restore the item',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    await h.confirm(0);
    h.api.releaseFailures = 10;
    h.cart.remove(42);
    await tester.pump();
    expect(h.api.releases.length, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(h.api.releases.length, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(h.api.releases.length, 3);
    await tester.pump(const Duration(minutes: 1));
    expect(h.api.releases.length, 3);
    expect(h.cart.items, isEmpty);
  });

  _reservationTest(
      'dispose releases a late response without reviving clock work',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    h.cart.onClose();
    h.clock.onClose();
    await h.confirm(0);
    expect(h.api.releases, ['hold_0']);
    expect(h.notices, isEmpty);
  });

  _reservationTest(
      'checkout requires review if preflight removes an expired unit',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    h.cart.add(dealFixture(id: 43));
    await h.confirm(0, lifetime: const Duration(seconds: 1));
    await h.confirm(1);
    h.clock.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 1));
    expect(h.cart.beginCheckout(), isNull);
    expect(h.cart.items.single.deal.id, 43);
    expect(h.cart.isCheckingOut.value, isFalse);
    expect(h.api.checkouts, isEmpty);
    expect(h.cart.beginCheckout(), isNotNull);
    h.cart.finishCheckout();
  });

  _reservationTest(
      'checkout snapshot is immutable and locks every mutation path',
      (tester) async {
    final h = _Harness(tester);
    h.cart.add(dealFixture());
    await h.confirm(0);
    final snapshot = h.cart.beginCheckout()!;
    expect(() => snapshot.clear(), throwsUnsupportedError);
    expect(() => snapshot.single.units.clear(), throwsUnsupportedError);
    expect(h.cart.add(dealFixture(id: 43)), AddToBagResult.checkoutInProgress);
    h.cart.decrement(42);
    h.cart.remove(42);
    h.cart.clear();
    expect(h.cart.itemCount.value, 1);
    expect(h.cart.beginCheckout(), isNull);
    h.cart.finishCheckout();
    expect(h.cart.canCheckout, isTrue);
  });

  _reservationTest('checkout flattens unit holds with matching non-null IDs',
      (tester) async {
    final h = _Harness(tester);
    await h.screen();
    h.cart.add(dealFixture());
    h.cart.add(dealFixture());
    h.cart.add(dealFixture(id: 43));
    for (var index = 0; index < 3; index++) {
      await h.confirm(index);
    }
    final request = h.controller.checkout();
    await h.controller.checkout();
    expect(h.api.checkouts, [
      [
        {'dealId': 42, 'quantity': 1, 'reservationId': 'hold_0'},
        {'dealId': 42, 'quantity': 1, 'reservationId': 'hold_1'},
        {'dealId': 43, 'quantity': 1, 'reservationId': 'hold_2'},
      ]
    ]);
    h.api.responses.single.complete(h.order);
    await request;
    await tester.pump();
    expect(h.cart.items, isEmpty);
    expect(h.api.releases, ['hold_0', 'hold_1', 'hold_2']);
    expect(h.cart.isCheckingOut.value, isFalse);
    await h.dismiss();
  });

  _reservationTest(
      'mid-checkout expiry defers release and accepts server success',
      (tester) async {
    final h = _Harness(tester);
    await h.screen();
    h.cart.add(dealFixture());
    await h.confirm(0, lifetime: const Duration(seconds: 1));
    final request = h.controller.checkout();
    await tester.pump(const Duration(seconds: 1));
    expect(h.cart.items, isEmpty);
    expect(h.api.releases, isEmpty);
    expect(find.text('Confirming your order…'), findsOneWidget);
    expect(h.cart.isCheckingOut.value, isTrue);
    h.api.responses.single.complete(h.order);
    await request;
    await tester.pump();
    expect(h.api.releases, ['hold_0']);
    expect(h.cart.isCheckingOut.value, isFalse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Order confirmed'), findsOneWidget);
    await h.dismiss();
  });

  for (final expireLocally in [false, true]) {
    _reservationTest(
        '410 invalidates submitted holds (local expiry: $expireLocally)',
        (tester) async {
      final h = _Harness(tester);
      await h.screen();
      h.cart.add(dealFixture());
      h.cart.add(dealFixture(id: 43));
      await h.confirm(0, lifetime: const Duration(seconds: 1));
      await h.confirm(1);
      final request = h.controller.checkout();
      if (expireLocally) await tester.pump(const Duration(seconds: 1));
      h.api.responses.single.completeError(
          const ApiException('Unknown reservation', statusCode: 410));
      await request;
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.cart.items, isEmpty);
      expect(h.cart.itemCount.value, 0);
      expect(h.api.releases.toSet(), {'hold_0', 'hold_1'});
      expect(h.api.releases.length, 2);
      expect(h.cart.isCheckingOut.value, isFalse);
      expect(find.text('Hold expired'), findsOneWidget);
      expect(h.api.checkouts.length, 1);
      expect(h.api.reserves.length, 2);
      await h.dismiss();
    });
  }

  for (final error in [
    const ApiException('Gateway timeout', statusCode: 502),
    StateError('unexpected response'),
  ]) {
    _reservationTest('checkout failure unlocks and keeps valid holds: $error',
        (tester) async {
      final h = _Harness(tester);
      await h.screen();
      h.cart.add(dealFixture());
      await h.confirm(0);
      final request = h.controller.checkout();
      h.api.responses.single.completeError(error);
      await request;
      expect(h.cart.isCheckingOut.value, isFalse);
      expect(h.cart.canCheckout, isTrue);
      expect(h.cart.itemCount.value, 1);
      expect(h.api.releases, isEmpty);
      await h.dismiss();
    });
  }

  _reservationTest('changing routes cannot start a second checkout',
      (tester) async {
    final h = _Harness(tester);
    await h.screen();
    h.cart.add(dealFixture());
    await h.confirm(0);
    final request = h.controller.checkout();
    await Get.delete<CartController>();
    final replacement =
        Get.put(CartController(cartService: h.cart, orderRepo: h.repo));
    await replacement.checkout();
    expect(h.api.checkouts.length, 1);
    h.api.responses.single.complete(h.order);
    await request;
    expect(h.cart.isCheckingOut.value, isFalse);
    await h.dismiss();
  });

  _reservationTest(
      'bag controls reflect pending, confirmed and checkout states',
      (tester) async {
    final h = _Harness(tester);
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await h.screen();
    h.cart.add(dealFixture());
    await tester.pump();
    expect(find.text('Reserving 1…'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull);
    await h.confirm(0);
    expect(find.text('05:00'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull);
    final request = h.controller.checkout();
    await tester.pump();
    for (final label in ['Reduce quantity', 'Increase quantity']) {
      expect(
          tester
              .widget<IconButton>(find.byWidgetPredicate(
                  (widget) => widget is IconButton && widget.tooltip == label))
              .onPressed,
          isNull);
    }
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Remove'))
            .onPressed,
        isNull);
    h.api.responses.single.complete(h.order);
    await request;
    await h.dismiss();
    expect(tester.takeException(), isNull);
  });

  _reservationTest('reservation ticks rebuild text without rebuilding the bag',
      (tester) async {
    final h = _Harness(tester);
    await h.screen();
    h.cart.add(dealFixture());
    await h.confirm(0);
    await tester.pump();
    final builds = <String, int>{};
    debugOnRebuildDirtyWidget = (element, _) {
      builds.update(element.widget.runtimeType.toString(), (n) => n + 1,
          ifAbsent: () => 1);
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('04:59'), findsOneWidget);
    expect(builds['FlashSaleCountdown'], 1);
    for (final type in ['CartScreen', 'Obx', 'TheNetworkImage', 'Card']) {
      expect(builds[type] ?? 0, 0, reason: '$type rebuilt on a clock tick');
    }
    debugOnRebuildDirtyWidget = null;
    await h.dismiss();
  });

  _reservationTest('repository rejects absent, mismatched and duplicate holds',
      (tester) async {
    final h = _Harness(tester);
    final deal = dealFixture();
    final valid = ReservationModel(
        id: 'same',
        dealId: 42,
        quantity: 1,
        expiresAt: h.clock.now().add(const Duration(minutes: 5)));
    for (final units in [
      <CartUnitModel>[],
      [CartUnitModel(token: Object())],
      [
        CartUnitModel(
            token: Object(),
            reservation: ReservationModel(
                id: 'wrong',
                dealId: 43,
                quantity: 1,
                expiresAt: valid.expiresAt))
      ],
      [
        CartUnitModel(
            token: Object(),
            reservation: ReservationModel(
                id: 'wrong-quantity',
                dealId: 42,
                quantity: 2,
                expiresAt: valid.expiresAt))
      ],
      [
        CartUnitModel(token: Object(), reservation: valid),
        CartUnitModel(token: Object(), reservation: valid)
      ],
    ]) {
      await expectLater(
          h.repo.checkout([CartItemModel(deal: deal, units: units)]),
          throwsStateError);
    }
    expect(h.api.checkouts, isEmpty);
  });
}
