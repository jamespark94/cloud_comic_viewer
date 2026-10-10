import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/comic_reading_history.dart';

class ReadingHistoryService extends ChangeNotifier {
  static const String _storageKey = 'comic_reading_histories';
  static const String _deletedStorageKey = 'comic_reading_deleted_records';
  static ReadingHistoryService? _instance;
  static ReadingHistoryService get instance => _instance ??= ReadingHistoryService._();

  final Map<String, ComicReadingHistory> _histories = {};
  Map<String, int>? _deletedCache;

  ReadingHistoryService._();

  List<ComicReadingHistory> get recentList {
    final list = _histories.values.toList();
    list.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
    return list;
  }

  ComicReadingHistory? getHistory(String id) => _histories[id];

  Future<Map<String, int>> getDeletedRecords() async {
    if (_deletedCache != null) return _deletedCache!;
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_deletedStorageKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final decoded = jsonDecode(jsonStr) as Map<String, dynamic>;
        _deletedCache = decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
        return _deletedCache!;
      }
    } catch (e) {
      debugPrint('[ReadingHistory] 삭제 기록 불러오기 실패: $e');
    }
    _deletedCache = {};
    return _deletedCache!;
  }

  Future<void> _saveDeletedRecords() async {
    if (_deletedCache == null) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      const thirtyDaysMs = 30 * 24 * 60 * 60 * 1000;
      _deletedCache!.removeWhere((k, timestamp) => now - timestamp > thirtyDaysMs);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_deletedStorageKey, jsonEncode(_deletedCache));
    } catch (e) {
      debugPrint('[ReadingHistory] 삭제 기록 저장 실패: $e');
    }
  }

  Future<void> loadHistories() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_storageKey);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final List<dynamic> list = jsonDecode(jsonStr);
        _histories.clear();
        for (final item in list) {
          final history = ComicReadingHistory.fromJson(item as Map<String, dynamic>);
          _histories[history.id] = history;
        }
      } catch (_) {}
    }
    await getDeletedRecords();
    notifyListeners();
  }

  Future<void> updateProgress({
    required String id,
    required String accountId,
    required String accountName,
    required dynamic cloudType, // CloudType
    required String title,
    String? parentFolderId,
    required int pageIndex,
    required int totalPages,
    String? coverThumbnailUrl,
  }) async {
    // 삭제 툼스톤이 존재한다면 (사용자가 삭제 후 다시 열람한 경우) 툼스톤 해제
    final deleted = await getDeletedRecords();
    if (deleted.containsKey(id) || deleted.containsKey(title)) {
      deleted.remove(id);
      deleted.remove(title);
      await _saveDeletedRecords();
    }

    final history = ComicReadingHistory(
      id: id,
      accountId: accountId,
      accountName: accountName,
      cloudType: cloudType,
      title: title,
      parentFolderId: parentFolderId,
      lastPage: pageIndex,
      totalPages: totalPages,
      lastReadAt: DateTime.now(),
      coverThumbnailUrl: coverThumbnailUrl ?? _histories[id]?.coverThumbnailUrl,
    );

    _histories[id] = history;
    await _persist();
    notifyListeners();
  }

  Future<void> updateThumbnail(String id, String thumbnailPath) async {
    final existing = _histories[id];
    if (existing != null) {
      _histories[id] = ComicReadingHistory(
        id: existing.id,
        accountId: existing.accountId,
        accountName: existing.accountName,
        cloudType: existing.cloudType,
        title: existing.title,
        parentFolderId: existing.parentFolderId,
        lastPage: existing.lastPage,
        totalPages: existing.totalPages,
        lastReadAt: existing.lastReadAt,
        coverThumbnailUrl: thumbnailPath,
      );
      await _persist();
      notifyListeners();
    }
  }

  /// 특정 히스토리 삭제 (식별자 및 제목 기준 툼스톤 등록)
  Future<void> removeHistory(String id, {String? title}) async {
    final deleted = await getDeletedRecords();
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1. id 및 title 툼스톤 등록
    deleted[id] = now;
    if (title != null && title.isNotEmpty) {
      deleted[title] = now;
    }

    final existing = _histories[id];
    final titleToMatch = title ?? existing?.title;
    if (titleToMatch != null && titleToMatch.isNotEmpty) {
      deleted[titleToMatch] = now;
    }

    // 2. id 또는 title 일치 항목 탐색 및 제거
    final keysToRemove = <String>[];
    for (final entry in _histories.entries) {
      if (entry.key == id ||
          entry.value.id == id ||
          (titleToMatch != null && entry.value.title == titleToMatch)) {
        keysToRemove.add(entry.key);
        if (entry.value.coverThumbnailUrl != null) {
          try {
            final f = File(entry.value.coverThumbnailUrl!);
            if (f.existsSync()) f.deleteSync();
          } catch (_) {}
        }
      }
    }

    for (final k in keysToRemove) {
      _histories.remove(k);
    }

    await _persist();
    await _saveDeletedRecords();
    notifyListeners();
  }

  /// 전체 히스토리 삭제 (현재 모든 기록 툼스톤 등록)
  Future<void> clearAll() async {
    final deleted = await getDeletedRecords();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final h in _histories.values) {
      deleted[h.id] = now;
      if (h.title.isNotEmpty) {
        deleted[h.title] = now;
      }
      if (h.coverThumbnailUrl != null) {
        try {
          final f = File(h.coverThumbnailUrl!);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
    }

    _histories.clear();
    await _persist();
    await _saveDeletedRecords();
    notifyListeners();
  }

  List<ComicReadingHistory> getAllHistories() => _histories.values.toList();

  /// 원격 클라우드 히스토리 목록과 로컬 목록을 스마트 병합 (삭제 툼스톤 양방향 반영)
  Future<List<ComicReadingHistory>> mergeWithRemote(
    List<ComicReadingHistory> remoteList, {
    Map<String, int>? remoteDeletedRecords,
  }) async {
    final deleted = await getDeletedRecords();

    // 1. 원격 삭제 툼스톤을 로컬 툼스톤과 병합
    if (remoteDeletedRecords != null && remoteDeletedRecords.isNotEmpty) {
      for (final entry in remoteDeletedRecords.entries) {
        final existingTime = deleted[entry.key] ?? 0;
        deleted[entry.key] = math.max(existingTime, entry.value);
      }
      await _saveDeletedRecords();
    }

    // 2. 로컬 레코드 중 삭제 툼스톤에 의해 삭제된 항목 제거
    final localKeysToRemove = <String>[];
    for (final entry in _histories.entries) {
      final h = entry.value;
      final delTime = math.max(deleted[h.id] ?? 0, deleted[h.title] ?? 0);
      if (delTime > 0 && h.lastReadAt.millisecondsSinceEpoch <= delTime) {
        localKeysToRemove.add(entry.key);
      }
    }
    for (final key in localKeysToRemove) {
      _histories.remove(key);
    }

    // 3. 원격 레코드 병합 (단, 삭제 툼스톤 이후의 기록만 수용하여 좀비 부활 방지)
    for (final remote in remoteList) {
      final delTime = math.max(deleted[remote.id] ?? 0, deleted[remote.title] ?? 0);
      if (delTime > 0 && remote.lastReadAt.millisecondsSinceEpoch <= delTime) {
        continue;
      }

      // 만약 삭제 시각 이후에 새로 읽은 기록이라면 툼스톤 해제
      if (delTime > 0 && remote.lastReadAt.millisecondsSinceEpoch > delTime) {
        deleted.remove(remote.id);
        deleted.remove(remote.title);
      }

      // 로컬에 기존 매칭되는 레코드가 있는지 검사 (id 또는 title)
      String? matchedKey;
      ComicReadingHistory? existing;

      if (_histories.containsKey(remote.id)) {
        matchedKey = remote.id;
        existing = _histories[remote.id];
      } else {
        for (final entry in _histories.entries) {
          if (entry.value.title == remote.title) {
            matchedKey = entry.key;
            existing = entry.value;
            break;
          }
        }
      }

      if (existing == null) {
        _histories[remote.id] = remote;
      } else {
        final higherPage = remote.lastPage > existing.lastPage ? remote.lastPage : existing.lastPage;
        final maxPages = remote.totalPages > existing.totalPages ? remote.totalPages : existing.totalPages;
        final newerTime = remote.lastReadAt.isAfter(existing.lastReadAt) ? remote.lastReadAt : existing.lastReadAt;
        final thumb = existing.coverThumbnailUrl ?? remote.coverThumbnailUrl;

        final mergedHistory = ComicReadingHistory(
          id: existing.id,
          accountId: existing.accountId,
          accountName: existing.accountName,
          cloudType: existing.cloudType,
          title: existing.title,
          parentFolderId: existing.parentFolderId ?? remote.parentFolderId,
          lastPage: higherPage,
          totalPages: maxPages,
          lastReadAt: newerTime,
          coverThumbnailUrl: thumb,
        );

        if (matchedKey != null && matchedKey != remote.id) {
          _histories.remove(matchedKey);
        }
        _histories[remote.id] = mergedHistory;
      }
    }

    await _persist();
    await _saveDeletedRecords();
    notifyListeners();
    return recentList;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _histories.values.map((e) => e.toJson()).toList();
    await prefs.setString(_storageKey, jsonEncode(list));
  }
}
