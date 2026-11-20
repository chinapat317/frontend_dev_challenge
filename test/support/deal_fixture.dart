import 'package:rescu/model/deal_model.dart';

DealModel dealFixture(
        {int id = 42,
        DateTime? endsAt,
        int quantity = 3,
        String imageUrl = ''}) =>
    DealModel.fromJson({
      'id': id,
      'imageUrl': imageUrl,
      'name': 'Deal $id',
      'storeName': 'Bakery',
      'quantityLeft': quantity,
      'price': 20,
      'originalPrice': 50,
      'flashSaleEndsAt': endsAt?.toUtc().toIso8601String(),
      'pickupWindow': {
        'start': '2026-11-20T00:00:00Z',
        'end': '2026-11-20T02:30:00Z',
      },
    });
