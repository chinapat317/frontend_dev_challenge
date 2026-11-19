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

  String _query = '';

  void onQueryChanged(String query) {
    _query = query;
    _search(query);
  }

  Future<void> _search(String query) async {
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
      if (query != _query) return;
      results.assignAll(response);
    } catch (e) {
      if (query == _query) {
        LogService.error('search failed', e);
      }
    } finally {
      if (query == _query) {
        isLoading.value = false;
      }
    }
  }
}
