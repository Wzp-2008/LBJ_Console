import 'dart:math' as math;
import 'dart:isolate';
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../models/merged_record.dart';
import '../services/database_service.dart';
import '../services/records_feed.dart';
import '../models/train_record.dart';
import '../models/map_state.dart';
import '../services/map_state_service.dart';

class HistoryScreen extends StatefulWidget {
  final Function(bool isEditing) onEditModeChanged;
  final Function() onSelectionChanged;

  const HistoryScreen({
    super.key,
    required this.onEditModeChanged,
    required this.onSelectionChanged,
  });

  @override
  HistoryScreenState createState() => HistoryScreenState();
}

class HistoryScreenState extends State<HistoryScreen> {
  static const int _batchSize = 100;
  static const double _scrollThreshold = 200.0;
  static const int _searchDebounceMs = 300;
  static const int _minVisibleItems = 15;

  final List<Object> _displayItems = [];
  bool _isInitialLoading = true;
  bool _isLoadingMore = false;
  bool _isSearchRefreshing = false;
  bool _hasMoreRecords = true;
  // Keyset cursor for the non-search path (null = first page). Replaces the
  // old offset counter for the main list, fixing the offset/dedup drift bug
  // on a live stream. [_currentOffset] is now search-only.
  PageCursor? _displayCursor;
  int _currentOffset = 0;
  bool _isEditMode = false;
  final Set<String> _selectedRecords = {};
  final Map<String, bool> _expandedStates = {};
  final Map<String, bool> _mergedDetailsLoading = {};
  /// groupKeys whose last [_loadMergedDetails] attempt threw. Caps the
  /// build-triggered self-heal in [_buildMergedRecordCard] to a single
  /// attempt per need-state so a persistently-failing DB query cannot
  /// busy-loop. Cleared on a manual expand-tap so the user can retry.
  final Set<String> _mergedDetailsLoadFailed = {};
  final ScrollController _scrollController = ScrollController();
  bool _isAtTop = true;
  String? _displaySettingsSignature;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ValueNotifier<bool> _searchRefreshingNotifier = ValueNotifier(false);
  final ValueNotifier<int?> _searchCountNotifier = ValueNotifier(null);
  final ValueNotifier<int?> _searchLoadedCountNotifier = ValueNotifier(null);
  String _searchQuery = '';
  int? _searchTotalCount;
  Timer? _searchDebounce;
  Timer? _scrollLoadDebounce;
  int _searchGeneration = 0;

  StreamSubscription? _recordDeleteSubscription;
  StreamSubscription? _settingsSubscription;

  final Map<String, double> _mapOptimalZoom = {};
  final Map<String, bool> _mapCalculating = {};

  LatLng? _currentUserLocation;
  bool _isLocationPermissionGranted = false;
  Timer? _locationTimer;

  int getSelectedCount() => _selectedRecords.length;
  Set<String> getSelectedRecordIds() => _selectedRecords;
  void clearSelection() => setState(() => _selectedRecords.clear());

  void setEditMode(bool isEditing) {
    setState(() {
      _isEditMode = isEditing;
      widget.onEditModeChanged(isEditing);
      if (!isEditing) {
        _selectedRecords.clear();
      }
    });
  }

