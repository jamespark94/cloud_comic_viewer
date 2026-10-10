import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/comic_reading_history.dart';

class ReadingHistoryService extends ChangeNotifier {
  static const String _storageKey = 'comic_reading_histories';
  static ReadingHistoryService? _instance;
  static ReadingHistoryService get instance => _instance ??= ReadingHistoryService._();

  final Map<String, ComicReadingHistory> _histories = {};

  ReadingHistoryService._();

  List<ComicReadingHistory> get recentList {
    final list = _histories.values.toList();
    list.sort((a, b) => b.lastReadAt.compareTo(a.lastReadAt));
    return list;
  }

  ComicReadingHistory? getHistory(String id) => _histories[id];

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

  Future<void> removeHistory(String id) async {
    _histories.remove(id);
    await _persist();
    notifyListeners();
  }

  Future<void> clearAll() async {
    _histories.clear();
    await _persist();
    notifyListeners();
  }

  List<ComicReadingHistory> getAllHistories() => _histories.values.toList();

  /// 원격 클라우드 히스토리 목록과 로컬 목록을 스마트 병합
  Future<List<ComicReadingHistory>> mergeWithRemote(List<ComicReadingHistory> remoteList) async {
    for (final remote in remoteList) {
      final existing = _histories[remote.id];
      if (existing == null) {
        _histories[remote.id] = remote;
      } else {
        final higherPage = remote.lastPage > existing.lastPage ? remote.lastPage : existing.lastPage;
        final maxPages = remote.totalPages > existing.totalPages ? remote.totalPages : existing.totalPages;
        final newerTime = remote.lastReadAt.isAfter(existing.lastReadAt) ? remote.lastReadAt : existing.lastReadAt;
        final thumb = existing.coverThumbnailUrl ?? remote.coverThumbnailUrl;

        _histories[remote.id] = ComicReadingHistory(
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
      }
    }
    await _persist();
    notifyListeners();
    return recentList;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _histories.values.map((e) => e.toJson()).toList();
    await prefs.setString(_storageKey, jsonEncode(list));
  }
}
