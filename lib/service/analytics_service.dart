import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../util/log_service.dart';
import 'fake_api_service.dart';

class AnalyticsEvent {
  final String name;
  final Map<String, dynamic> properties;
  final DateTime at;

  AnalyticsEvent(this.name, Map<String, dynamic> properties, {DateTime? at})
      : properties = Map.unmodifiable(properties),
        at = at ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'name': name,
        'properties': properties,
        'at': at.toIso8601String(),
      };
}

/// Session-wide recording, impression deduplication and batched delivery.
/// Debug history is independent of the unsent queue and remains after delivery.
class AnalyticsService extends GetxService with WidgetsBindingObserver {
  AnalyticsService({FakeApiService? api, DateTime Function()? now})
      : _api = api ?? FakeApiService(),
        _now = now ?? DateTime.now;

  final FakeApiService _api;
  final DateTime Function() _now;
  final events = <AnalyticsEvent>[].obs;
  final _impressedDeals = <int>{};
  final _pending = <AnalyticsEvent>[];
  Timer? _flushTimer;
  bool _sending = false;
  bool _closed = false;
  DateTime? _retryAt;
  int _failures = 0;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
  }

  bool hasImpression(int dealId) => _impressedDeals.contains(dealId);

  /// Claim before doing any asynchronous work, including across placements.
  bool recordDealImpression({
    required int dealId,
    required String source,
    required int position,
  }) {
    if (_closed || !_impressedDeals.add(dealId)) return false;
    logEvent('deal_impression', {
      'deal_id': dealId,
      'source': source,
      'position': position,
    });
    return true;
  }

  void logEvent(String name, [Map<String, dynamic> properties = const {}]) {
    if (_closed) return;
    final event = AnalyticsEvent(name, properties, at: _now());
    events.add(event);
    _pending.add(event);
    LogService.log('analytics: $name $properties');
    _schedule();
  }

  void _schedule() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_closed || _sending || _pending.isEmpty) return;

    final now = _now();
    final retryAt = _retryAt;
    final deadline = retryAt ??
        (_pending.length >= 10
            ? now
            : _pending.first.at.add(const Duration(seconds: 15)));
    final delay = deadline.difference(now);
    if (delay <= Duration.zero) {
      unawaited(_flush());
    } else {
      _flushTimer = Timer(delay, () => unawaited(_flush()));
    }
  }

  Future<void> _flush() async {
    if (_closed || _sending || _pending.isEmpty) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _sending = true;
    // New arrivals append behind this immutable request snapshot.
    final batch = _pending.take(10).map((event) => event.toJson()).toList();
    try {
      await _api.sendAnalyticsBatch(batch);
      if (_closed) return;
      _pending.removeRange(0, batch.length);
      _failures = 0;
      _retryAt = null;
    } catch (error) {
      if (_closed) return;
      LogService.error(
          'analytics batch failed; retaining events for retry', error);
      // 1, 2, 4, 8, 16, then 30 seconds. New events cannot bypass backoff.
      _failures++;
      final seconds = _failures > 5 ? 30 : 1 << (_failures - 1);
      _retryAt = _now().add(Duration(seconds: seconds));
    } finally {
      _sending = false;
      _schedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Timers may have been suspended. Keep the original oldest-event deadline.
    if (state == AppLifecycleState.resumed) _schedule();
  }

  @override
  void onClose() {
    _closed = true;
    _flushTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}