  Future<void> reloadRecords() async {
    await _loadFirstPage();
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadFirstPage();
        _startLocationUpdates();
        _setupRecordDeleteListener();
        _setupSettingsListener();
      }
    });
  }

  String _displaySettingsSignatureFrom(Map<String, dynamic> settingsMap) {
    return [
      settingsMap['mergeRecordsEnabled'] ?? 0,
      settingsMap['hideUngroupableRecords'] ?? 0,
    ].join('|');
  }

  void _setupSettingsListener() {
    _settingsSubscription =
        DatabaseService.instance.onSettingsChanged((settings) {
      if (!mounted) return;
      final signature = _displaySettingsSignatureFrom(settings);
      if (signature == _displaySettingsSignature) return;
      _displaySettingsSignature = signature;
      _loadFirstPage();
    });
  }

  void _setupRecordDeleteListener() {
    _recordDeleteSubscription =
        DatabaseService.instance.onRecordDeleted((deletedIds) {
      if (!mounted) return;
      for (final id in deletedIds) {
        _selectedRecords.remove(id);
        _expandedStates.remove(id);
      }
      _loadFirstPage();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _locationTimer?.cancel();
    _searchDebounce?.cancel();
    _scrollLoadDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _searchRefreshingNotifier.dispose();
    _searchCountNotifier.dispose();
    _searchLoadedCountNotifier.dispose();
    _recordDeleteSubscription?.cancel();
    _settingsSubscription?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.atEdge && position.pixels == 0) {
      _isAtTop = true;
    } else {
      _isAtTop = false;
    }
    if (position.pixels >= position.maxScrollExtent - _scrollThreshold) {
      _scrollLoadDebounce?.cancel();
      _scrollLoadDebounce = Timer(const Duration(milliseconds: 80), () {
        if (mounted) _loadNextPage();
      });
    }
  }

  bool _computeHasMore({required int lastBatchSize}) {
    if (lastBatchSize < _batchSize) return false;
    if (_searchQuery.isNotEmpty && _searchTotalCount != null) {
      return _currentOffset < _searchTotalCount!;
    }
    return true;
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final trimmed = value.trim();
    _searchDebounce = Timer(const Duration(milliseconds: _searchDebounceMs), () async {
      if (!mounted) return;
      if (_searchQuery != trimmed) {
        final retainFocus = trimmed.isEmpty && _searchFocusNode.hasFocus;
        _searchQuery = trimmed;
        if (trimmed.isNotEmpty) {
          await _loadFirstPage(keepStaleResults: true);
        } else {
          await _loadFirstPage(keepStaleResults: false);
        }
        if (retainFocus && mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_searchFocusNode.hasFocus) {
              _searchFocusNode.requestFocus();
            }
          });
        }
      }
    });
  }

  Future<void> _loadFirstPage({bool keepStaleResults = false}) async {
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    final query = _searchQuery;

    if (keepStaleResults) {
      _currentOffset = 0;
      _searchTotalCount = null;
      _hasMoreRecords = true;
      _isSearchRefreshing = true;
      _searchRefreshingNotifier.value = true;
    } else {
      setState(() {
        _isInitialLoading = _displayItems.isEmpty;
        _isLoadingMore = false;
        _isSearchRefreshing = false;
        _displayItems.clear();
        _currentOffset = 0;
        _displayCursor = null;
        _searchTotalCount = null;
        _hasMoreRecords = true;
        // A full reload replaces every instance with a fresh one — give each
        // expanded merged card a fresh detail-load attempt even if a prior
        // attempt failed (transient DB error / short result).
        _mergedDetailsLoadFailed.clear();
      });
      _searchRefreshingNotifier.value = false;
      _searchCountNotifier.value = null;
      _searchLoadedCountNotifier.value = null;
    }

    try {
      final settingsMap = await DatabaseService.instance.getAllSettings() ?? {};
      _displaySettingsSignature = _displaySettingsSignatureFrom(settingsMap);

      if (query.isNotEmpty) {
        if (!keepStaleResults) {
          _searchRefreshingNotifier.value = true;
        }
        _searchCountNotifier.value = null;
        _searchLoadedCountNotifier.value = null;

        final items = await RecordsFeed.fetchSearchPage(
          query: query,
          limit: _batchSize,
          offset: 0,
        );
        if (!mounted || generation != _searchGeneration || query != _searchQuery) {
          return;
        }

        final total = await RecordsFeed.countSearch(query);
        if (!mounted || generation != _searchGeneration || query != _searchQuery) {
          return;
        }

        setState(() {
          _displayItems
            ..clear()
            ..addAll(items);
          _isInitialLoading = false;
          _isSearchRefreshing = false;
          _searchTotalCount = total;
          _currentOffset = items.length;
          _hasMoreRecords = _computeHasMore(lastBatchSize: items.length);
        });
        _searchRefreshingNotifier.value = false;
        _searchCountNotifier.value = total;
        _searchLoadedCountNotifier.value = _currentOffset;
        _ensureEnoughContent();
        return;
      }

      final result = await RecordsFeed.fetchPage(
        limit: _batchSize,
        cursor: null,
      );
      if (!mounted || generation != _searchGeneration) return;

      setState(() {
        _displayItems
          ..clear()
          ..addAll(result.items);
        _isInitialLoading = false;
        _isSearchRefreshing = false;
        _searchTotalCount = null;
        _displayCursor = result.nextCursor;
        _hasMoreRecords = result.nextCursor != null;
      });
      _searchRefreshingNotifier.value = false;
      _searchCountNotifier.value = null;
      _searchLoadedCountNotifier.value = null;
      _ensureEnoughContent();
    } catch (e) {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _isInitialLoading = false;
          _isSearchRefreshing = false;
        });
        _searchRefreshingNotifier.value = false;
      }
    }
  }

  Future<void> _loadNextPage() async {
    if (_isLoadingMore || !_hasMoreRecords) return;
    setState(() => _isLoadingMore = true);
    final generation = _searchGeneration;
    final isSearch = _searchQuery.isNotEmpty;

    try {
      if (isSearch) {
        final page = await RecordsFeed.fetchSearchPage(
          query: _searchQuery,
          limit: _batchSize,
          offset: _currentOffset,
        );
        if (!mounted || generation != _searchGeneration) return;

        // New records arriving at the top shift offsets; drop duplicates.
        final existing = _displayItemIdentities(_displayItems);
        final fresh = page
            .where((item) => !existing.contains(_displayItemIdentity(item)))
            .toList();

        setState(() {
          _displayItems.addAll(fresh);
          _currentOffset += page.length;
          _hasMoreRecords = _computeHasMore(lastBatchSize: page.length);
          _isLoadingMore = false;
        });
        _searchLoadedCountNotifier.value = _currentOffset;
        _ensureEnoughContent();
        return;
      }

      // Keyset: fetch strictly after the last shown item. New live records
      // land above the cursor, so they never re-appear on the next page —
      // this is what keeps the list growing with fresh (post-merge) items
      // instead of stalling on already-shown groups.
      final result = await RecordsFeed.fetchPage(
        limit: _batchSize,
        cursor: _displayCursor,
      );
      if (!mounted || generation != _searchGeneration) return;

      final existing = _displayItemIdentities(_displayItems);
      final fresh = result.items
          .where((item) => !existing.contains(_displayItemIdentity(item)))
          .toList();

      setState(() {
        _displayItems.addAll(fresh);
        _displayCursor = result.nextCursor;
        _hasMoreRecords = result.nextCursor != null;
        _isLoadingMore = false;
      });
      _ensureEnoughContent();
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  String _displayItemIdentity(Object item) {
    if (item is TrainRecord) return 't:${item.uniqueId}';
    if (item is MergedTrainRecord) return 'm:${item.groupKey}';
    return 'x:${item.hashCode}';
  }

  Set<String> _displayItemIdentities(List<Object> items) {
    return items.map(_displayItemIdentity).toSet();
  }

  void _ensureEnoughContent() {
    if (!_hasMoreRecords || _isLoadingMore) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final searchNeedsMore = _searchQuery.isNotEmpty &&
          _searchTotalCount != null &&
          _currentOffset < _searchTotalCount!;
      final needsMore = position.maxScrollExtent <= 0 ||
          _displayItems.length < _minVisibleItems ||
          (searchNeedsMore && _displayItems.length < _searchTotalCount!);
      if (needsMore) {
        _loadNextPage();
      }
    });
  }

  void _removeIntersectingItems(Object newItem) {
    final memberIds = newItem is MergedTrainRecord
        ? newItem.memberUniqueIds.toSet()
        : {(newItem as TrainRecord).uniqueId};
    final identity = _displayItemIdentity(newItem);
    _displayItems.removeWhere((existing) {
      if (_displayItemIdentity(existing) == identity) return true;
      if (existing is TrainRecord) return memberIds.contains(existing.uniqueId);
      if (existing is MergedTrainRecord) {
        return existing.memberUniqueIds.any(memberIds.contains);
      }
      return false;
    });
  }

  Future<void> addNewRecord(TrainRecord newRecord) async {
    try {
      if (!mounted || _searchQuery.isNotEmpty) return;

      // The record is already merged into the cache by insertRecord; just
      // fetch the up-to-date display item that contains it.
      final item = await RecordsFeed.itemContaining(newRecord);
      if (item == null || !mounted || _searchQuery.isNotEmpty) return;

      final wasAtTop = _isAtTop;
      final savedOffset =
          _scrollController.hasClients ? _scrollController.offset : 0.0;

      setState(() {
        // Prepend the up-to-date display item. The keyset cursor is
        // unaffected: newer items live above it and are never re-fetched.
        _removeIntersectingItems(item);
        _displayItems.insert(0, item);
      });

      if (wasAtTop) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0.0);
        }
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          final newMax = _scrollController.position.maxScrollExtent;
          final adjustedOffset = savedOffset.clamp(0.0, newMax);
          if ((_scrollController.offset - adjustedOffset).abs() > 0.5) {
            _scrollController.jumpTo(adjustedOffset);
          }
        });
      }
    } catch (e) {
      developer.log('addNewRecord error: $e', name: 'HistoryScreen');
    }
  }


  static int _getCrossAxisCount(double width) {
    // Responsive grid: min 1 column, max 5, adapting to screen width.
    if (width >= 1600) return 5;
    if (width >= 1200) return 4;
    if (width >= 800) return 3;
    if (width >= 500) return 2;
    return 1;
  }

  /// Test accessor for [_getCrossAxisCount].
  @visibleForTesting
  static int crossAxisCountForWidth(double width) =>
      _getCrossAxisCount(width);

  double _getMapHeight() {
    final width = MediaQuery.of(context).size.width;
    if (width >= 1200) return 320;
    if (width >= 800) return 280;
    return 220;
  }

  Key _displayItemKey(Object item) {
    if (item is TrainRecord) return ValueKey('t:${item.uniqueId}');
    if (item is MergedTrainRecord) return ValueKey('m:${item.groupKey}');
    return ValueKey(item.hashCode);
  }

  Widget _buildCardForItem(Object item) {
    final card = item is MergedTrainRecord
        ? _buildMergedRecordCard(item)
        : item is TrainRecord
            ? _buildRecordCard(item, key: ValueKey(item.uniqueId))
            : const SizedBox.shrink();
    return RepaintBoundary(child: card);
  }

  Widget _buildLoadMoreIndicator() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          width: 24, height: 24,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        _searchRefreshingNotifier,
        _searchCountNotifier,
        _searchLoadedCountNotifier,
      ]),
      builder: (context, _) {
        final isRefreshing = _searchRefreshingNotifier.value;
        final resultCount = _searchCountNotifier.value;
        final loadedCount = _searchLoadedCountNotifier.value;
        String resultText = '搜索中...';
        if (resultCount != null) {
          if (loadedCount != null && loadedCount < resultCount) {
            resultText = '找到 $resultCount 条，已加载 $loadedCount 条';
          } else {
            resultText = '找到 $resultCount 条匹配记录';
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: '搜索车次/机车...',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 14),
                  prefixIcon: const Icon(Icons.search, color: Colors.grey, size: 20),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey, size: 20),
                          onPressed: () {
                            _searchController.clear();
                            _searchFocusNode.unfocus();
                            _onSearchChanged('');
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: const Color(0xFF1E1E1E),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.blue, width: 1),
                  ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
            if (_searchController.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        resultText,
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                    ),
                    if (isRefreshing)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.blue),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildRecordList(int crossAxisCount) {
    // Single column: a plain item-by-item list (no Row wrapper).
    if (crossAxisCount <= 1) {
      return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(16.0),
        addRepaintBoundaries: true,
        addAutomaticKeepAlives: false,
        cacheExtent: 800,
        itemCount: _displayItems.length + (_isLoadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _displayItems.length) return _buildLoadMoreIndicator();
          final item = _displayItems[index];
          return KeyedSubtree(
            key: _displayItemKey(item),
            child: _buildCardForItem(item),
          );
        },
      );
    }

    final cols = crossAxisCount;

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16.0),
      addRepaintBoundaries: true,
      addAutomaticKeepAlives: false,
      cacheExtent: 800,
      itemCount:
          (_displayItems.length / cols).ceil() + (_isLoadingMore ? 1 : 0),
      itemBuilder: (context, rowIndex) {
        final rowCount = (_displayItems.length / cols).ceil();
        // Trailing row renders a full-width centered load-more spinner.
        if (rowIndex >= rowCount) return _buildLoadMoreIndicator();

        final start = rowIndex * cols;
        final end = math.min(start + cols, _displayItems.length);

        // One grid slot: Expanded (equal column width) + horizontal gutter
        // padding + a KeyedSubtree carrying the stable display key so each
        // card's state survives reordering. [visible] false renders an
        // invisible slot that still reserves the column's width — used to keep
        // column alignment across the two overlayed rows below.
        Widget slot(int col, Object item, {bool visible = true}) => Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                    left: col > 0 ? 4.0 : 0, right: col < cols - 1 ? 4.0 : 0),
                child: visible
                    ? KeyedSubtree(
                        key: _displayItemKey(item),
                        child: _buildCardForItem(item),
                      )
                    : const SizedBox.shrink(),
              ),
            );

        // Detect whether any card in this row is expanded.
        var hasExpanded = false;
        for (var col = 0; col < cols; col++) {
          final idx = start + col;
          if (idx < end && _isCardExpanded(_displayItems[idx])) {
            hasExpanded = true;
            break;
          }
        }

        final Widget row;
        if (!hasExpanded) {
          // All collapsed: stretch every card to the tallest one so the row
          // shares one height (content top+bottom justified via the card's
          // Column mainAxisAlignment). Safe — no maps in collapsed cards.
          row = IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var col = 0; col < cols; col++)
                  if (start + col < end) slot(col, _displayItems[start + col]),
              ],
            ),
          );
        } else {
          // A card is expanded. We want the collapsed siblings to share one
          // height (the tallest collapsed card, same as the all-collapsed
          // case) WITHOUT being stretched to the expanded card's taller map
          // height — and every card must stay in its original grid column.
          //
          // A single Row can't do this: IntrinsicHeight+stretch would size the
          // row to the expanded card and drag the collapsed cards up to it. So
          // overlay two full-width rows in a Stack, each carrying all `cols`
          // slots (the matching per-column gutters keep them aligned):
          //   - collapsed layer: IntrinsicHeight + stretch → collapsed cards
          //     share one height (their own tallest), staying short.
          //   - expanded layer: start-aligned, no IntrinsicHeight → expanded
          //     card(s) take their natural taller height.
          // Both layers are top-aligned; each card renders in its own column,
          // so collapsed cards stay equal-height and short while the expanded
          // card rises above them.
          final collapsedSlots = <Widget>[];
          final expandedSlots = <Widget>[];
          for (var col = 0; col < cols; col++) {
            final idx = start + col;
            if (idx >= end) continue;
            final item = _displayItems[idx];
            if (_isCardExpanded(item)) {
              expandedSlots.add(slot(col, item));
              collapsedSlots.add(slot(col, item, visible: false));
            } else {
              collapsedSlots.add(slot(col, item));
              expandedSlots.add(slot(col, item, visible: false));
            }
          }
          row = Stack(
            alignment: Alignment.topLeft,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: collapsedSlots,
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: expandedSlots,
              ),
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: row,
        );
      },
    );
  }

  bool _isCardExpanded(Object item) {
    if (item is TrainRecord) return _expandedStates[item.uniqueId] == true;
    if (item is MergedTrainRecord) {
      return _expandedStates[item.groupKey] == true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitialLoading && _displayItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_isInitialLoading && _displayItems.isEmpty) {
      return Column(children: [
        _buildSearchBar(),
        Expanded(
          child: Center(
            child: _isSearchRefreshing
                ? const CircularProgressIndicator(color: Colors.blue)
                : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.history, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('暂无记录', style: TextStyle(color: Colors.white, fontSize: 18))
                  ]),
          ),
        ),
      ]);
    }
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = _getCrossAxisCount(screenWidth);

    return Column(children: [
      _buildSearchBar(),
      Expanded(child: _buildRecordList(crossAxisCount)),
    ]);
  }

  Future<void> _loadMergedDetails(MergedTrainRecord merged) async {
    if (!mounted || merged.hasLoadedDetails || merged.recordCount <= 1) return;
    if (_mergedDetailsLoading[merged.groupKey] == true) return;

    setState(() => _mergedDetailsLoading[merged.groupKey] = true);

    try {
      final loaded = await DatabaseService.instance.getRecordsByUniqueIds(
        merged.memberUniqueIds,
      );
      if (!mounted) return;
      if (loaded.length < merged.memberUniqueIds.length) {
        // Short result (no throw): some members are missing from
        // train_records — an orphaned cache member, or a record deleted
        // between building the display item and this fetch. Don't latch
        // partial data; flag the group so the build self-heal doesn't
        // retry-loop on a result that will keep coming up short. Recovery
        // is a manual collapse+expand or a full reload (_loadFirstPage),
        // both of which clear the flag.
        _mergedDetailsLoadFailed.add(merged.groupKey);
      } else {
        merged.setDetailRecords(loaded);
      }
    } catch (e) {
      developer.log('loadMergedDetails error: $e', name: 'HistoryScreen');
      _mergedDetailsLoadFailed.add(merged.groupKey);
    } finally {
      if (mounted) {
        setState(() => _mergedDetailsLoading.remove(merged.groupKey));
      }
    }
  }

  Widget _buildMergedRecordCard(MergedTrainRecord mergedRecord) {
    final bool isSelected = mergedRecord.memberUniqueIds
        .any((id) => _selectedRecords.contains(id));
    final isExpanded = _expandedStates[mergedRecord.groupKey] ?? false;
    // Self-heal an already-expanded merged card whose instance was swapped
    // for a fresh one. This happens when a new record merges INTO the
    // expanded group (addNewRecord), on a full reload (_loadFirstPage, via
    // settings change / record delete), or when an in-flight
    // _loadMergedDetails had its captured instance replaced mid-flight. A
    // fresh instance has hasLoadedDetails == false, and the detail load is
    // otherwise only triggered by the expand-tap gesture — which never
    // fires for an already-expanded card, so without this the card would
    // spin forever (closing and re-opening was the only recovery). Re-arm
    // the load from build instead. The guards keep at most one in-flight
    // load per group and prevent any retry storm:
    //   - _mergedDetailsLoading==true  -> a load is already running
    //   - _mergedDetailsLoadFailed      -> last attempt failed (threw, or
    //     returned fewer records than members); cleared by a manual
    //     collapse+expand or a full reload (_loadFirstPage)
    //   - hasLoadedDetails              -> already done
    if (isExpanded &&
        mergedRecord.recordCount > 1 &&
        !mergedRecord.hasLoadedDetails &&
        _mergedDetailsLoading[mergedRecord.groupKey] != true &&
        !_mergedDetailsLoadFailed.contains(mergedRecord.groupKey)) {
      final groupKey = mergedRecord.groupKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Operate on whichever instance currently backs this group — it may
        // have been swapped again between this build and the callback.
        MergedTrainRecord? current;
        for (final it in _displayItems) {
          if (it is MergedTrainRecord && it.groupKey == groupKey) {
            current = it;
            break;
          }
        }
        if (current == null) return;
        if (current.hasLoadedDetails) return;
        if (_mergedDetailsLoading[groupKey] == true) return;
        if (_mergedDetailsLoadFailed.contains(groupKey)) return;
        _loadMergedDetails(current);
      });
    }
    final displayRecord = mergedRecord.summaryRecord;
    return Card(
        key: ValueKey(mergedRecord.groupKey),
        color: isSelected && _isEditMode
            ? const Color(0xFF2E2E2E)
            : const Color(0xFF1E1E1E),
        elevation: 1,
        margin: const EdgeInsets.only(bottom: 8.0),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8.0),
            side: BorderSide(
                color: isSelected && _isEditMode
                    ? Colors.blue
                    : Colors.transparent,
                width: 2.0)),
        child: InkWell(
            borderRadius: BorderRadius.circular(8.0),
            onTap: () {
              if (_isEditMode) {
                setState(() {
                  final allIdsInGroup = mergedRecord.memberUniqueIds.toSet();
                  if (isSelected) {
                    _selectedRecords.removeAll(allIdsInGroup);
                  } else {
                    _selectedRecords.addAll(allIdsInGroup);
                  }
                  widget.onSelectionChanged();
                });
              } else {
                if (isExpanded) {
                  final mapId = mergedRecord.memberUniqueIds.join('_');
                  setState(() {
                    _expandedStates[mergedRecord.groupKey] = false;
                    _mapOptimalZoom.remove(mapId);
                    _mapCalculating.remove(mapId);
                  });
                } else {
                  setState(() {
                    _expandedStates[mergedRecord.groupKey] = true;
                    _mergedDetailsLoadFailed.remove(mergedRecord.groupKey);
                  });
                  _loadMergedDetails(mergedRecord);
                }
              }
            },
            onLongPress: () {
              if (!_isEditMode) {
                setEditMode(true);
              }
              setState(() {
                _selectedRecords.addAll(mergedRecord.memberUniqueIds);
                widget.onSelectionChanged();
              });
            },
            child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: isExpanded
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.spaceBetween,
                    children: [
                      _buildRecordHeader(displayRecord, isMerged: true),
                      if (mergedRecord.recordCount > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '共 ${mergedRecord.recordCount} 条 · 点击展开',
                            style: const TextStyle(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      _buildPositionAndSpeed(displayRecord),
                      _buildLocoInfo(displayRecord),
                      if (isExpanded) _buildMergedExpandedContent(mergedRecord)
                    ]))));
  }

  Widget _buildMergedExpandedContent(MergedTrainRecord mergedRecord) {
    final loading = _mergedDetailsLoading[mergedRecord.groupKey] ?? false;
    if (loading ||
        (!mergedRecord.hasLoadedDetails && mergedRecord.recordCount > 1)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
          ),
        ),
      );
    }

    final details = mergedRecord.records;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildExpandedMapForAll(details, mergedRecord.groupKey),
        const Divider(color: Colors.white24, height: 24),
        ...details.map((record) =>
            _buildSubRecordItem(record, mergedRecord.latestRecord)),
      ],
    );
  }

  Widget _buildSubRecordItem(TrainRecord record, TrainRecord latest) {
    String differingInfo = _getDifferingInfo(record, latest);
    String locationInfo = _getLocationInfo(record);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0, top: 4.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                record.receivedTimestamp.toString().split('.')[0],
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              if (differingInfo.isNotEmpty)
                Text(
                  differingInfo,
                  style:
                      const TextStyle(color: Color(0xFF81D4FA), fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  locationInfo,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                record.speed.isNotEmpty ? "${record.speed} km/h" : "",
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatLocoInfo(TrainRecord record) => record.formattedLocoDisplay;

  String _getDifferingInfo(TrainRecord record, TrainRecord latest) {
    final train = record.train.trim();
    final loco = record.loco.trim();
    final latestTrain = latest.train.trim();
    final latestLoco = latest.loco.trim();

    final trainDiff = train.isNotEmpty && train != latestTrain ? train : "";
    final locoDiff =
        loco.isNotEmpty && loco != latestLoco ? _formatLocoInfo(record) : "";

    if (trainDiff.isNotEmpty && locoDiff.isNotEmpty) {
      return "$trainDiff $locoDiff";
    } else if (trainDiff.isNotEmpty) {
      return trainDiff;
    } else if (locoDiff.isNotEmpty) {
      return locoDiff;
    }
    return "";
  }

  String _getLocationInfo(TrainRecord record) {
    List<String> parts = [];
    if (record.route.isNotEmpty && record.route != "<NUL>") {
      parts.add(record.route);
    }
    if (record.direction != 0) {
      parts.add(record.direction == 1 ? "下" : "上");
    }
    if (record.position.isNotEmpty && record.position != "<NUL>") {
      final position = record.position;
      final cleanPosition = position.endsWith('.')
          ? position.substring(0, position.length - 1)
          : position;
      parts.add("${cleanPosition}K");
    }
    return parts.join(' ');
  }

  Widget _buildExpandedMapForAll(List<TrainRecord> records, String groupKey) {
    final positions = records
        .map((record) => _parsePosition(record.positionInfo))
        .whereType<LatLng>()
        .toList();
    if (positions.isEmpty) {
      return const SizedBox.shrink();
    }

    final mapId = records.map((r) => r.uniqueId).join('_');
    final bounds = LatLngBounds.fromPoints(positions);

    if (!_mapOptimalZoom.containsKey(mapId) &&
        !(_mapCalculating[mapId] ?? false)) {
      _mapCalculating[mapId] = true;

      _calculateOptimalZoomAsync(positions,
              containerWidth: MediaQuery.of(context).size.width / _getCrossAxisCount(MediaQuery.of(context).size.width) - 40,
              containerHeight: _getMapHeight())
          .then((optimalZoom) {
        if (mounted) {
          setState(() {
            _mapOptimalZoom[mapId] = optimalZoom;
            _mapCalculating[mapId] = false;
          });
        }
      });
    }

    if (!_mapOptimalZoom.containsKey(mapId)) {
      return const Column(
        children: [
          SizedBox(height: 8),
          SizedBox(
            height: 228,
            child: Center(
              child: CircularProgressIndicator(
                color: Colors.blue,
                strokeWidth: 2,
              ),
            ),
          ),
        ],
      );
    }

    final zoomLevel = _mapOptimalZoom[mapId]!;

    return Column(children: [
      const SizedBox(height: 8),
      Container(
          height: _getMapHeight(),
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8), color: Colors.grey[900]),
          child: _DelayedMultiMarkerMap(
            key: ValueKey('multi_map_${mapId}_$zoomLevel'),
            positions: positions,
            center: bounds.center,
            zoom: zoomLevel,
            groupKey: groupKey,
            currentUserLocation: _currentUserLocation,
          ))
    ]);
  }

  Future<void> _requestLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever) {
      return;
    }

    if (mounted) {
      setState(() {
        _isLocationPermissionGranted = true;
      });
    }

    _getCurrentLocation();
  }

  Future<void> _getCurrentLocation() async {
    try {
      final locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        forceLocationManager: true,
      );
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );

      if (mounted) {
        setState(() {
          _currentUserLocation = LatLng(position.latitude, position.longitude);
        });
      }
    } catch (e) {}
  }

  void _startLocationUpdates() {
    _requestLocationPermission();

    _locationTimer = Timer.periodic(const Duration(seconds: 30), (timer) {
      if (_isLocationPermissionGranted) {
        _getCurrentLocation();
      }
    });
  }

  Widget _buildRecordCard(TrainRecord record,
      {bool isSubCard = false, Key? key}) {
    final isSelected = _selectedRecords.contains(record.uniqueId);
    final isExpanded = _expandedStates[record.uniqueId] ?? false;

    return Card(
        key: key,
        color: isSelected && _isEditMode
            ? const Color(0xFF2E2E2E)
            : const Color(0xFF1E1E1E),
        elevation: isSubCard ? 0 : 1,
        margin: EdgeInsets.only(bottom: isSubCard ? 4.0 : 8.0),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8.0),
            side: BorderSide(
                color: isSelected && _isEditMode
                    ? Colors.blue
                    : Colors.transparent,
                width: 2.0)),
        child: InkWell(
            borderRadius: BorderRadius.circular(8.0),
            onTap: () {
              if (_isEditMode) {
                setState(() {
                  if (isSelected) {
                    _selectedRecords.remove(record.uniqueId);
                  } else {
                    _selectedRecords.add(record.uniqueId);
                  }
                  widget.onSelectionChanged();
                });
              } else {
                setState(() {
                  _expandedStates[record.uniqueId] =
                      !(_expandedStates[record.uniqueId] ?? false);
                });
              }
            },
            onLongPress: () {
              if (!_isEditMode) {
                setEditMode(true);
              }
              setState(() {
                _selectedRecords.add(record.uniqueId);
                widget.onSelectionChanged();
              });
            },
            child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: isExpanded
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.spaceBetween,
                    children: [
                      _buildRecordHeader(record),
                      _buildPositionAndSpeed(record),
                      _buildLocoInfo(record),
                      if (isExpanded) _buildExpandedContent(record),
                    ]))));
  }

  Widget _buildRecordHeader(TrainRecord record, {bool isMerged = false}) {
    final trainType = record.trainType;
    final formattedLocoInfo = record.formattedLocoDisplay;

    if (record.fullTrainNumber.isEmpty && formattedLocoInfo.isEmpty) {
      return Text(
          (record.time == "<NUL>" || record.time.isEmpty)
              ? record.receivedTimestamp.toString().split(".")[0]
              : record.time.split("\n")[0],
          style: const TextStyle(fontSize: 11, color: Colors.grey),
          overflow: TextOverflow.ellipsis);
    }

    final hasTrainNumber = record.fullTrainNumber.isNotEmpty;
    final hasDirection = record.direction == 1 || record.direction == 3;
    final hasLocoInfo =
        formattedLocoInfo.isNotEmpty && formattedLocoInfo != "<NUL>";
    final shouldShowTrainRow = hasTrainNumber || hasDirection || hasLocoInfo;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Flexible(
            child: Text(
                (record.time == "<NUL>" || record.time.isEmpty)
                    ? record.receivedTimestamp.toString().split(".")[0]
                    : record.time.split("\n")[0],
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                overflow: TextOverflow.ellipsis)),
        if (trainType.isNotEmpty)
          Flexible(
              child: Text(trainType,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  overflow: TextOverflow.ellipsis))
      ]),
      if (shouldShowTrainRow) ...[
        const SizedBox(height: 2),
        Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                  child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                    if (hasTrainNumber)
                      Flexible(
                          child: Text(record.fullTrainNumber,
                              style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white),
                              overflow: TextOverflow.ellipsis)),
                    if (hasTrainNumber && hasDirection)
                      const SizedBox(width: 6),
                    if (hasDirection)
                      Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(2)),
                          child: Center(
                              child: Text(record.direction == 1 ? "下" : "上",
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.black))))
                  ])),
              if (hasLocoInfo)
                Text(formattedLocoInfo,
                    style:
                        const TextStyle(fontSize: 14, color: Colors.white70)),
            ]),
        const SizedBox(height: 2)
      ]
    ]);
  }

  Widget _buildLocoInfo(TrainRecord record) {
    final locoInfo = record.locoInfo;
    if (locoInfo == null || locoInfo.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 4),
      Text(locoInfo,
          style: const TextStyle(fontSize: 14, color: Colors.white),
          maxLines: 1,
          overflow: TextOverflow.ellipsis)
    ]);
  }

  Widget _buildPositionAndSpeed(TrainRecord record) {
    final routeStr = record.route.trim();
    final position = record.position.trim();
    final speed = record.speed.trim();
    final isValidRoute = routeStr.isNotEmpty &&
        !routeStr.runes.every((r) => r == '*'.runes.first);
    final isValidPosition = position.isNotEmpty &&
        !position.runes
            .every((r) => r == '-'.runes.first || r == '.'.runes.first) &&
        position != "<NUL>";
    final isValidSpeed = speed.isNotEmpty &&
        !speed.runes
            .every((r) => r == '*'.runes.first || r == '-'.runes.first) &&
        speed != "NUL" &&
        speed != "<NUL>";
    if (!isValidRoute && !isValidPosition && !isValidSpeed) {
      return const SizedBox.shrink();
    }
    return Padding(
        padding: const EdgeInsets.only(top: 4.0),
        child:
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          if (isValidRoute || isValidPosition)
            Expanded(
                child: Row(children: [
              if (isValidRoute)
                Flexible(
                    child: Text(routeStr,
                        style:
                            const TextStyle(fontSize: 16, color: Colors.white),
                        overflow: TextOverflow.ellipsis)),
              if (isValidRoute && isValidPosition) const SizedBox(width: 4),
              if (isValidPosition)
                Flexible(
                    child: Text(
                        "${position.trim().endsWith('.') ? position.trim().substring(0, position.trim().length - 1) : position.trim()}K",
                        style:
                            const TextStyle(fontSize: 16, color: Colors.white),
                        overflow: TextOverflow.ellipsis))
            ])),
          if (isValidSpeed)
            Text("${speed.replaceAll(' ', '')} km/h",
                style: const TextStyle(fontSize: 16, color: Colors.white),
                textAlign: TextAlign.right)
        ]));
  }

  Widget _buildExpandedContent(TrainRecord record) {
    final position = _parsePosition(record.positionInfo);
    final mapId = record.uniqueId;

    if (position == null) {
      return const SizedBox.shrink();
    }

    if (!_mapOptimalZoom.containsKey(mapId) &&
        !(_mapCalculating[mapId] ?? false)) {
      _mapCalculating[mapId] = true;

      _calculateOptimalZoomAsync([position],
              containerWidth: 400, containerHeight: 220)
          .then((optimalZoom) {
        if (mounted) {
          setState(() {
            _mapOptimalZoom[mapId] = optimalZoom;
            _mapCalculating[mapId] = false;
          });
        }
      });
    }

    if (!_mapOptimalZoom.containsKey(mapId)) {
      return const Column(
        children: [
          SizedBox(height: 8),
          SizedBox(
            height: 228,
            child: Center(
              child: CircularProgressIndicator(
                color: Colors.blue,
                strokeWidth: 2,
              ),
            ),
          ),
        ],
      );
    }

    final zoomLevel = _mapOptimalZoom[mapId]!;

    return Column(children: [
      const SizedBox(height: 8),
      Container(
          height: 220,
          margin: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8), color: Colors.grey[900]),
          child: _DelayedMapWithMarker(
            key: ValueKey('map_${mapId}_$zoomLevel'),
            position: position,
            zoom: zoomLevel,
            recordId: record.uniqueId,
            currentUserLocation: _currentUserLocation,
          ))
    ]);
  }

  LatLng? _parsePosition(String? positionInfo) {
    if (positionInfo == null ||
        positionInfo.isEmpty ||
        positionInfo == '<NUL>') {
      return null;
    }
    try {
      final parts = positionInfo.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final lat = _parseDmsCoordinate(parts[0]);
        final lng = _parseDmsCoordinate(parts[1]);
        if (lat != null &&
            lng != null &&
            (lat.abs() > 0.001 || lng.abs() > 0.001)) {
          return LatLng(lat, lng);
        }
      }
    } catch (e) {}
    return null;
  }

  double? _parseDmsCoordinate(String dmsStr) {
    try {
      final degreeIndex = dmsStr.indexOf('°');
      if (degreeIndex == -1) {
        return null;
      }
      final degrees = double.tryParse(dmsStr.substring(0, degreeIndex));
      if (degrees == null) {
        return null;
      }
      final minuteIndex = dmsStr.indexOf('′');
      if (minuteIndex == -1) {
        return degrees;
      }
      final minutes =
          double.tryParse(dmsStr.substring(degreeIndex + 1, minuteIndex));
      if (minutes == null) {
        return degrees;
      }
      return degrees + (minutes / 60.0);
    } catch (e) {
      return null;
    }
  }

  Future<_BoundaryBox> _calculateBoundaryBoxParallel(
      List<LatLng> positions) async {
    if (positions.length < 100) {
      return _calculateBoundaryBoxIsolate(positions);
    }

    final chunkSize = (positions.length / 4).ceil();
    final chunks = <List<LatLng>>[];

    for (int i = 0; i < positions.length; i += chunkSize) {
      final end = math.min(i + chunkSize, positions.length);
      chunks.add(positions.sublist(i, end));
    }

    final results = await Future.wait(chunks.map(
        (chunk) => Isolate.run(() => _calculateBoundaryBoxIsolate(chunk))));

    double minLat = results[0].minLat;
    double maxLat = results[0].maxLat;
    double minLng = results[0].minLng;
    double maxLng = results[0].maxLng;

    for (final box in results.skip(1)) {
      minLat = math.min(minLat, box.minLat);
      maxLat = math.max(maxLat, box.maxLat);
      minLng = math.min(minLng, box.minLng);
      maxLng = math.max(maxLng, box.maxLng);
    }

    return _BoundaryBox(minLat, maxLat, minLng, maxLng);
  }

  Future<double> _calculateOptimalZoomAsync(List<LatLng> positions,
      {required double containerWidth, required double containerHeight}) async {
    if (positions.length == 1) return 17.0;

    final boundaryBox = await _calculateBoundaryBoxParallel(positions);

    double latToY(double lat) {
      final latRad = lat * math.pi / 180.0;
      return math.log(math.tan(latRad) + 1.0 / math.cos(latRad));
    }

    double lngToX(double lng) {
      return lng * math.pi / 180.0;
    }

    final minX = lngToX(boundaryBox.minLng);
    final maxX = lngToX(boundaryBox.maxLng);
    final minY = latToY(boundaryBox.minLat);
    final maxY = latToY(boundaryBox.maxLat);

    const worldSize = 2.0 * math.pi;

    final widthWorld = (maxX - minX) / worldSize;
    final heightWorld = (maxY - minY) / worldSize;

    const paddingRatio = 0.8;

    final widthZoom =
        math.log((containerWidth * paddingRatio) / (widthWorld * 256.0)) /
            math.log(2.0);
    final heightZoom =
        math.log((containerHeight * paddingRatio) / (heightWorld * 256.0)) /
            math.log(2.0);

    final optimalZoom = math.min(widthZoom, heightZoom);

    return math.max(5.0, math.min(18.0, optimalZoom));
  }
}

