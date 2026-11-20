import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../service/flash_sale_service.dart';

/// Only this Text rebuilds on second changes, never its containing card.
class FlashSaleCountdown extends StatefulWidget {
  const FlashSaleCountdown({
    super.key,
    required this.endsAt,
    this.style,
    this.flashSales,
  });

  final DateTime endsAt;
  final TextStyle? style;
  final FlashSaleService? flashSales;

  @override
  State<FlashSaleCountdown> createState() => _FlashSaleCountdownState();
}

class _FlashSaleCountdownState extends State<FlashSaleCountdown> {
  late String _text;
  late VoidCallback _unsubscribe;

  void _subscribe() {
    final service = widget.flashSales ?? Get.find<FlashSaleService>();
    String text() => formatFlashSaleCountdown(widget.endsAt, service.now());
    _text = text();
    _unsubscribe = service.watch(widget.endsAt, () {
      final next = text();
      if (next != _text) setState(() => _text = next);
    });
  }

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(FlashSaleCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.endsAt != widget.endsAt ||
        oldWidget.flashSales != widget.flashSales) {
      _unsubscribe();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(_text, style: widget.style);
}

/// Rebuilds its boundary only when availability changes, not every second.
class FlashSaleState extends StatefulWidget {
  const FlashSaleState({
    super.key,
    required this.endsAt,
    required this.builder,
    this.child,
    this.flashSales,
  });

  final DateTime? endsAt;
  final Widget Function(bool expired, Widget? child) builder;
  final Widget? child;
  final FlashSaleService? flashSales;

  @override
  State<FlashSaleState> createState() => _FlashSaleStateState();
}

class _FlashSaleStateState extends State<FlashSaleState> {
  bool _expired = false;
  VoidCallback? _unsubscribe;

  void _subscribe() {
    final deadline = widget.endsAt;
    _expired = false;
    if (deadline == null) return;
    final service = widget.flashSales ?? Get.find<FlashSaleService>();
    _expired = service.isExpired(deadline);
    _unsubscribe = service.watch(deadline, () {
      final next = service.isExpired(deadline);
      if (next != _expired) setState(() => _expired = next);
    });
  }

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(FlashSaleState oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.endsAt != widget.endsAt ||
        oldWidget.flashSales != widget.flashSales) {
      _unsubscribe?.call();
      _unsubscribe = null;
      _subscribe();
    }
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(_expired, widget.child);
}

/// Retains the expensive card subtree while changing its disabled appearance.
class FlashSaleCardState extends StatelessWidget {
  const FlashSaleCardState({
    super.key,
    required this.endsAt,
    required this.child,
  });

  final DateTime? endsAt;
  final Widget child;

  @override
  Widget build(BuildContext context) => FlashSaleState(
        endsAt: endsAt,
        child: child,
        builder: (expired, child) => Semantics(
          enabled: !expired,
          child: ExcludeFocus(
            excluding: expired,
            child: IgnorePointer(
              ignoring: expired,
              child: Opacity(opacity: expired ? 0.5 : 1, child: child),
            ),
          ),
        ),
      );
}
