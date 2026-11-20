import 'package:get/get.dart';

import '../../repository/order_repo.dart';
import '../../service/api_exception.dart';
import '../../service/cart_service.dart';
import '../../util/log_service.dart';

class CartController extends GetxController {
  final CartService cartService;
  final OrderRepo orderRepo;

  CartController({required this.cartService, required this.orderRepo});

  RxBool get isCheckingOut => cartService.isCheckingOut;

  Future<void> checkout() async {
    final snapshot = cartService.beginCheckout();
    if (snapshot == null) return;
    try {
      final order = await orderRepo.checkout(snapshot);
      cartService.finishCheckout(purchased: true);
      Get.snackbar(
        'Order confirmed',
        'Order #${order.id} — pick up soon!',
        snackPosition: SnackPosition.BOTTOM,
      );
    } on ApiException catch (e) {
      LogService.error('checkout failed', e);
      cartService.finishCheckout(invalidate: e.statusCode == 410);
      Get.snackbar(
        e.statusCode == 410 ? 'Hold expired' : 'Checkout failed',
        e.statusCode == 410
            ? 'Your holds are no longer valid. Please add the deals again to reserve them before checkout.'
            : e.statusCode == 502
                ? 'Payment timed out. Your card was not charged. Please review your bag and try again.'
                : 'We couldn’t complete checkout. Please review your bag and try again.',
        snackPosition: SnackPosition.BOTTOM,
      );
    } catch (e) {
      LogService.error('checkout failed', e);
      Get.snackbar('Checkout failed',
          'We couldn’t confirm your order. Please check My orders before trying again.',
          snackPosition: SnackPosition.BOTTOM);
    } finally {
      cartService.finishCheckout();
    }
  }
}
