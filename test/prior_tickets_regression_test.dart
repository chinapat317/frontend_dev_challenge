import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/home/home_controller.dart';
import 'package:rescu/feature/home/home_screen.dart';
import 'package:rescu/feature/order/widget/pickup_countdown.dart';
import 'package:rescu/feature/search/search_deals_controller.dart';
import 'package:rescu/feature/shared_widget/the_network_image.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/paged_response_model.dart';
import 'package:rescu/model/pickup_window_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/flash_sale_service.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'support/deal_fixture.dart';
import 'support/analytics_api.dart';

class _SearchRepo extends DealRepo {
  _SearchRepo() : super(api: FakeApiService());
  final searches = <Completer<List<DealModel>>>[];

  @override
  Future<List<DealModel>> search(String query) {
    final request = Completer<List<DealModel>>();
    searches.add(request);
    return request.future;
  }
}

class _FeedRepo extends DealRepo {
  _FeedRepo(this.now) : super(api: FakeApiService());
  final DateTime Function() now;

  @override
  Future<PagedResponseModel<DealModel>> fetchDeals({int page = 1}) async =>
      PagedResponseModel(
        page: page,
        totalPages: 1,
        items: [
          for (var id = 1; id <= 122; id++)
            dealFixture(id: id, endsAt: now().add(const Duration(minutes: 5))),
        ],
      );

  @override
  Future<List<DealModel>> fetchFlashDeals() async => [];
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

  test('RES-101: out-of-order responses and clearing preserve the latest query',
      () async {
    final repo = _SearchRepo();
    final controller = Get.put(SearchDealsController(dealRepo: repo));
    controller.onQueryChanged('s');
    controller.onQueryChanged('sushi');
    repo.searches[1].complete([dealFixture(id: 2)]);
    await Future<void>.delayed(Duration.zero);
    repo.searches[0].complete([dealFixture(id: 1)]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.results.single.id, 2);
    expect(controller.isLoading.value, isFalse);
    controller.onQueryChanged('sushi');
    controller.onQueryChanged('');
    repo.searches[2].complete([dealFixture(id: 3)]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.results, isEmpty);
    expect(controller.hasSearched.value, isFalse);
  });

  test('RES-101: repeating a query does not resurrect its older response',
      () async {
    final repo = _SearchRepo();
    final controller = Get.put(SearchDealsController(dealRepo: repo));
    controller.onQueryChanged('sushi');
    controller.onQueryChanged('s');
    controller.onQueryChanged('sushi');
    repo.searches[2].complete([dealFixture(id: 3)]);
    await Future<void>.delayed(Duration.zero);
    repo.searches[0].complete([dealFixture(id: 1)]);
    repo.searches[1].complete([dealFixture(id: 2)]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.results.single.id, 3);
  });

  test('RES-101: a disposed search ignores late success and failure', () async {
    final repo = _SearchRepo();
    final controller = Get.put(SearchDealsController(dealRepo: repo));
    controller.onQueryChanged('s');
    controller.onQueryChanged('sushi');
    await Get.delete<SearchDealsController>();
    repo.searches[0].completeError(Exception('old failure'));
    repo.searches[1].complete([dealFixture()]);
    await Future<void>.delayed(Duration.zero);
    expect(controller.results, isEmpty);
  });

  testWidgets('RES-102: leaving pickup countdown cancels its timer',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: PickupCountdown(
          pickupStart: DateTime.now().add(const Duration(minutes: 5))),
    ));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('RES-105: scrolling and countdown ticks do not rebuild the feed',
      (tester) async {
    Get.put(FlashSaleService(now: tester.binding.clock.now));
    final controller = Get.put(HomeController(
        dealRepo: _FeedRepo(tester.binding.clock.now),
        now: tester.binding.clock.now));
    await tester.pumpWidget(const GetMaterialApp(home: HomeScreen()));
    await tester.pump();
    await tester.pump();
    final counts = <String, int>{};
    debugOnRebuildDirtyWidget = (element, _) {
      final type = element.widget.runtimeType.toString();
      counts.update(type, (count) => count + 1, ifAbsent: () => 1);
    };
    controller.scrollController.jumpTo(100);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(counts['Obx'] ?? 0, 0);
    expect(counts['HomeScreen'] ?? 0, 0);
    expect(counts['DealCard'] ?? 0, 0);
    expect(counts['TheNetworkImage'] ?? 0, 0);
    expect(counts['FlashSaleCountdown'], greaterThan(0));
    debugOnRebuildDirtyWidget = null;
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
    await Get.delete<HomeController>();
    expect(tester.takeException(), isNull);
  });

  testWidgets('RES-105: images still decode at physical display width',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(devicePixelRatio: 3),
        child: Center(child: TheNetworkImage(url: '', width: 100, height: 80)),
      ),
    ));
    final image =
        tester.widget<CachedNetworkImage>(find.byType(CachedNetworkImage));
    expect(image.memCacheWidth, 300);
    await tester.pumpWidget(const SizedBox.shrink());
    Get.find<AnalyticsService>().onClose();
  });

  test('RES-106: UTC pickup instants retain correct local labels and dates',
      () {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, 6);
    PickupWindowModel window(DateTime date) => PickupWindowModel.fromJson({
          'start': date.toUtc().toIso8601String(),
          'end': date
              .add(const Duration(hours: 3, minutes: 30))
              .toUtc()
              .toIso8601String(),
        });
    final today = window(start);
    expect(today.label, '06:00 – 09:30');
    expect(today.isToday, isTrue);
    expect(today.start.toUtc(), start.toUtc());
    expect(
        window(DateTime(now.year, now.month + 1, now.day, 6)).isToday, isFalse);
    expect(
        window(DateTime(now.year + 1, now.month, now.day, 6)).isToday, isFalse);
  });
}
