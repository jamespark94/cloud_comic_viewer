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

  /// 만화책 압축 파일 형식 판별 (.zip, .cbz, .rar, .cbr, .7z, .tar, .pdf 등)
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

  /// 만화책 뷰어에서 열 수 있는 미디어인지 여부
  bool get isViewable => isComicArchive || isImage;

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
