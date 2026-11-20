import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/feature/home/widget/flash_deals_section.dart';
import 'package:rescu/feature/shared_widget/deal_card.dart';
import 'package:rescu/feature/shared_widget/deal_impression_tracker.dart';
import 'package:rescu/feature/shared_widget/the_network_image.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/flash_sale_service.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'support/analytics_api.dart';
import 'support/deal_fixture.dart';

class _ControlledImage extends ImageStreamCompleter {
  void load() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 100), Paint());
    final picture = recorder.endRecording();
    setImage(ImageInfo(image: picture.toImageSync(100, 100)));
    picture.dispose();
  }

  void fail() => reportError(exception: StateError('image unavailable'));
}

/// Seed the same resized cache key used by production. This exercises the real
/// CachedNetworkImage success/error builders without HTTP or decode timing.
Future<_ControlledImage> _prepareImage(String url, {int width = 100}) async {
  final provider =
      ResizeImage.resizeIfNeeded(width, null, CachedNetworkImageProvider(url));
  final key = await provider.obtainKey(ImageConfiguration.empty);
  final image = _ControlledImage();
  PaintingBinding.instance.imageCache.putIfAbsent(key, () => image);
  return image;
}

void main() {
  late AnalyticsService analytics;

  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    Get.reset();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    VisibilityDetectorController.instance.updateInterval =
        const Duration(milliseconds: 500);
  });

  void registerServices(WidgetTester tester) {
    analytics = Get.put(AnalyticsService(
        api: ImmediateAnalyticsApi(), now: tester.binding.clock.now));
    Get.put(FlashSaleService(now: tester.binding.clock.now));
  }

  Widget page(
          {String url = 'https://test/image', double visibleHeight = 100}) =>
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1),
          child: Align(
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
                    dealId: 42,
                    source: 'home_feed',
                    position: 0,
                    imageUrl: url,
                    child: TheNetworkImage(url: url, width: 100, height: 100),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    analytics.onClose();
  }

  testWidgets('visible placeholders wait for image rendering plus one second',
      (tester) async {
    registerServices(tester);
    final image = await _prepareImage('https://test/image');
    await tester.pumpWidget(page());
    await tester.pump(const Duration(seconds: 3));
    expect(analytics.events, isEmpty);
    image.load();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(analytics.events.single.name, 'deal_impression');
    await finish(tester);
  });

  testWidgets('failed images never qualify', (tester) async {
    registerServices(tester);
    final image = await _prepareImage('https://test/image');
    await tester.pumpWidget(page());
    image.fail();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
    expect(analytics.events, isEmpty);
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets('cached images still require one second of visibility',
      (tester) async {
    registerServices(tester);
    final image = await _prepareImage('https://test/image');
    image.load();
    await tester.pumpWidget(page());
    await tester.pump(const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(analytics.events.length, 1);
    await finish(tester);
  });

  testWidgets('an offscreen image load waits until the card becomes visible',
      (tester) async {
    registerServices(tester);
    final image = await _prepareImage('https://test/image');
    await tester.pumpWidget(page(visibleHeight: 49));
    image.load();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(analytics.events, isEmpty);
    await tester.pumpWidget(page(visibleHeight: 50));
    await tester.pump(const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(analytics.events.length, 1);
    await finish(tester);
  });

  testWidgets('a changed URL cancels dwell and waits for the new image',
      (tester) async {
    registerServices(tester);
    final first = await _prepareImage('https://test/image');
    final second = await _prepareImage('https://test/replacement');
    await tester.pumpWidget(page());
    first.load();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpWidget(page(url: 'https://test/replacement'));
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    second.load();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 999));
    expect(analytics.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(analytics.events.length, 1);
    await finish(tester);
  });

  testWidgets('late completion for a replaced image cannot qualify the card',
      (tester) async {
    registerServices(tester);
    final first = await _prepareImage('https://test/image');
    await _prepareImage('https://test/replacement');
    await tester.pumpWidget(page());
    await tester.pumpWidget(page(url: 'https://test/replacement'));
    first.load();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(analytics.events, isEmpty);
    await finish(tester);
  });

  for (final source in ['home_feed', 'search', 'flash_rail']) {
    testWidgets('$source integrates image readiness with real deal cards',
        (tester) async {
      registerServices(tester);
      final deal = dealFixture(
        endsAt: tester.binding.clock.now().add(const Duration(hours: 1)),
        imageUrl: 'https://test/$source',
      );
      // Full-width cards have 16 px margin on each side; rail cards have 4 px.
      final width = source == 'flash_rail' ? 192 : 400;
      final image = await _prepareImage(deal.imageUrl, width: width);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 1),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 432,
              child: source == 'flash_rail'
                  ? FlashDealsSection(deals: [deal])
                  : DealCard(deal: deal, source: source, position: 4),
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(seconds: 2));
      expect(analytics.events, isEmpty);
      final builds = <String, int>{};
      debugOnRebuildDirtyWidget = (element, _) {
        final type = element.widget.runtimeType.toString();
        builds.update(type, (count) => count + 1, ifAbsent: () => 1);
      };
      image.load();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(analytics.events.single.properties, {
        'deal_id': 42,
        'source': source,
        'position': source == 'flash_rail' ? 0 : 4,
      });
      for (final type in [
        'DealCard',
        'FlashDealsSection',
        'TheNetworkImage',
        'Obx'
      ]) {
        expect(builds[type] ?? 0, 0,
            reason: '$type must not rebuild for image-ready impressions');
      }
      debugOnRebuildDirtyWidget = null;
      await finish(tester);
    });
  }

  testWidgets('custom image builder retains display-sized decoding',
      (tester) async {
    registerServices(tester);
    final image = await _prepareImage('https://test/image');
    await tester.pumpWidget(page());
    image.load();
    await tester.pump();
    final rendered = tester.widget<Image>(find
        .descendant(
            of: find.byType(TheNetworkImage), matching: find.byType(Image))
        .last);
    expect(rendered.image, isA<ResizeImage>());
    expect((rendered.image as ResizeImage).width, 100);
    await finish(tester);
  });
}
