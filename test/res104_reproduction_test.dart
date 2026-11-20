import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';
import 'package:rescu/feature/home/home_controller.dart';
import 'package:rescu/model/deal_model.dart';
import 'package:rescu/model/paged_response_model.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

// Control response order without timers or random backend latency. The fixture
// has 122 deals across seven pages, matching the catalog's pagination shape.
class _PendingPage {
  _PendingPage(this.page);

  final int page;
  final result = Completer<PagedResponseModel<DealModel>>();

  void complete() => result.complete(PagedResponseModel(
        page: page,
        totalPages: 7,
        items: List.generate(
            page == 7 ? 2 : 20,
            (i) => DealModel.fromJson({
                  'id': (page - 1) * 20 + i + 1,
                  'pickupWindow': {
                    'start': '2026-11-19T00:00:00Z',
                    'end': '2026-11-19T01:00:00Z',
                  },
                })),
      ));
}

class _ControlledRepo extends DealRepo {
  _ControlledRepo() : super(api: FakeApiService());

  final requests = <_PendingPage>[];

  @override
  Future<PagedResponseModel<DealModel>> fetchDeals({int page = 1}) {
    final request = _PendingPage(page);
    requests.add(request);
    return request.result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ControlledRepo repo;
  late HomeController controller;

  setUp(() async {
    repo = _ControlledRepo();
    controller = HomeController(dealRepo: repo);
    addTearDown(controller.onClose);
    final initial = controller.refreshDeals();
    repo.requests.last.complete();
    await initial;
  });

  Future<void> completeLoad(int expectedPage) async {
    final before = repo.requests.length;
    final load = controller.loadMore();
    expect(repo.requests.length, before + 1);
    expect(repo.requests.last.page, expectedPage);
    repo.requests.last.complete();
    await load;
  }

  // This controller-only fixture has no loading animation to schedule a frame.
  // pull_to_refresh publishes footer changes in a post-frame callback.
  Future<void> flushFooter(WidgetTester tester) async {
    tester.binding.scheduleFrame();
    await tester.pump();
  }

  group('RES-104 regression', () {
    for (final refreshFirst in [true, false]) {
      test('refreshFirst=$refreshFirst: stale page never duplicates the feed',
          () async {
        final oldLoad = controller.loadMore();
        final stale = repo.requests.last;
        expect(stale.page, 2);
        final refresh = controller.refreshDeals();
        final fresh = repo.requests.last;

        if (refreshFirst) {
          fresh.complete();
          await refresh;
          stale.complete();
          await oldLoad;
        } else {
          stale.complete();
          await oldLoad;
          fresh.complete();
          await refresh;
        }

        expect(controller.deals.length, 20);
        for (var page = 2; page <= 7; page++) {
          await completeLoad(page);
        }
        expect(controller.hasMore, isFalse);
        expect(controller.deals.map((d) => d.id),
            orderedEquals(List.generate(122, (i) => i + 1)));
      });
    }

    // The fake feed endpoint does not throw; injected errors verify how a real
    // repository failure interacts with refresh and pagination state.
    test('stale failure cannot roll back the refreshed page', () async {
      final oldLoad = controller.loadMore();
      final stale = repo.requests.last;
      final refresh = controller.refreshDeals();
      repo.requests.last.complete();
      await refresh;
      stale.result.completeError(Exception('old page failed'));
      await oldLoad;

      await completeLoad(2);
      expect(controller.deals.map((d) => d.id),
          orderedEquals(List.generate(40, (i) => i + 1)));
    });

    test('failed refresh preserves existing pages and ends the indicator',
        () async {
      await completeLoad(2);
      controller.refreshController.headerMode!.value = RefreshStatus.refreshing;
      final refresh = controller.refreshDeals();
      repo.requests.last.result.completeError(Exception('refresh failed'));
      await refresh;

      expect(controller.refreshController.headerStatus, RefreshStatus.failed);
      expect(controller.deals.length, 40);
      await completeLoad(3);
      expect(controller.deals.map((d) => d.id),
          orderedEquals(List.generate(60, (i) => i + 1)));
    });

    for (final refreshFirst in [true, false]) {
      test('failed refreshFirst=$refreshFirst: valid pending page is retained',
          () async {
        final oldLoad = controller.loadMore();
        final stale = repo.requests.last;
        final refresh = controller.refreshDeals();
        final fresh = repo.requests.last;

        if (refreshFirst) {
          fresh.result.completeError(Exception('refresh failed'));
          await refresh;
          stale.complete();
          await oldLoad;
        } else {
          stale.complete();
          await oldLoad;
          fresh.result.completeError(Exception('refresh failed'));
          await refresh;
        }

        expect(controller.deals.length, 40);
        await completeLoad(3);
        expect(controller.deals.map((d) => d.id),
            orderedEquals(List.generate(60, (i) => i + 1)));
      });
    }

    testWidgets('failed pagination shows failure and retries the same page',
        (tester) async {
      final load = controller.loadMore();
      repo.requests.last.result.completeError(Exception('page failed'));
      await load;
      await flushFooter(tester);
      expect(controller.refreshController.footerStatus, LoadStatus.failed);
      expect(controller.deals.length, 20);

      await completeLoad(2);
      await flushFooter(tester);
      expect(controller.refreshController.footerStatus, LoadStatus.idle);
      expect(controller.deals.length, 40);
    });

    test('pending refresh blocks pagination and overlapping refreshes',
        () async {
      final refresh = controller.refreshDeals();
      final before = repo.requests.length;
      await controller.loadMore();
      await controller.refreshDeals();
      expect(repo.requests.length, before);

      repo.requests.last.complete();
      await refresh;
      await completeLoad(2);
      expect(controller.deals.length, 40);
    });

    testWidgets('successful refresh resets an exhausted footer',
        (tester) async {
      for (var page = 2; page <= 7; page++) {
        await completeLoad(page);
      }
      await controller.loadMore();
      await flushFooter(tester);
      expect(controller.refreshController.footerStatus, LoadStatus.noMore);

      final refresh = controller.refreshDeals();
      repo.requests.last.complete();
      await refresh;
      expect(controller.refreshController.footerStatus, LoadStatus.idle);
      await completeLoad(2);
      expect(controller.deals.length, 40);
    });
  });
}
