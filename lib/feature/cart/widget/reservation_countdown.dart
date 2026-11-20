import 'package:flutter/material.dart';

import '../../../service/flash_sale_service.dart';
import '../../shared_widget/flash_sale_countdown.dart';

/// Shares the app clock; only the countdown text rebuilds on second ticks.
class ReservationCountdown extends StatelessWidget {
  const ReservationCountdown({
    super.key,
    required this.expiresAt,
    required this.clock,
    required this.multiple,
  });

  final DateTime expiresAt;
  final FlashSaleService clock;
  final bool multiple;

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
        style: TextStyle(fontSize: 12, color: Colors.orange.shade900),
        child: Wrap(
          children: [
            Text(multiple ? 'Next hold expires in ' : 'Hold expires in '),
            FlashSaleCountdown(endsAt: expiresAt, flashSales: clock),
          ],
        ),
      );
}
