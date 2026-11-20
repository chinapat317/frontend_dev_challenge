import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:pull_to_refresh/pull_to_refresh.dart';

import '../../model/deal_model.dart';
import '../../repository/deal_repo.dart';
import '../../util/log_service.dart';

class HomeController extends GetxController with WidgetsBindingObserver {
  final DealRepo dealRepo;
  final DateTime Function() _now;

  HomeController({required this.dealRepo, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  Timer? _midnightTimer;
  DateTime? _lastActiveDate;

  final deals = <DealModel>[].obs;
  final flashDeals = <DealModel>[].obs;
  final isLoading = true.obs;
  final todayOnly = false.obs;
  final showScrollToTop = false.obs;

  final scrollController = ScrollController();
  final refreshController = RefreshController();

  int _page = 1;
  int _nextPage = 2;
  int _totalPages = 1;
  bool _isFetchingMore = false;
  bool _isRefresh = false;

  bool get hasMore => _page < _totalPages;

  List<DealModel> get visibleDeals => todayOnly.value
      ? deals.where((d) => d.pickupWindow.isToday).toList()
      : deals.toList();

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    _checkDateAndScheduleRefresh();
    scrollController.addListener(_onScroll);
    _initialLoad();
  }

  void _checkDateAndScheduleRefresh() {
    if (isClosed) return;
    _midnightTimer?.cancel();
    final now = _now().toLocal();
    final today = DateUtils.dateOnly(now);
    if (_lastActiveDate != null && _lastActiveDate != today) {
      unawaited(_initialLoad());
    }
    _lastActiveDate = today;
    // Use local calendar midnight, including days shorter or longer than 24h.
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _midnightTimer =
        Timer(nextMidnight.difference(now), _checkDateAndScheduleRefresh);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkDateAndScheduleRefresh();
    }
  }

  void _onScroll() {
    final shouldShow = scrollController.offset > 800;
    if (showScrollToTop.value != shouldShow) {
      showScrollToTop.value = shouldShow;
    }
  }

  Future<void> _initialLoad() async {
    isLoading.value = true;
    try {
      await Future.wait([refreshDeals(), _loadFlashDeals()]);
    } catch (e) {
      LogService.error('initial load failed', e);
    }
    if (!isClosed) isLoading.value = false;
  }

  Future<void> _loadFlashDeals() async {
    final result = await dealRepo.fetchFlashDeals();
    if (!isClosed) flashDeals.assignAll(result);
  }

  Future<void> refreshDeals() async {
    if (_isRefresh || isClosed) return;
    _isRefresh = true;
    // Requests started before this refresh no longer belong to the feed.
    try {
      final res = await dealRepo.fetchDeals(page: 1);
      if (isClosed) return;
      _totalPages = res.totalPages;
      deals.assignAll(res.items);
      _page = 1;
      _nextPage = _page + 1;
      refreshController.refreshCompleted(resetFooterState: true);
    } catch (e) {
      if (isClosed) return;
      LogService.error('refreshDeals failed', e);
      refreshController.refreshFailed();
    } finally {
      _isRefresh = false;
    }
  }

  Future<void> loadMore() async {
    if (_isRefresh || _isFetchingMore || isClosed) return;
    if (!hasMore) {
      refreshController.loadNoData();
      return;
    }
    _isFetchingMore = true;
    _nextPage = _page + 1;
    _page = _nextPage;
    bool isFailed = false;
    try {
      final res = await dealRepo.fetchDeals(page: _nextPage);
      if (isClosed || _page != _nextPage) return;
      _totalPages = res.totalPages;
      deals.addAll(res.items);
    } catch (e) {
      if (isClosed || _nextPage != _page) return;
      _page = _nextPage - 1;
      LogService.error('loadMore failed', e);
      isFailed = true;
    } finally {
        _isFetchingMore = false;
        if(isFailed){
          refreshController.loadFailed();
        }
        else{
          refreshController.loadComplete();
        }
      }
  }

  void scrollToTop() {
    scrollController.animateTo(0,
        duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
  }

  @override
  void onClose() {
    _midnightTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    scrollController.dispose();
    refreshController.dispose();
    super.onClose();
  }
}
