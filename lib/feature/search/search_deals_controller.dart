import 'package:get/get.dart';

import '../../model/deal_model.dart';
import '../../repository/deal_repo.dart';
import '../../util/log_service.dart';

class SearchDealsController extends GetxController {
  final DealRepo dealRepo;

  SearchDealsController({required this.dealRepo});

  final results = <DealModel>[].obs;
  final isLoading = false.obs;
  final hasSearched = false.obs;

  int _requestId = 0;

  void onQueryChanged(String query) {
    if (isClosed) return;
    _search(query, ++_requestId);
  }

  Future<void> _search(String query, int requestId) async {
    if (query.trim().isEmpty) {
      results.clear();
      hasSearched.value = false;
      isLoading.value = false;
      return;
    }
    isLoading.value = true;
    hasSearched.value = true;
    try {
      final response = await dealRepo.search(query);
      if (isClosed || requestId != _requestId) return;
      results.assignAll(response);
    } catch (e) {
      if (!isClosed && requestId == _requestId) {
        LogService.error('search failed', e);
      }
    } finally {
      if (!isClosed && requestId == _requestId) {
        isLoading.value = false;
      }
    }
  }
}
