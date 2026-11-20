import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/shared_widget/deal_impression_tracker.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/impression_route_observer.dart';
import 'package:visibility_detector/visibility_detector.dart';

class _AnalyticsApi extends FakeApiService {
  final batches = <List<Map<String, dynamic>>>[];
  final requests = <Completer<void>>[];

  @override
  Future<void> sendAnalyticsBatch(List<Map<String, dynamic>> events) {
    batches.add(events);
    final request = Completer<void>();
    requests.add(request);
    return request.future;
  }
}

class _BuildCounter extends StatelessWidget {
  const _BuildCounter(this.onBuild);
  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox(width: 100, height: 100);
  }
}

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  tearDown(() {
    Get.reset();
    VisibilityDetectorController.instance.updateInterval =
        const Duration(milliseconds: 500);
  });

  AnalyticsService service(WidgetTester tester, [_AnalyticsApi? api]) =>
      Get.put(AnalyticsService(api: api, now: tester.binding.clock.now));

  void impression(AnalyticsService analytics, int id,
          {String source = 'home_feed', int position = 0}) =>
      analytics.recordDealImpression(
          dealId: id, source: source, position: position);

  Widget clippedCard({
    double visibleHeight = 100,
    int id = 42,
    String source = 'home_feed',
    int position = 3,
    Widget child = const SizedBox(width: 100, height: 100),
  }) =>
      MaterialApp(
        navigatorObservers: [impressionRouteObserver],
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 100,
              height: visibleHeight,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minHeight: 100,
                  maxHeight: 100,
                  child: DealImpressionTracker(
                    dealId: id,
                    source: source,
                    position: position,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> finish(WidgetTester tester, AnalyticsService analytics) async {
    await tester.pumpWidget(const SizedBox.shrink());
    analytics.onClose();
  }

  testWidgets('deduplicates by deal across sources until a new app session',
      (tester) async {
    final analytics = service(tester);
    impression(analytics, 42, source: 'flash_rail', position: 2);
    impression(analytics, 42, source: 'search', position: 7);
    expect(analytics.events.length, 1);
    expect(analytics.events.single.toJson(), {
      'name': 'deal_impression',
      'properties': {'deal_id': 42, 'source': 'flash_rail', 'position': 2},
      'at': tester.binding.clock.now().toIso8601String(),
    });
    analytics.onClose();
    final nextSession = AnalyticsService(now: tester.binding.clock.now);
    impression(nextSession, 42, source: 'search');
    expect(nextSession.events.length, 1);
    nextSession.onClose();
  });

  testWidgets('ten analytics events trigger a batch without waiting 15 seconds',
      (tester) async {
    final api = _AnalyticsApi();
    final analytics = service(tester, api);
    analytics.logEvent('screen_view', {'screen': '/home'});
    for (var id = 1; id <= 8; id++) {
      impression(analytics, id);
    }
    expect(api.batches, isEmpty);
    impression(analytics, 9);
    expect(api.batches.single.length, 10);
    expect(api.batches.single.first['name'], 'screen_view');
    api.requests.single.complete();
    await tester.pump();
    expect(analytics.events.length, 10); // Delivery preserves debug history.
    await tester.pump(const Duration(seconds: 15));
    expect(api.batches.length, 1);
    await finish(tester, analytics);
  });

  testWidgets('15 seconds starts at the first unsent event, not the last',
      (tester) async {
    final api = _AnalyticsApi();
    final analytics = service(tester, api);
    impression(analytics, 1);
    await tester.pump(const Duration(seconds: 14));
    impression(analytics, 2);
    await tester.pump(const Duration(milliseconds: 999));
    expect(api.batches, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(api.batches.single.length, 2);
    api.requests.single.complete();
    await tester.pump();
    // A new queue gets its own deadline.
    impression(analytics, 3);
    await tester.pump(const Duration(seconds: 14));
    expect(api.batches.length, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(api.batches.length, 2);
    api.requests.last.complete();
    await tester.pump();
    await finish(tester, analytics);
  });

  testWidgets(
      'in-flight arrivals survive and overdue events send after success',
      (tester) async {
    final api = _AnalyticsApi();
    final analytics = service(tester, api);
    for (var id = 1; id <= 10; id++) {
      impression(analytics, id);
    }
    impression(analytics, 11);
    await tester.pump(const Duration(seconds: 16));
    expect(api.batches.length, 1); // No concurrent request.
    api.requests.first.complete();
    await tester.pump();
    expect(api.batches.length, 2);
    expect(api.batches.last.single['properties']['deal_id'], 11);
    api.requests.last.complete();
    await tester.pump();
    await finish(tester, analytics);
  });

  testWidgets(
      'failed requests retain events and retry without duplicate logging',
      (tester) async {
    final api = _AnalyticsApi();
    final analytics = service(tester, api);
    for (var id = 1; id <= 10; id++) {
      impression(analytics, id);
    }
    api.requests.first.completeError(StateError('offline'));
    await tester.pump();
    impression(analytics, 11);
    impression(analytics, 1, source: 'search');
    await tester.pump(const Duration(milliseconds: 999));
    expect(api.batches.length, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(api.batches.length, 2);
    expect(api.batches.last, api.batches.first);
    expect(analytics.events.length, 11);
    api.requests.last.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 14));
    expect(api.batches.last.single['properties']['deal_id'], 11);
    api.requests.last.complete();
    await tester.pump();
    await finish(tester, analytics);
  });

  testWidgets('closing cancels deadlines and ignores late request completion',
      (tester) async {
    final api = _AnalyticsApi();
    final analytics = service(tester, api);
    for (var id = 1; id <= 11; id++) {
      impression(analytics, id);
    }
    analytics.onClose();
    api.requests.first.complete();
    await tester.pump(const Duration(seconds: 30));
    expect(api.batches.length, 1);
    impression(analytics, 12);
    expect(analytics.events.length, 11);
  });

  testWidgets('exactly 50% qualifies at 1000 ms, not 999 ms', (tester) async {
    final analytics = service(tester);
    await tester.pumpWidget(clippedCard(visibleHeight: 50));
    await tester.pump(const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(analytics.events.single.properties,
        {'deal_id': 42, 'source': 'home_feed', 'position': 3});
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events.length, 1);
    final detector =
        tester.widget<VisibilityDetector>(find.byType(VisibilityDetector));
    expect(detector.onVisibilityChanged, isNull);
    await finish(tester, analytics);
  });

  testWidgets(
      'below 50% never qualifies; interrupted periods do not accumulate',
      (tester) async {
    final analytics = service(tester);
    await tester.pumpWidget(clippedCard(visibleHeight: 49));
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    await tester.pumpWidget(clippedCard(visibleHeight: 60));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(clippedCard(visibleHeight: 49));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(clippedCard(visibleHeight: 60));
    await tester.pump(const Duration(milliseconds: 600));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 400));
    expect(analytics.events.length, 1);
    await finish(tester, analytics);
  });

  testWidgets(
      'changes above 50% retain elapsed time and use current list index',
      (tester) async {
    final analytics = service(tester);
    await tester.pumpWidget(clippedCard(visibleHeight: 60));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(clippedCard(visibleHeight: 90, position: 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(analytics.events.single.properties['position'], 1);
    await finish(tester, analytics);
  });

  testWidgets('reused widget resets dwell for a different deal',
      (tester) async {
    final analytics = service(tester);
    await tester.pumpWidget(clippedCard());
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(clippedCard(id: 43));
    await tester.pump(const Duration(milliseconds: 400));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 600));
    expect(analytics.events.single.properties['deal_id'], 43);
    await finish(tester, analytics);
  });

  testWidgets('backgrounding resets dwell; resume requires a fresh second',
      (tester) async {
    final analytics = service(tester);
    await tester.pumpWidget(clippedCard());
    await tester.pump(const Duration(milliseconds: 600));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(analytics.events.length, 1);
    await finish(tester, analytics);
  });

  testWidgets('a covering popup cancels dwell even when geometry is unchanged',
      (tester) async {
    final analytics = service(tester);
    await tester.pumpWidget(clippedCard());
    await tester.pump(const Duration(milliseconds: 600));
    final context = tester.element(find.byType(DealImpressionTracker));
    unawaited(showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('Covered'))));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    expect(analytics.events.length, 1);
    await finish(tester, analytics);
  });

  testWidgets('simultaneous copies record only one source', (tester) async {
    final analytics = service(tester);
    await tester.pumpWidget(MaterialApp(
        home: Column(children: [
      for (final source in ['flash_rail', 'home_feed', 'search'])
        DealImpressionTracker(
            dealId: 42,
            source: source,
            position: 0,
            child: const SizedBox(width: 100, height: 100)),
    ])));
    await tester.pump(const Duration(seconds: 1));
    expect(analytics.events.length, 1);
    expect(analytics.events.single.properties['source'], 'flash_rail');
    await finish(tester, analytics);
  });

  testWidgets('visibility and qualification never rebuild the card child',
      (tester) async {
    final analytics = service(tester);
    var builds = 0;
    final child = _BuildCounter(() => builds++);
    await tester.pumpWidget(clippedCard(visibleHeight: 60, child: child));
    expect(builds, 1);
    for (final height in [70.0, 80.0, 90.0]) {
      await tester.pumpWidget(clippedCard(visibleHeight: height, child: child));
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(analytics.events.length, 1);
    expect(builds, 1);
    await finish(tester, analytics);
  });

  testWidgets('disposing before qualification cancels all card work',
      (tester) async {
    final analytics = service(tester);
    await tester.pumpWidget(clippedCard());
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    expect(VisibilityDetectorController.instance.debugUpdateCount, 0);
    analytics.onClose();
  });

  testWidgets('nested horizontal and vertical scrolling clips each card',
      (tester) async {
    final analytics = service(tester);
    final horizontal = ScrollController();
    final vertical = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 150,
          height: 100,
          child: SingleChildScrollView(
            controller: vertical,
            child: Column(children: [
              SizedBox(
                height: 100,
                child: SingleChildScrollView(
                  controller: horizontal,
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (var id = 1; id <= 3; id++)
                      DealImpressionTracker(
                        dealId: id,
                        source: 'flash_rail',
                        position: id - 1,
                        child: const SizedBox(width: 100, height: 100),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 300),
            ]),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(
        analytics.events.map((event) => event.properties['deal_id']), [1, 2]);
    horizontal.jumpTo(100);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    vertical.jumpTo(51); // Only 49% of the rail's height remains visible.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(analytics.events.length, 2);
    vertical.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 999));
    expect(analytics.events.length, 2);
    await tester.pump(const Duration(milliseconds: 1));
    expect(analytics.events.last.properties,
        {'deal_id': 3, 'source': 'flash_rail', 'position': 2});
    await finish(tester, analytics);
    horizontal.dispose();
    vertical.dispose();
  });
}
