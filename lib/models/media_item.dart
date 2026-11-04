/// 미디어/전자책 포맷 구분 열거형
enum MediaBookType {
  comicArchive, // .zip, .cbz, .rar, .cbr, .7z, .tar
  image,        // .jpg, .png, .webp 등
  txt,          // .txt, .md
  epub,         // .epub
  pdf,          // .pdf
  unknown,
}

class MediaItem {
  final String id;
  final String name;
  final String? parentId;
  final bool isFolder;
  final int? size;
  final String? mimeType;
  final String? thumbnailUrl;
  final String? directStreamUrl;
  final DateTime? modifiedTime;

  MediaItem({
    required this.id,
    required this.name,
    this.parentId,
    required this.isFolder,
    this.size,
    this.mimeType,
    this.thumbnailUrl,
    this.directStreamUrl,
    this.modifiedTime,
  });

  /// 만화책 압축 파일 형식 판별 (.zip, .cbz, .rar, .cbr, .7z, .tar)
  bool get isComicArchive {
    if (isFolder) return false;
    final lowerName = name.toLowerCase();
    return lowerName.endsWith('.zip') ||
        lowerName.endsWith('.cbz') ||
        lowerName.endsWith('.rar') ||
        lowerName.endsWith('.cbr') ||
        lowerName.endsWith('.7z') ||
        lowerName.endsWith('.tar');
  }

  /// 단일 이미지 파일 형식 판별
  bool get isImage {
    if (isFolder) return false;
    final lowerName = name.toLowerCase();
    if (lowerName.endsWith('.jpg') ||
        lowerName.endsWith('.jpeg') ||
        lowerName.endsWith('.png') ||
        lowerName.endsWith('.webp') ||
        lowerName.endsWith('.gif') ||
        lowerName.endsWith('.avif') ||
        lowerName.endsWith('.bmp')) {
      return true;
    }
    if (mimeType != null && mimeType!.startsWith('image/')) {
      return true;
    }
    return false;
  }

  /// 텍스트(TXT/MD) 전자책 파일 판별
  bool get isTxt {
    if (isFolder) return false;
    final lowerName = name.toLowerCase();
    if (lowerName.endsWith('.txt') || lowerName.endsWith('.md')) {
      return true;
    }
    if (mimeType != null && mimeType!.toLowerCase().startsWith('text/plain')) {
      return true;
    }
    return false;
  }

  /// EPUB 전자책 파일 판별
  bool get isEpub {
    if (isFolder) return false;
    final lowerName = name.toLowerCase();
    if (lowerName.endsWith('.epub')) {
      return true;
    }
    if (mimeType != null && mimeType!.toLowerCase().contains('epub')) {
      return true;
    }
    return false;
  }

  /// PDF 문서/만화 파일 판별
  bool get isPdf {
    if (isFolder) return false;
    final lowerName = name.toLowerCase();
    if (lowerName.endsWith('.pdf')) {
      return true;
    }
    if (mimeType != null && mimeType!.toLowerCase() == 'application/pdf') {
      return true;
    }
    return false;
  }

  /// 전자책(TXT, EPUB, PDF) 여부
  bool get isEbook => isTxt || isEpub || isPdf;

  /// 뷰어에서 열 수 있는 미디어(만화 + 이미지 + 전자책)인지 여부
  bool get isViewable => isComicArchive || isImage || isEbook;

  /// 미디어/전자책의 상세 포맷 타입 반환
  MediaBookType get bookType {
    if (isEpub) return MediaBookType.epub;
    if (isTxt) return MediaBookType.txt;
    if (isPdf) return MediaBookType.pdf;
    if (isComicArchive) return MediaBookType.comicArchive;
    if (isImage) return MediaBookType.image;
    return MediaBookType.unknown;
  }

  /// UI 배지 텍스트 반환
  String get formatBadgeLabel {
    switch (bookType) {
      case MediaBookType.epub:
        return 'EPUB';
      case MediaBookType.txt:
        return 'TXT';
      case MediaBookType.pdf:
        return 'PDF';
      case MediaBookType.comicArchive:
        return 'COMIC';
      case MediaBookType.image:
        return 'IMG';
      case MediaBookType.unknown:
        return 'FILE';
    }
  }

  String get formattedSize {
    if (size == null || size == 0) return '';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double dSize = size!.toDouble();
    while (dSize >= 1024 && i < suffixes.length - 1) {
      dSize /= 1024;
      i++;
    }
    return '${dSize.toStringAsFixed(1)} ${suffixes[i]}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'parentId': parentId,
        'isFolder': isFolder,
        'size': size,
        'mimeType': mimeType,
        'thumbnailUrl': thumbnailUrl,
        'directStreamUrl': directStreamUrl,
        'modifiedTime': modifiedTime?.toIso8601String(),
      };

  MediaItem copyWith({
    String? id,
    String? name,
    String? parentId,
    bool? isFolder,
    int? size,
    String? mimeType,
    String? thumbnailUrl,
    String? directStreamUrl,
    DateTime? modifiedTime,
  }) {
    return MediaItem(
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      isFolder: isFolder ?? this.isFolder,
      size: size ?? this.size,
      mimeType: mimeType ?? this.mimeType,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      directStreamUrl: directStreamUrl ?? this.directStreamUrl,
      modifiedTime: modifiedTime ?? this.modifiedTime,
    );
  }

  factory MediaItem.fromJson(Map<String, dynamic> json) => MediaItem(
        id: json['id'] as String,
        name: json['name'] as String,
        parentId: json['parentId'] as String?,
        isFolder: json['isFolder'] as bool? ?? false,
        size: json['size'] as int?,
        mimeType: json['mimeType'] as String?,
        thumbnailUrl: json['thumbnailUrl'] as String?,
        directStreamUrl: json['directStreamUrl'] as String?,
        modifiedTime: json['modifiedTime'] != null
            ? DateTime.tryParse(json['modifiedTime'] as String)
            : null,
      );
}
