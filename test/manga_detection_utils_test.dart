import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_comic_viewer/models/viewer_settings.dart';
import 'package:cloud_comic_viewer/utils/manga_detection_utils.dart';

void main() {
  group('MangaDetectionUtils Tests', () {
    test('detects Japanese characters in title', () {
      expect(MangaDetectionUtils.isLikelyJapaneseManga('ワンピース 第01巻.zip'), isTrue); // 히라가나 ぴ
      expect(MangaDetectionUtils.isLikelyJapaneseManga('ナルト 01.cbz'), isTrue); // 가타카나
      expect(MangaDetectionUtils.isLikelyJapaneseManga('일반 한국 만화 1권.zip'), isFalse);
    });

    test('detects manga tags in title', () {
      expect(MangaDetectionUtils.isLikelyJapaneseManga('Bleach [Manga] Vol 01.zip'), isTrue);
      expect(MangaDetectionUtils.isLikelyJapaneseManga('One Piece (RAW) c01.zip'), isTrue);
      expect(MangaDetectionUtils.isLikelyJapaneseManga('Attack on Titan [JP] v01.zip'), isTrue);
      expect(MangaDetectionUtils.isLikelyJapaneseManga('Spider-Man 01.cbz'), isFalse);
    });

    test('detects manga tags in parent folder', () {
      expect(MangaDetectionUtils.isLikelyJapaneseManga('01.zip', parentFolder: '[Manga] Naruto'), isTrue);
    });

    test('parses ComicInfo.xml correctly', () {
      const xml = '<?xml version="1.0"?><ComicInfo><Manga>YesAndRightToLeft</Manga></ComicInfo>';
      final dir = MangaDetectionUtils.parseComicInfoXml(Uint8List.fromList(utf8.encode(xml)));
      expect(dir, ReadingDirection.rightToLeft);
    });
  });
}
