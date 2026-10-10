import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/viewer_settings.dart';

class ViewerSettingsService extends ChangeNotifier {
  static const String _storageKey = 'comic_viewer_settings';
  static ViewerSettingsService? _instance;
  static ViewerSettingsService get instance => _instance ??= ViewerSettingsService._();

  ViewerSettings _settings = const ViewerSettings();

  ViewerSettingsService._();

  ViewerSettings get settings => _settings;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_storageKey);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        _settings = ViewerSettings.fromJson(jsonDecode(jsonStr));
      } catch (_) {
        _settings = const ViewerSettings();
      }
    }
    notifyListeners();
  }

  Future<void> updateSettings(ViewerSettings newSettings) async {
    _settings = newSettings;
    await _persist();
    notifyListeners();
  }

  Future<void> setReadingDirection(ReadingDirection direction) async {
    _settings = _settings.copyWith(readingDirection: direction);
    await _persist();
    notifyListeners();
  }

  Future<void> setViewerMode(ViewerMode mode) async {
    _settings = _settings.copyWith(viewerMode: mode);
    await _persist();
    notifyListeners();
  }

  Future<void> setFitMode(FitMode fit) async {
    _settings = _settings.copyWith(fitMode: fit);
    await _persist();
    notifyListeners();
  }

  Future<void> setTheme(ViewerTheme theme) async {
    _settings = _settings.copyWith(theme: theme);
    await _persist();
    notifyListeners();
  }

  Future<void> toggleKeepScreenOn() async {
    _settings = _settings.copyWith(keepScreenOn: !_settings.keepScreenOn);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_settings.toJson()));
  }
}
