import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/binding/deal_details_binding.dart';
import 'package:rescu/feature/cart/cart_controller.dart';
import 'package:rescu/feature/deal/deal_details_controller.dart';
import 'package:rescu/feature/deal/deal_details_screen.dart';
import 'package:rescu/feature/home/widget/flash_deals_section.dart';
import 'package:rescu/feature/shared_widget/deal_card.dart';
import 'package:rescu/feature/shared_widget/flash_sale_countdown.dart';
import 'package:rescu/model/cart_item_model.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/order_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/repository/order_repo.dart';
import 'package:rescu/routes/routes.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/flash_sale_service.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'support/deal_fixture.dart';
import 'support/analytics_api.dart';
import 'support/reservation_repo.dart';

class _DealRepo extends DealRepo {
  _DealRepo(this.deal) : super(api: FakeApiService());
  final DealModel deal;
  int requests = 0;

  @override
  Future<DealModel> fetchById(int id) async {
    requests++;
    return deal;
  }
}

class _OrderRepo extends OrderRepo {
  _OrderRepo() : super(api: FakeApiService());
  final submitted = <List<CartItemModel>>[];
  final response = Completer<OrderModel>();

  @override
  Future<OrderModel> checkout(List<CartItemModel> items) {
    submitted.add(items);
    return response.future;
  }
}

