import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../service/analytics_service.dart';
import '../../service/impression_route_observer.dart';
import 'the_network_image.dart';

/// Visibility changes only touch fields/timers. The expensive child is retained
/// even when this boundary rebuilds once to turn off a completed detector.
class DealImpressionTracker extends StatefulWidget {
  const DealImpressionTracker({
    super.key,
    required this.dealId,
    required this.source,
    required this.position,
    required this.child,
    this.imageUrl,
  });

  final int dealId;
  final String source;
  final int position;
  final Widget child;

  /// If present, qualification waits for this image's first decoded frame.
  final String? imageUrl;

  @override
  State<DealImpressionTracker> createState() => _DealImpressionTrackerState();
}

class _DealImpressionTrackerState extends State<DealImpressionTracker>
    with WidgetsBindingObserver, RouteAware {
  // A deal can appear in multiple routes/placements at the same time.
  final _detectorKey = UniqueKey();
  late final AnalyticsService _analytics;
  ModalRoute<dynamic>? _route;
  Timer? _timer;
  double _visibleFraction = 0;
  bool _foreground = true;
  bool _completed = false;
  late bool _imageReady;

  bool get _eligible =>
      mounted &&
      !_completed &&
      _imageReady &&
      _foreground &&
      (_route?.isCurrent ?? true) &&
      _visibleFraction >= 0.5;

  @override
  void initState() {
    super.initState();
    _analytics = Get.find<AnalyticsService>();
    _completed = _analytics.hasImpression(widget.dealId);
    _imageReady = widget.imageUrl == null;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route == route) return;
    _cancel();
    impressionRouteObserver.unsubscribe(this);
    _route = route;
    if (route != null) impressionRouteObserver.subscribe(this, route);
  }

  @override
  void didUpdateWidget(DealImpressionTracker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dealId != widget.dealId ||
        oldWidget.source != widget.source ||
        oldWidget.imageUrl != widget.imageUrl) {
      _cancel();
      if (oldWidget.imageUrl != widget.imageUrl) {
        _imageReady = widget.imageUrl == null;
      }
      _completed = _analytics.hasImpression(widget.dealId);
      _recheckAfterFrame();
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    _visibleFraction = info.visibleFraction;
    _evaluate();
  }

  bool _onImageLoaded(NetworkImageLoadedNotification notification) {
    if (notification.url != widget.imageUrl) return false;
    if (!_imageReady) {
      _imageReady = true;
      _evaluate();
    }
    return true;
  }

  void _evaluate() {
    if (_completed) return;
    if (_analytics.hasImpression(widget.dealId)) {
      _finish();
    } else if (!_eligible) {
      _cancel();
    } else {
      // Do not restart on changes that remain above the threshold.
      _timer ??= Timer(const Duration(seconds: 1), () {
        _timer = null;
        // Flush pending geometry before accepting the last known fraction.
        VisibilityDetectorController.instance.notifyNow();
        if (!_eligible) return;
        _analytics.recordDealImpression(
          dealId: widget.dealId,
          source: widget.source,
          position: widget.position,
        );
        _finish();
      });
    }
  }

  void _finish() {
    _cancel();
    if (!mounted || _completed) return;
    setState(() => _completed = true);
  }

  void _recheckAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      VisibilityDetectorController.instance.notifyNow();
      _evaluate();
    });
  }

  @override
  void didPush() => _recheckAfterFrame();

  @override
  void didPopNext() => _recheckAfterFrame();

  @override
  void didPushNext() => _cancel();

  @override
  void didPop() => _cancel();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _cancel();
    if (_foreground) _recheckAfterFrame();
  }

  @override
  void deactivate() {
    _cancel();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _recheckAfterFrame();
  }

  @override
  void dispose() {
    _cancel();
    impressionRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    VisibilityDetectorController.instance.forget(_detectorKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => VisibilityDetector(
        key: _detectorKey,
        onVisibilityChanged: _completed ? null : _onVisibilityChanged,
        child: NotificationListener<NetworkImageLoadedNotification>(
          onNotification: _onImageLoaded,
          child: widget.child,
        ),
      );
}