class _BoundaryBox {
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;

  _BoundaryBox(this.minLat, this.maxLat, this.minLng, this.maxLng);
}

_BoundaryBox _calculateBoundaryBoxIsolate(List<LatLng> positions) {
  double minLat = positions[0].latitude;
  double maxLat = positions[0].latitude;
  double minLng = positions[0].longitude;
  double maxLng = positions[0].longitude;

  for (final pos in positions) {
    minLat = math.min(minLat, pos.latitude);
    maxLat = math.max(maxLat, pos.latitude);
    minLng = math.min(minLng, pos.longitude);
    maxLng = math.max(maxLng, pos.longitude);
  }

  return _BoundaryBox(minLat, maxLat, minLng, maxLng);
}

class _DelayedMapWithMarker extends StatefulWidget {
  final LatLng position;
  final double zoom;
  final String recordId;
  final LatLng? currentUserLocation;

  const _DelayedMapWithMarker({
    super.key,
    required this.position,
    required this.zoom,
    required this.recordId,
    this.currentUserLocation,
  });

  @override
  State<_DelayedMapWithMarker> createState() => _DelayedMapWithMarkerState();
}

class _DelayedMapWithMarkerState extends State<_DelayedMapWithMarker> {
  late final MapController _mapController;
  late final String _mapKey;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _mapKey = MapStateService.instance.getSingleRecordMapKey(widget.recordId);
    _initializeMapState();
  }

  Future<void> _initializeMapState() async {
    final savedState = await MapStateService.instance.getMapState(_mapKey);
    if (savedState != null && mounted) {
      _mapController.move(
        LatLng(savedState.centerLat, savedState.centerLng),
        savedState.zoom,
      );
      if (savedState.bearing != 0.0) {
        _mapController.rotate(savedState.bearing);
      }
    }
    if (mounted) {
      setState(() {
        _isInitializing = false;
      });
    }
  }

  void _onCameraMove() {
    if (_isInitializing) {
      return;
    }

    final camera = _mapController.camera;
    final state = MapState(
      zoom: camera.zoom,
      centerLat: camera.center.latitude,
      centerLng: camera.center.longitude,
      bearing: camera.rotation,
    );

    MapStateService.instance.saveMapState(_mapKey, state);
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>[
      Marker(
        point: widget.position,
        width: 24,
        height: 24,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.red,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white, width: 1.5),
          ),
          child: const Icon(Icons.train, color: Colors.white, size: 12),
        ),
      ),
    ];

    if (widget.currentUserLocation != null) {
      markers.add(
        Marker(
          point: widget.currentUserLocation!,
          width: 24,
          height: 24,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.blue,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
            child: const Icon(
              Icons.my_location,
              color: Colors.white,
              size: 12,
            ),
          ),
        ),
      );
    }

    if (_isInitializing) {
      return FlutterMap(
        options: MapOptions(
          initialCenter: widget.position,
          initialZoom: widget.zoom,
          onPositionChanged: (position, hasGesture) => _onCameraMove(),
        ),
        mapController: _mapController,
        children: [
          TileLayer(
              urlTemplate: 'https://tile-osm.mirror.wzpmc.email/{z}/{x}/{y}.png',
              userAgentPackageName: 'org.noxylva.lbjconsole'),
          MarkerLayer(markers: markers),
        ],
      );
    }

    return FlutterMap(
      options: MapOptions(
        onPositionChanged: (position, hasGesture) => _onCameraMove(),
      ),
      mapController: _mapController,
      children: [
        TileLayer(
            urlTemplate: 'https://tile-osm.mirror.wzpmc.email/{z}/{x}/{y}.png',
            userAgentPackageName: 'org.noxylva.lbjconsole'),
        MarkerLayer(markers: markers),
      ],
    );
  }
}

