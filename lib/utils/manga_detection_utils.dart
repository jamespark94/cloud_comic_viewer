import 'dart:convert';
import 'dart:typed_data';
import '../models/viewer_settings.dart';

class MangaDetectionUtils {
  // 히라가나(\u3040-\u309F) 및 가타카나(\u30A0-\u30FF) 정규식
  static final RegExp _japaneseCharRegex = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]');

  // 일본 만화 표기 키워드 (대소문자 무시)
  static final RegExp _mangaKeywordRegex = RegExp(
    r'(\[|\()(manga|raw|jp|jpn|jap|코믹스|망가|동인지)(\]|\))|manga|tankobon',
    caseSensitive: false,
  );

  /// 파일명 및 부모 폴더명을 분석하여 일본 만화(오른쪽➔왼쪽 넘김)인지 판별합니다.
  static bool isLikelyJapaneseManga(String title, {String? parentFolder}) {
    // 1. 파일명이나 폴더명에 일본어 문자(히라가나/가타카나)가 포함되어 있는 경우
    if (_japaneseCharRegex.hasMatch(title)) return true;
    if (parentFolder != null && _japaneseCharRegex.hasMatch(parentFolder)) return true;

    // 2. [Manga], [RAW], [JP] 등의 표준 만화 태그가 포함된 경우
    if (_mangaKeywordRegex.hasMatch(title)) return true;
    if (parentFolder != null && _mangaKeywordRegex.hasMatch(parentFolder)) return true;

    return false;
  }

  /// ComicInfo.xml 내용(바이트 또는 텍스트)에서 만화 읽기 방향을 파싱합니다.
  static ReadingDirection? parseComicInfoXml(Uint8List xmlBytes) {
    try {
      final xml = utf8.decode(xmlBytes, allowMalformed: true);
      // <Manga> 태그 파싱: Yes, YesAndRightToLeft, No
      final match = RegExp(r'<Manga>(.*?)<\/Manga>', caseSensitive: false).firstMatch(xml);
      if (match != null) {
        final val = match.group(1)?.trim().toLowerCase();
        if (val == 'yes' || val == 'yesandrighttoleft') {
          return ReadingDirection.rightToLeft;
        } else if (val == 'no') {
          return ReadingDirection.leftToRight;
        }
      }
    } catch (_) {}
    return null;
  }
}
