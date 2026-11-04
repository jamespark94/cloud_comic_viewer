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

  Future<void> setDisplayMode(PageDisplayMode mode) async {
    _settings = _settings.copyWith(displayMode: mode);
    await _persist();
    notifyListeners();
  }

  Future<void> setPageNavigationMode(PageNavigationMode mode) async {
    _settings = _settings.copyWith(pageNavigationMode: mode);
    await _persist();
    notifyListeners();
  }

  Future<void> toggleKeepScreenOn() async {
    _settings = _settings.copyWith(keepScreenOn: !_settings.keepScreenOn);
    await _persist();
    notifyListeners();
  }

  Future<void> toggleFitSmallImages() async {
    _settings = _settings.copyWith(fitSmallImages: !_settings.fitSmallImages);
    await _persist();
    notifyListeners();
  }

  Future<void> setFitSmallImages(bool enable) async {
    _settings = _settings.copyWith(fitSmallImages: enable);
    await _persist();
    notifyListeners();
  }

  // 이북 조판 설정 헬퍼 메서드들
  Future<void> setEbookPageMode(EbookPageMode mode) async {
    _settings = _settings.copyWith(ebookPageMode: mode);
    await _persist();
    notifyListeners();
  }

  Future<void> setEbookFontSize(double size) async {
    _settings = _settings.copyWith(ebookFontSize: size.clamp(12.0, 40.0));
    await _persist();
    notifyListeners();
  }

  Future<void> setEbookLineHeight(double height) async {
    _settings = _settings.copyWith(ebookLineHeight: height.clamp(1.1, 2.8));
    await _persist();
    notifyListeners();
  }

  Future<void> setEbookParagraphSpacing(double spacing) async {
    _settings = _settings.copyWith(ebookParagraphSpacing: spacing.clamp(0.0, 36.0));
    await _persist();
    notifyListeners();
  }

  Future<void> setEbookMargins({double? horizontal, double? vertical}) async {
    _settings = _settings.copyWith(
      ebookHorizontalMargin: horizontal?.clamp(8.0, 64.0),
      ebookVerticalMargin: vertical?.clamp(8.0, 64.0),
    );
    await _persist();
    notifyListeners();
  }

  Future<void> setEbookFontFamily(String family) async {
    _settings = _settings.copyWith(ebookFontFamily: family);
    await _persist();
    notifyListeners();
  }

  Future<void> toggleEbookJustifyText() async {
    _settings = _settings.copyWith(ebookJustifyText: !_settings.ebookJustifyText);
    await _persist();
    notifyListeners();
  }

  Future<void> toggleEbookFirstLineIndent() async {
    _settings = _settings.copyWith(ebookFirstLineIndent: !_settings.ebookFirstLineIndent);
    await _persist();
    notifyListeners();
  }

  Future<void> toggleVolumeKeysForPageTurn() async {
    _settings = _settings.copyWith(useVolumeKeysForPageTurn: !_settings.useVolumeKeysForPageTurn);
    await _persist();
    notifyListeners();
  }

  Future<void> togglePdfDarkInvert() async {
    _settings = _settings.copyWith(pdfDarkInvert: !_settings.pdfDarkInvert);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_settings.toJson()));
  }
}