class _DelayedMultiMarkerMap extends StatefulWidget {
  final List<LatLng> positions;
  final LatLng center;
  final double zoom;
  final String groupKey;
  final LatLng? currentUserLocation;

  const _DelayedMultiMarkerMap({
    super.key,
    required this.positions,
    required this.center,
    required this.zoom,
    required this.groupKey,
    this.currentUserLocation,
  });

  @override
  State<_DelayedMultiMarkerMap> createState() => _DelayedMultiMarkerMapState();
}

class _DelayedMultiMarkerMapState extends State<_DelayedMultiMarkerMap> {
  late final MapController _mapController;
  late final String _mapKey;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _mapKey = MapStateService.instance.getMergedRecordMapKey(widget.groupKey);
    _initializeMapState();
  }

  Future<void> _initializeMapState() async {
    final savedState = await MapStateService.instance.getMapState(_mapKey);
    if (savedState != null && mounted) {
      _mapController.move(
        LatLng(savedState.centerLat, savedState.centerLng),
        savedState.zoom,
      );
      if (savedState.bearing != 0.0) {
        _mapController.rotate(savedState.bearing);
      }
    } else if (mounted) {
      _mapController.move(widget.center, widget.zoom);
    }
    if (mounted) {
      setState(() {
        _isInitializing = false;
      });
    }
  }

  void _onCameraMove() {
    if (_isInitializing) {
      return;
    }

    final camera = _mapController.camera;
    final state = MapState(
      zoom: camera.zoom,
      centerLat: camera.center.latitude,
      centerLng: camera.center.longitude,
      bearing: camera.rotation,
    );

    MapStateService.instance.saveMapState(_mapKey, state);
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>[
      ...widget.positions.map((pos) => Marker(
          point: pos,
          width: 24,
          height: 24,
          child: Container(
              decoration: BoxDecoration(
                  color: Colors.red.withAlpha((255 * 0.8).round()),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5)),
              child: const Icon(Icons.train, color: Colors.white, size: 12)))),
    ];

    if (widget.currentUserLocation != null) {
      markers.add(
        Marker(
          point: widget.currentUserLocation!,
          width: 24,
          height: 24,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.blue,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
            child: const Icon(
              Icons.my_location,
              color: Colors.white,
              size: 12,
            ),
          ),
        ),
      );
    }

    return FlutterMap(
      options: MapOptions(
        onPositionChanged: (position, hasGesture) => _onCameraMove(),
        minZoom: 8,
        maxZoom: 18,
      ),
      mapController: _mapController,
      children: [
        TileLayer(
          urlTemplate: 'https://tile-osm.mirror.wzpmc.email/{z}/{x}/{y}.png',
          userAgentPackageName: 'org.noxylva.lbjconsole',
        ),
        MarkerLayer(markers: markers),
      ],
    );
  }
}
