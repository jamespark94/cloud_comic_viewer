import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import '../models/comic_page.dart';
import '../utils/natural_sort_utils.dart';

class ComicArchiveService {
  static final Set<String> _supportedImageExts = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.bmp',
    '.avif',
  };

  static bool isImageFileName(String fileName) {
    final lower = fileName.toLowerCase();
    return _supportedImageExts.any((ext) => lower.endsWith(ext));
  }

  /// ZIP/CBZ 아카이브 바이트에서 만화 페이지 목록을 파싱하여 반환합니다.
  static Future<List<ComicPage>> extractPagesFromZipBytes(Uint8List zipBytes) async {
    // 백그라운드 compute 대신 빠른 메모리 파싱 (필요 시 isolate 분리 가능)
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final List<ArchiveFile> imageFiles = [];

    for (final file in archive.files) {
      if (file.isFile && !file.name.startsWith('__MACOSX') && isImageFileName(file.name)) {
        imageFiles.add(file);
      }
    }

    // 파일 이름 자연어 정렬 (Natural Sort Order)
    imageFiles.sort((a, b) => NaturalSortUtils.compare(a.name, b.name));

    final List<ComicPage> pages = [];
    for (int i = 0; i < imageFiles.length; i++) {
      final archFile = imageFiles[i];
      final pageBytes = archFile.content;

      pages.add(
        ComicPage(
          index: i,
          name: archFile.name.split('/').last,
          initialBytes: pageBytes,
        ),
      );
    }

    return pages;
  }

  /// 로컬 파일 시스템의 ZIP/CBZ 파일에서 페이지 목록 추출
  static Future<List<ComicPage>> extractPagesFromZipFile(File file) async {
    final bytes = await file.readAsBytes();
    return extractPagesFromZipBytes(bytes);
  }

  /// 로컬 디렉토리(이미지 파일들이 모여있는 폴더)에서 페이지 목록 생성
  static Future<List<ComicPage>> extractPagesFromDirectory(Directory dir) async {
    final entities = dir.listSync(followLinks: false);
    final List<FileSystemEntity> imageFiles = [];

    for (final e in entities) {
      if (e is File && isImageFileName(e.path)) {
        imageFiles.add(e);
      }
    }

    imageFiles.sort((a, b) => NaturalSortUtils.compare(
      a.path.split(Platform.pathSeparator).last,
      b.path.split(Platform.pathSeparator).last,
    ));

    final List<ComicPage> pages = [];
    for (int i = 0; i < imageFiles.length; i++) {
      final file = imageFiles[i] as File;
      final fileName = file.path.split(Platform.pathSeparator).last;
      pages.add(
        ComicPage(
          index: i,
          name: fileName,
          filePath: file.path,
          byteGetter: () => file.readAsBytes(),
        ),
      );
    }

    return pages;
  }

  /// 압축 파일에서 첫 번째 표지(썸네일) 이미지만 빠르게 추출
  static Uint8List? extractCoverThumbnail(Uint8List zipBytes) {
    try {
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final List<ArchiveFile> imageFiles = [];
      for (final file in archive.files) {
        if (file.isFile && !file.name.startsWith('__MACOSX') && isImageFileName(file.name)) {
          imageFiles.add(file);
        }
      }
      if (imageFiles.isEmpty) return null;
      imageFiles.sort((a, b) => NaturalSortUtils.compare(a.name, b.name));
      return imageFiles.first.content;
    } catch (_) {}
    return null;
  }
}
