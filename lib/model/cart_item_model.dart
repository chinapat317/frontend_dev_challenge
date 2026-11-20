import 'deal_model.dart';
import 'reservation_model.dart';

class CartItemModel {
  final DealModel deal;
  final List<CartUnitModel> units;

  CartItemModel({required this.deal, required Iterable<CartUnitModel> units})
      : units = List.unmodifiable(units);

  int get quantity => units.length;
  int get pendingCount =>
      units.where((unit) => unit.reservation == null).length;

  DateTime? get nextExpiry {
    DateTime? next;
    for (final unit in units) {
      final deadline = unit.reservation?.expiresAt;
      if (deadline != null && (next == null || deadline.isBefore(next))) {
        next = deadline;
      }
    }
    return next;
  }

  num get lineTotal => deal.price * quantity;
}

/// One optimistic addition. Its identity survives confirmation, so late API
/// responses can never restore a removed unit or overwrite another addition.
class CartUnitModel {
  final Object token;
  final ReservationModel? reservation;

  const CartUnitModel({required this.token, this.reservation});
}
