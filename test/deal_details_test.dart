import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/binding/deal_details_binding.dart';
import 'package:rescu/feature/deal/deal_details_controller.dart';
import 'package:rescu/feature/deal/deal_details_screen.dart';
import 'package:rescu/feature/home/widget/flash_deals_section.dart';
import 'package:rescu/feature/shared_widget/deal_card.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/routes/routes.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/api_exception.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/flash_sale_service.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'support/analytics_api.dart';
import 'support/reservation_repo.dart';

class _ControlledDealRepo extends DealRepo {
  _ControlledDealRepo() : super(api: FakeApiService());

  final ids = <int>[];
  final requests = <Completer<DealModel>>[];

  @override
  Future<DealModel> fetchById(int id) {
    ids.add(id);
    final request = Completer<DealModel>();
    requests.add(request);
    return request.future;
  }
}

DealModel _deal({int quantityLeft = 2, DateTime? flashSaleEndsAt}) =>
    DealModel.fromJson({
      'id': 42,
      'name': 'Mystery Japanese Basket',
      'quantityLeft': quantityLeft,
      'flashSaleEndsAt': flashSaleEndsAt?.toIso8601String(),
      'pickupWindow': {
        'start': '2026-11-20T00:00:00Z',
        'end': '2026-11-20T02:30:00Z',
      },
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ControlledDealRepo repo;
  late CartService cart;
  late AnalyticsService analytics;
  late FlashSaleService flashSales;

  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    Get.testMode = true;
    Get.parameters = {'id': '42', 'source': 'push'};
    repo = _ControlledDealRepo();
    flashSales = Get.put(FlashSaleService());
    cart = CartService(
        flashSales: flashSales, orderRepo: ImmediateReservationRepo());
    analytics = AnalyticsService(api: ImmediateAnalyticsApi());
  });

  tearDown(() {
    analytics.onClose();
    VisibilityDetectorController.instance.updateInterval =
        const Duration(milliseconds: 500);
    cart.onClose();
    flashSales.onClose();
    Get.reset();
  });

  DealDetailsController openController() => Get.put(DealDetailsController(
        dealRepo: repo,
        cartService: cart,
        analytics: analytics,
      ));

  Future<void> flushRequest() => Future<void>.delayed(Duration.zero);

  test('loads URL ID without arguments and captures source before awaiting',
      () async {
    expect(Get.arguments, isNull);
    final controller = openController();
    expect(controller.isLoading.value, isTrue);
    expect(controller.deal, isNull);
    expect(repo.ids, [42]);

    Get.parameters = {'id': '7', 'source': 'search'};
    final loaded = _deal();
    repo.requests.single.complete(loaded);
    await flushRequest();

    expect(controller.deal, same(loaded));
    expect(controller.quantityLeft, 2);
    expect(controller.isLoading.value, isFalse);
    expect(controller.error.value, isNull);
    expect(
        analytics.events.single.properties, {'deal_id': 42, 'source': 'push'});
  });

  for (final id in [null, '', 'invalid', '0', '-1']) {
    test('rejects invalid ID $id without fetching', () {
      Get.parameters = {if (id != null) 'id': id};
      final controller = openController();
      expect(repo.ids, isEmpty);
      expect(controller.isLoading.value, isFalse);
      expect(controller.error.value, 'This deal link is invalid.');
      expect(analytics.events, isEmpty);
      controller.addToCart();
      expect(cart.items, isEmpty);
    });
  }

  test('failed request can retry the captured ID and defaults source',
      () async {
    Get.parameters = {'id': '42'};
    final controller = openController();
    repo.requests.single.completeError(const ApiException('Unavailable'));
    await flushRequest();
    expect(
        controller.error.value, 'Could not load this deal. Please try again.');
    expect(controller.isLoading.value, isFalse);
    expect(analytics.events, isEmpty);

    Get.parameters = {'id': '7'};
    final retry = controller.loadDeal();
    expect(repo.ids, [42, 42]);
    repo.requests.last.complete(_deal());
    await retry;
    expect(controller.deal?.id, 42);
    expect(controller.error.value, isNull);
    expect(analytics.events.single.properties['source'], 'unknown');
  });

  test('404 is handled without a loaded deal or analytics event', () async {
    final controller = openController();
    repo.requests.single
        .completeError(const ApiException('Not found', statusCode: 404));
    await flushRequest();
    expect(controller.error.value, 'This deal is no longer available.');
    expect(controller.deal, isNull);
    expect(controller.isLoading.value, isFalse);
    expect(analytics.events, isEmpty);
  });

  test('leaving during loading ignores the result and creates no worker',
      () async {
    final controller = openController();
    await Get.delete<DealDetailsController>();
    expect(controller.isClosed, isTrue);
    repo.requests.single.complete(_deal());
    await flushRequest();
    cart.add(_deal());
    expect(controller.deal, isNull);
    expect(analytics.events, isEmpty);
    expect(repo.ids, [42]);
  });

  test('cart availability updates stop when the loaded controller closes',
      () async {
    final controller = openController();
    repo.requests.single.complete(_deal());
    await flushRequest();
    cart.add(_deal());
    expect(repo.ids, [42, 42]);
    repo.requests.last.complete(_deal(quantityLeft: 1));
    await flushRequest();
    expect(controller.quantityLeft, 1);

    await Get.delete<DealDetailsController>();
    cart.clear();
    expect(repo.ids, [42, 42]);
  });

  for (final passModel in [true, false]) {
    testWidgets(
        passModel
            ? 'model argument takes precedence over an invalid URL ID'
            : 'non-model argument falls back to the URL ID', (tester) async {
      final passedDeal = _deal();
      Get.put<DealRepo>(repo);
      Get.put(cart);
      Get.put(analytics);
      await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
          body: TextButton(
            onPressed: () => Get.toNamed(
              '${Routes.deal}?id=${passModel ? 'invalid' : '42'}&source=push',
              arguments: passModel ? passedDeal : {'unexpected': true},
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
      if (passModel) {
        expect(repo.ids, isEmpty);
      } else {
        expect(repo.ids, [42]);
        repo.requests.single.complete(passedDeal);
        await tester.pump();
      }
      expect(Get.find<DealDetailsController>().deal, same(passedDeal));
      expect(find.text('Add to bag'), findsOneWidget);
      expect(analytics.events.single.properties,
          {'deal_id': 42, 'source': 'push'});
      await tester.pumpWidget(const SizedBox.shrink());
      analytics.onClose();
      await Get.delete<DealDetailsController>();
      expect(tester.takeException(), isNull);
    });
  }

  for (final entry in ['deep_link', 'home_feed', 'flash_rail']) {
    testWidgets('$entry navigation loads a working deal page', (tester) async {
      final passedDeal = _deal(
        flashSaleEndsAt: entry == 'flash_rail'
            ? DateTime.now().add(const Duration(hours: 1))
            : null,
      );
      Get.put<DealRepo>(repo);
      Get.put(cart);
      Get.put(analytics);
      await tester.pumpWidget(GetMaterialApp(
        home: Scaffold(
          body: entry == 'home_feed'
              ? DealCard(deal: passedDeal, source: 'home_feed')
              : entry == 'flash_rail'
                  ? FlashDealsSection(deals: [passedDeal])
                  : TextButton(
                      onPressed: () =>
                          Get.toNamed(Routes.dealRoute(42, source: 'push')),
                      child: const Text('Open deep link'),
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
      await tester.tap(
          find.text(entry == 'deep_link' ? 'Open deep link' : passedDeal.name));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      if (entry == 'deep_link') {
        expect(Get.arguments, isNull);
        expect(repo.ids, [42]);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Add to bag'), findsNothing);

        repo.requests.single.complete(_deal());
        await tester.pump();
        await tester.pump();
      } else {
        expect(Get.arguments, same(passedDeal));
        expect(Get.find<DealDetailsController>().deal, same(passedDeal));
        expect(repo.ids, isEmpty);
        expect(find.byType(CircularProgressIndicator), findsNothing);
      }
      expect(analytics.events.single.properties,
          {'deal_id': 42, 'source': entry == 'deep_link' ? 'push' : entry});
      expect(find.text('Mystery Japanese Basket'), findsOneWidget);
      expect(find.text('2 left'), findsOneWidget);
      await tester.tap(find.text('Add to bag'));
      await tester.pump();
      expect(cart.items.single.deal.id, 42);
      expect(repo.ids, entry == 'deep_link' ? [42, 42] : [42]);
      repo.requests.last.complete(_deal());
      await tester.pump();

      Get.closeAllSnackbars();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox.shrink());
      analytics.onClose();
      cart.onClose();
      flashSales.onClose();
      expect(tester.takeException(), isNull);
    });
  }
}
