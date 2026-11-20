import 'package:get/get.dart';

import '../../model/deal_model.dart';
import '../../repository/deal_repo.dart';
import '../../service/analytics_service.dart';
import '../../service/api_exception.dart';
import '../../service/cart_service.dart';
import '../../util/log_service.dart';

class DealDetailsController extends GetxController {
  final DealRepo dealRepo;
  final CartService cartService;
  final AnalyticsService analytics;

  DealDetailsController({
    required this.dealRepo,
    required this.cartService,
    required this.analytics,
  });

  final _deal = Rxn<DealModel>();
  DealModel? get deal => _deal.value;

  final isLoading = false.obs;
  final error = RxnString();
  late final int? _dealId;
  late final String _source;

  final _quantityLeft = RxnInt();
  int? get quantityLeft => _quantityLeft.value;

  Worker? _cartCounter;
  @override
  void onInit() {
    super.onInit();
    // Capture route parameters before awaiting: another route can change them.
    _dealId = int.tryParse(Get.parameters['id'] ?? '');
    _source = Get.parameters['source'] ?? 'unknown';
    loadDeal();
  }

  Future<void> loadDeal() async {
    if (isClosed || isLoading.value) return;
    final id = _dealId;
    if (id == null || id <= 0) {
      error.value = 'This deal link is invalid.';
      return;
    }

    isLoading.value = true;
    error.value = null;
    try {
      final loadedDeal = await dealRepo.fetchById(id);
      if (isClosed) return;
      _quantityLeft.value = loadedDeal.quantityLeft;
      _deal.value = loadedDeal;
      analytics.logEvent('deal_details_view', {
        'deal_id': loadedDeal.id,
        'source': _source,
      });
      // Only watch cart changes once a deal is ready.
      _cartCounter ??=
          ever(cartService.itemCount, (_) => _recheckAvailability());
    } on ApiException catch (e) {
      if (isClosed) return;
      error.value = e.statusCode == 404
          ? 'This deal is no longer available.'
          : 'Could not load this deal. Please try again.';
    } catch (e) {
      if (isClosed) return;
      LogService.log('loading deal $id failed: $e');
      error.value = 'Could not load this deal. Please try again.';
    } finally {
      if (!isClosed) isLoading.value = false;
    }
  }

  @override
  void onClose() {
    _cartCounter?.dispose();
    super.onClose();
  }

  Future<void> _recheckAvailability() async {
    final deal = this.deal;
    if (isClosed || deal == null) return;
    LogService.log('re-checking availability for deal ${deal.id}');
    try {
      final fresh = await dealRepo.fetchById(deal.id);
      if (isClosed) return;
      _quantityLeft.value = fresh.quantityLeft;
    } catch (e) {
      LogService.log('re-checking availability for deal ${deal.id} failed: $e');
    }
  }

  void addToCart() {
    final deal = this.deal;
    if (isClosed || deal == null) return;
    cartService.add(deal);
    Get.snackbar(
      'Added to bag',
      '${deal.name} — pick up ${deal.pickupWindow.label}',
      snackPosition: SnackPosition.BOTTOM,
      duration: const Duration(seconds: 2),
    );
  }
}
