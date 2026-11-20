import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:visibility_detector/visibility_detector.dart';

import 'app_config.dart';
import 'repository/deal_repo.dart';
import 'repository/order_repo.dart';
import 'repository/store_repo.dart';
import 'routes/routes.dart';
import 'service/analytics_service.dart';
import 'service/cart_service.dart';
import 'service/fake_api_service.dart';
import 'service/flash_sale_service.dart';
import 'service/impression_route_observer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Observe threshold interruptions at frame boundaries, not in 500 ms batches.
  VisibilityDetectorController.instance.updateInterval = Duration.zero;
  await initDependencies();
  runApp(const RescuApp());
}

Future<void> initDependencies() async {
  await Get.putAsync(() => FakeApiService().init(), permanent: true);
  Get.put(AnalyticsService(api: Get.find<FakeApiService>()), permanent: true);
  Get.put(FlashSaleService(), permanent: true);
  Get.put(OrderRepo(api: Get.find()), permanent: true);
  Get.put(CartService(flashSales: Get.find(), orderRepo: Get.find()),
      permanent: true);
  Get.lazyPut(() => DealRepo(api: Get.find()), fenix: true);
  Get.lazyPut(() => StoreRepo(api: Get.find()), fenix: true);
}

class RescuApp extends StatelessWidget {
  const RescuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppConfig.theme,
      initialRoute: Routes.home,
      getPages: Routes.pages,
      navigatorObservers: [impressionRouteObserver],
    );
  }
}
