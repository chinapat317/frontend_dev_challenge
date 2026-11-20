import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/home/home_controller.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/paged_response_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

class _Repo extends DealRepo {
  _Repo() : super(api: FakeApiService());

  int feedRequests = 0;
  int flashRequests = 0;

  @override
  Future<PagedResponseModel<DealModel>> fetchDeals({int page = 1}) async {
    feedRequests++;
    // Each response changes, making the page reload observable in the UI.
    final start = DateTime.now();
    return PagedResponseModel(page: page, totalPages: 1, items: [
      DealModel.fromJson({
        'id': feedRequests,
        'pickupWindow': {
          'start': start.toUtc().toIso8601String(),
          'end': start.add(const Duration(hours: 1)).toUtc().toIso8601String(),
        },
      }),
    ]);
  }

  @override
  Future<List<DealModel>> fetchFlashDeals() async {
    flashRequests++;
    return [];
  }
}

Widget _page(HomeController controller) => Directionality(
      textDirection: TextDirection.ltr,
      child: Obx(() => Text(controller.isLoading.value
          ? 'loading'
          : controller.visibleDeals.map((d) => d.id).join(','))),
    );

void main() {
  for (final date in [
    DateTime(2026, 11, 20, 23, 59, 59),
    DateTime(2026, 11, 30, 23, 59, 59),
    DateTime(2026, 12, 31, 23, 59, 59),
  ]) {
    testWidgets('home refreshes at successive local midnights after $date',
        (tester) async {
      var now = date;
      final repo = _Repo();
      final controller = HomeController(dealRepo: repo, now: () => now);
      try {
        controller.todayOnly.value = true;
        controller.onInit();
        await tester.pumpWidget(_page(controller));
        await tester.pump();
        expect(find.text('1'), findsOneWidget);

        now = DateTime(date.year, date.month, date.day + 1);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(find.text('2'), findsOneWidget);

        final nextMidnight = DateTime(now.year, now.month, now.day + 1);
        final elapsed = nextMidnight.difference(now);
        now = nextMidnight;
        await tester.pump(elapsed);
        await tester.pump();
        expect(find.text('3'), findsOneWidget);
        expect(repo.feedRequests, 3);
        expect(repo.flashRequests, 3);
        expect(controller.todayOnly.value, isTrue);
      } finally {
        controller.onClose();
      }
    });
  }

  testWidgets('resume refreshes only after the local date changes',
      (tester) async {
    var now = DateTime(2026, 11, 20, 23);
    final repo = _Repo();
    final controller = HomeController(dealRepo: repo, now: () => now);
    try {
      controller.onInit();
      await tester.pumpWidget(_page(controller));
      await tester.pump();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(repo.feedRequests, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Simulate several suspended days without firing the old midnight timer.
      now = DateTime(2026, 11, 23, 23, 59, 59);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
      expect(repo.flashRequests, 2);

      now = DateTime(2026, 11, 24);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
      expect(repo.feedRequests, 3);
      expect(repo.flashRequests, 3);
    } finally {
      controller.onClose();
    }
  });

  testWidgets('closing home cancels midnight refresh and resume handling',
      (tester) async {
    final repo = _Repo();
    var now = DateTime(2026, 11, 20, 23, 59, 59);
    final controller = HomeController(dealRepo: repo, now: () => now);
    controller.onInit();
    await tester.pump();
    controller.onClose();

    now = DateTime(2026, 11, 23);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(days: 2));
    expect(repo.feedRequests, 1);
    expect(repo.flashRequests, 1);
    expect(tester.takeException(), isNull);
  });
}
