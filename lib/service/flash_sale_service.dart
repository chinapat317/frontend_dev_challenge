import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// One clock for mounted countdowns and bag expiry, independent of routes.
/// Callbacks may run each second; consumers decide whether anything changed.
class FlashSaleService extends GetxService with WidgetsBindingObserver {
  FlashSaleService({DateTime Function()? now}) : now = now ?? DateTime.now;

  final DateTime Function() now;
  final _listeners = <Object, ({DateTime deadline, VoidCallback callback})>{};
  Timer? _timer;
  bool _paused = false;
  bool _notifying = false;
  bool _disposed = false;

  bool isExpired(DateTime? deadline) =>
      deadline != null && !now().isBefore(deadline);

  /// Returns an unsubscribe function. There is never a timer per card.
  VoidCallback watch(DateTime deadline, VoidCallback callback) {
    assert(!_disposed);
    final token = Object();
    _listeners[token] = (deadline: deadline, callback: callback);
    _schedule();
    return () {
      _listeners.remove(token);
      _schedule();
    };
  }

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
  }

  /// Reconcile against real instants after a suspended app resumes.
  void refresh() {
    if (_disposed) return;
    _notifying = true;
    try {
      for (final entry in _listeners.entries.toList()) {
        if (_listeners.containsKey(entry.key)) entry.value.callback();
      }
    } finally {
      _notifying = false;
      _schedule();
    }
  }

  void _schedule() {
    if (_notifying || _disposed) return;
    _timer?.cancel();
    _timer = null;
    if (_paused) return;
    final current = now();
    // Align second updates, but also wake at the exact nearest expiry.
    var delay = Duration(
      microseconds: Duration.microsecondsPerSecond -
          current.microsecondsSinceEpoch % Duration.microsecondsPerSecond,
    );
    var hasActiveDeadline = false;
    for (final listener in _listeners.values) {
      final remaining = listener.deadline.difference(current);
      if (remaining <= Duration.zero) continue;
      hasActiveDeadline = true;
      if (remaining < delay) delay = remaining;
    }
    if (hasActiveDeadline) _timer = Timer(delay, refresh);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (_paused) {
      _timer?.cancel();
      _timer = null;
    } else {
      refresh();
    }
  }

  @override
  void onClose() {
    _disposed = true;
    _timer?.cancel();
    _listeners.clear();
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}

String formatFlashSaleCountdown(DateTime deadline, DateTime now) {
  final micros = deadline.difference(now).inMicroseconds;
  if (micros <= 0) return 'Expired';
  // An active sale with a fraction of a second left must not show 00:00.
  final seconds = (micros / Duration.microsecondsPerSecond).ceil();
  String two(int value) => value.toString().padLeft(2, '0');
  final minutesAndSeconds = '${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
  return seconds >= 3600
      ? '${two(seconds ~/ 3600)}:$minutesAndSeconds'
      : minutesAndSeconds;
}
