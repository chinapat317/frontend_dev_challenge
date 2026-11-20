import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:rescu/main.dart';
import 'package:rescu/repository/deal_repo.dart';
import 'package:rescu/repository/order_repo.dart';
import 'package:rescu/repository/store_repo.dart';
import 'package:rescu/service/analytics_service.dart';
import 'package:rescu/service/cart_service.dart';
import 'package:rescu/service/fake_api_service.dart';
import 'package:rescu/service/flash_sale_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => Get.reset());

  test('real app bootstrap resolves all services and lazy repositories',
      () async {
    // Exercise production wiring, rather than registering test replacements.
    await initDependencies();

    final api = Get.find<FakeApiService>();
    expect(Get.find<AnalyticsService>(), isA<AnalyticsService>());
    expect(
        Get.find<CartService>().flashSales, same(Get.find<FlashSaleService>()));
    expect(Get.find<DealRepo>().api, same(api));
    expect(Get.find<StoreRepo>().api, same(api));
    expect(Get.find<OrderRepo>().api, same(api));
    expect(Get.find<CartService>().orderRepo, same(Get.find<OrderRepo>()));
  });
}