Future<DealDetailsController> _openDetails(
  WidgetTester tester, {
  required DealModel deal,
  required DealRepo repo,
  required CartService cart,
  required bool passModel,
}) async {
  Get.put<DealRepo>(repo);
  Get.put(cart);
  Get.put(AnalyticsService(api: ImmediateAnalyticsApi()));
  await tester.pumpWidget(GetMaterialApp(
    home: Scaffold(
      body: TextButton(
        onPressed: () => Get.toNamed(
          Routes.dealRoute(deal.id, source: passModel ? 'home_feed' : 'push'),
          arguments: passModel ? deal : null,
        ),
        child: const Text('Open deal'),
      ),
    ),
    getPages: [
      GetPage(
        name: Routes.deal,
        page: () => const DealDetailsScreen(),
        binding: DealDetailsBinding(),
      ),
    ],
  ));
  await tester.tap(find.text('Open deal'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return Get.find<DealDetailsController>();
}

void main() {
  setUp(() {
    Get.put(AnalyticsService(api: ImmediateAnalyticsApi()));
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    Get.reset();
    VisibilityDetectorController.instance.updateInterval =
        const Duration(milliseconds: 500);
  });

  test(
      'format boundaries, clamping, rounding and equivalent UTC/local instants',
      () {
    final now = DateTime.utc(2026, 11, 20);
    for (final entry in <int, String>{
      -1: 'Expired',
      0: 'Expired',
      1: '00:01',
      999999: '00:01',
      1000000: '00:01',
      59000000: '00:59',
      60000000: '01:00',
      3599000000: '59:59',
      3600000000: '01:00:00',
      3661000000: '01:01:01',
      90000000000: '25:00:00',
    }.entries) {
      final end = now.add(Duration(microseconds: entry.key));
      expect(formatFlashSaleCountdown(end, now), entry.value);
      expect(formatFlashSaleCountdown(end.toLocal(), now), entry.value);
    }
  });

  testWidgets('one clock expires bag lines at a fractional deadline without UI',
      (tester) async {
    final service = FlashSaleService(now: tester.binding.clock.now);
    final notices = <List<DealModel>>[];
    final cart = CartService(
        orderRepo: ImmediateReservationRepo(now: service.now),
        flashSales: service,
        onExpired: notices.add);
    final deadline = service.now().add(const Duration(milliseconds: 1250));
    final flash = dealFixture(endsAt: deadline);
    cart.add(flash);
    cart.add(flash);
    cart.add(dealFixture(id: 43, endsAt: deadline));
    cart.add(dealFixture(id: 44));
    expect(cart.itemCount.value, 4);
    expect(cart.total, 80);

    await tester.pump(const Duration(milliseconds: 1249));
    expect(cart.items.length, 3);
    await tester.pump(const Duration(milliseconds: 1));
    expect(cart.items.single.deal.id, 44);
    expect(cart.itemCount.value, 1);
    expect(cart.total, 20);
    expect(notices.single.map((deal) => deal.id), [42, 43]);
    expect(cart.add(flash), AddToBagResult.expired);
    await tester.pump(const Duration(seconds: 10));
    expect(notices.length, 1);
    cart.onClose();
    service.onClose();
  });

  testWidgets('expiry notices are visible on the current route',
      (tester) async {
    final service = Get.put(FlashSaleService(now: tester.binding.clock.now));
    final cart = Get.put(CartService(
        orderRepo: ImmediateReservationRepo(now: service.now),
        flashSales: service));
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    cart.add(
        dealFixture(endsAt: service.now().add(const Duration(seconds: 1))));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Flash sale expired'), findsOneWidget);
    expect(find.text('Deal 42 expired and was removed from your bag.'),
        findsOneWidget);
    expect(cart.items, isEmpty);
    Get.closeAllSnackbars();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
  });

  testWidgets(
      'resume reconciles expired lines and text after a long suspension',
      (tester) async {
    final service = Get.put(FlashSaleService(now: tester.binding.clock.now));
    final notices = <List<DealModel>>[];
    final cart = CartService(
        orderRepo: ImmediateReservationRepo(now: service.now),
        flashSales: service,
        onExpired: notices.add);
    final end = service.now().add(const Duration(seconds: 3));
    cart.add(dealFixture(endsAt: end));
    await tester.pumpWidget(MaterialApp(
      home: FlashSaleCountdown(endsAt: end, flashSales: service),
    ));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 10));
    expect(cart.items.length, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Expired'), findsOneWidget);
    expect(cart.items, isEmpty);
    expect(notices.length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
    cart.onClose();
  });

  testWidgets('removing lines and disposing subscribers cancels clock work',
      (tester) async {
    final service = FlashSaleService(now: tester.binding.clock.now);
    final notices = <List<DealModel>>[];
    final cart = CartService(
        orderRepo: ImmediateReservationRepo(now: service.now),
        flashSales: service,
        onExpired: notices.add);
    final end = service.now().add(const Duration(seconds: 3));
    cart.add(dealFixture(endsAt: end));
    cart.decrement(42);
    cart.add(dealFixture(id: 43, endsAt: end));
    cart.remove(43);
    cart.add(dealFixture(id: 44, endsAt: end));
    cart.clear();
    await tester.pumpWidget(MaterialApp(
      home: FlashSaleCountdown(endsAt: end, flashSales: service),
    ));
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 4));
    expect(notices, isEmpty);
    expect(tester.takeException(), isNull);
    cart.onClose();
    service.onClose();
    // The test binding also fails this test if any timer is left pending.
  });

  testWidgets('reused countdown handles changed deadlines and normal deals',
      (tester) async {
    final service = FlashSaleService(now: tester.binding.clock.now);
    var end = service.now().add(const Duration(seconds: 1));
    Widget page() => MaterialApp(
          home: FlashSaleState(
            endsAt: end,
            flashSales: service,
            builder: (expired, _) => FlashSaleCountdown(
              endsAt: end,
              flashSales: service,
            ),
          ),
        );
    await tester.pumpWidget(page());
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Expired'), findsOneWidget);
    end = service.now().add(const Duration(seconds: 10));
    await tester.pumpWidget(page());
    expect(find.text('00:10'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:09'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(
      home: FlashSaleState(
        endsAt: null,
        flashSales: service,
        builder: (expired, _) => Text('$expired'),
      ),
    ));
    expect(find.text('false'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
    service.onClose();
  });

  testWidgets('feed/search cards and flash rail count down and disable at zero',
      (tester) async {
    final service = Get.put(FlashSaleService(now: tester.binding.clock.now));
    final deal =
        dealFixture(endsAt: service.now().add(const Duration(seconds: 2)));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          DealCard(deal: deal),
          DealCard(deal: deal, source: 'search'),
          FlashDealsSection(deals: [deal]),
        ]),
      ),
    ));
    expect(find.text('00:02'), findsNWidgets(3));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('00:01'), findsNWidgets(3));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Expired'), findsNWidgets(3));
    final wrappers = tester.widgetList<IgnorePointer>(find.descendant(
      of: find.byType(FlashSaleCardState),
      matching: find.byType(IgnorePointer),
    ));
    expect(wrappers.length, 3);
    expect(wrappers.every((widget) => widget.ignoring), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
    expect(tester.takeException(), isNull);
  });

  for (final passModel in [true, false]) {
    final entry = passModel ? 'model argument' : 'URL ID';
    testWidgets('$entry: expiry works without polling or leaked workers',
        (tester) async {
      final service = Get.put(FlashSaleService(now: tester.binding.clock.now));
      final cart = Get.put(CartService(
          orderRepo: ImmediateReservationRepo(now: service.now),
          flashSales: service,
          onExpired: (_) {}));
      final deal =
          dealFixture(endsAt: service.now().add(const Duration(seconds: 3)));
      final repo = _DealRepo(deal);
      final controller = await _openDetails(tester,
          deal: deal, repo: repo, cart: cart, passModel: passModel);
      final initialRequests = passModel ? 0 : 1;
      expect(repo.requests, initialRequests);
      expect(controller.deal, same(deal));
      expect(find.text('Deal 42'), findsOneWidget);
      cart.add(deal);
      await tester.pump();
      expect(repo.requests, initialRequests + 1); // existing cart worker
      await tester.pump(const Duration(seconds: 1));
      expect(repo.requests, initialRequests + 1);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      final button = tester.widget<FilledButton>(
          find.byWidgetPredicate((widget) => widget is FilledButton));
      expect(button.onPressed, isNull);
      expect(find.text('Expired'), findsNWidgets(2));
      expect(cart.items, isEmpty);
      expect(
          repo.requests, initialRequests + 2); // one check for expiry removal
      await tester.pumpWidget(const SizedBox.shrink());
      Get.find<AnalyticsService>().onClose();
      await Get.delete<DealDetailsController>();
      cart.add(dealFixture(id: 43));
      expect(repo.requests, initialRequests + 2);
      expect(controller.isClosed, isTrue);
      expect(tester.takeException(), isNull);
      cart.onClose();
      service.onClose();
    });
  }

  testWidgets(
      'checkout revalidates at submission and requires review of changes',
      (tester) async {
    final service = FlashSaleService(now: tester.binding.clock.now);
    final cart = CartService(
        orderRepo: ImmediateReservationRepo(now: service.now),
        flashSales: service,
        onExpired: (_) {});
    final repo = _OrderRepo();
    final controller = CartController(cartService: cart, orderRepo: repo);
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    cart.add(
        dealFixture(endsAt: service.now().add(const Duration(seconds: 1))));
    cart.add(dealFixture(id: 43));
    service.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 2));
    await controller.checkout();
    expect(repo.submitted, isEmpty);
    expect(cart.items.single.deal.id, 43);
    await tester.pump();
    final checkout = controller.checkout();
    expect(repo.submitted.single.single.deal.id, 43);
    repo.response.complete(OrderModel.fromJson({
      'id': 9,
      'pickupStart': '2026-11-20T00:00:00Z',
      'pickupEnd': '2026-11-20T02:30:00Z',
    }));
    await checkout;
    await tester.pumpAndSettle();
    Get.closeAllSnackbars();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
    cart.onClose();
    service.onClose();
  });

  for (final passModel in [true, false]) {
    final entry = passModel ? 'model argument' : 'URL ID';
    testWidgets('$entry: already-expired deals cannot show add success',
        (tester) async {
      final service = Get.put(FlashSaleService(now: tester.binding.clock.now));
      final cart = Get.put(CartService(
          orderRepo: ImmediateReservationRepo(now: service.now),
          flashSales: service));
      final deal = dealFixture(endsAt: service.now());
      final repo = _DealRepo(deal);
      final controller = await _openDetails(tester,
          deal: deal, repo: repo, cart: cart, passModel: passModel);
      expect(repo.requests, passModel ? 0 : 1);
      expect(find.text('Expired'), findsNWidgets(2));
      controller
          .addToCart(); // Guard callers bypassing the disabled button, too.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(cart.items, isEmpty);
      expect(find.text('Flash sale expired'), findsOneWidget);
      expect(find.text('Added to bag'), findsNothing);
      Get.closeAllSnackbars();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      await tester.pump();
      expect(Get.isSnackbarOpen, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      Get.find<AnalyticsService>().onClose();
      await Get.delete<DealDetailsController>();
    });
  }

  testWidgets('a submitted checkout can finish after its flash sale expires',
      (tester) async {
    final service = Get.put(FlashSaleService(now: tester.binding.clock.now));
    final notices = <List<DealModel>>[];
    final cart = Get.put(CartService(
        orderRepo: ImmediateReservationRepo(now: service.now),
        flashSales: service,
        onExpired: notices.add));
    final repo = _OrderRepo();
    final controller = CartController(cartService: cart, orderRepo: repo);
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold()));
    cart.add(
        dealFixture(endsAt: service.now().add(const Duration(seconds: 1))));
    await tester.pump();
    final checkout = controller.checkout();
    expect(repo.submitted.single.single.deal.id, 42);
    await tester.pump(const Duration(seconds: 1));
    expect(cart.items, isEmpty);
    expect(notices.length, 1);
    repo.response.complete(OrderModel.fromJson({
      'id': 9,
      'pickupStart': '2026-11-20T00:00:00Z',
      'pickupEnd': '2026-11-20T02:30:00Z',
    }));
    await checkout;
    await tester.pumpAndSettle();
    expect(controller.isCheckingOut.value, isFalse);
    expect(find.text('Order confirmed'), findsOneWidget);
    Get.closeAllSnackbars();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
  });

  testWidgets('120 visible cards rebuild only countdown text on second ticks',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(3200, 5000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final service = Get.put(FlashSaleService(now: tester.binding.clock.now));
    final end = service.now().add(const Duration(minutes: 5));
    await tester.pumpWidget(MaterialApp(
      home: SingleChildScrollView(
        child: Wrap(children: [
          for (var id = 1; id <= 120; id++)
            SizedBox(
                width: 400,
                child: DealCard(deal: dealFixture(id: id, endsAt: end))),
        ]),
      ),
    ));
    await tester.pump(); // allow invalid image placeholders to settle
    expect(find.byType(DealCard), findsNWidgets(120));
    expect(tester.getRect(find.byType(DealCard).last).bottom, lessThan(5000));
    final builds = <String, int>{};
    debugOnRebuildDirtyWidget = (element, _) {
      final type = element.widget.runtimeType.toString();
      builds.update(type, (count) => count + 1, ifAbsent: () => 1);
    };
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('04:59'), findsNWidgets(120));
    expect(builds['FlashSaleCountdown'], 120);
    for (final type in [
      'DealCard',
      'TheNetworkImage',
      'FlashSaleState',
      'Obx'
    ]) {
      expect(builds[type] ?? 0, 0,
          reason: '$type must not rebuild each second');
    }
    debugOnRebuildDirtyWidget = null;
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
    expect(tester.takeException(), isNull);
  });
}
