import 'package:rescu/model/reservation_model.dart';
import 'package:rescu/repository/order_repo.dart';
import 'package:rescu/service/fake_api_service.dart';

/// Immediate holds for tests whose subject is outside the reservation lifecycle.
class ImmediateReservationRepo extends OrderRepo {
  ImmediateReservationRepo({DateTime Function()? now})
      : now = now ?? DateTime.now,
        super(api: FakeApiService());

  final DateTime Function() now;
  int _sequence = 0;

  @override
  Future<ReservationModel> reserve(int dealId, {int quantity = 1}) async =>
      ReservationModel(
        id: 'test_${++_sequence}',
        dealId: dealId,
        quantity: quantity,
        expiresAt: now().add(const Duration(minutes: 5)),
      );

  @override
  Future<void> releaseReservation(String reservationId) async {}
}
