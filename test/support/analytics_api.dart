import 'package:rescu/service/fake_api_service.dart';

/// Keep unrelated widget tests independent of the backend's latency timers.
class ImmediateAnalyticsApi extends FakeApiService {
  @override
  Future<void> sendAnalyticsBatch(List<Map<String, dynamic>> events) async {}
}
