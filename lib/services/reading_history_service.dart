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

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _histories.values.map((e) => e.toJson()).toList();
    await prefs.setString(_storageKey, jsonEncode(list));
  }
}
