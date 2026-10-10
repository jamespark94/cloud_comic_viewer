import 'dart:typed_data';
import '../utils/image_dimension_utils.dart';

class ComicPage {
  final int index;
  final String name;
  final String? filePath;
  Uint8List? _cachedBytes;
  final Future<Uint8List> Function()? byteGetter;
  ImageDimensions? _dimensions;

  ComicPage({
    required this.index,
    required this.name,
    this.filePath,
    Uint8List? initialBytes,
    this.byteGetter,
  }) : _cachedBytes = initialBytes {
    if (initialBytes != null) {
      _dimensions = ImageDimensionUtils.parse(initialBytes);
    }
  }

  bool get hasBytes => _cachedBytes != null;
  Uint8List? get cachedBytes => _cachedBytes;
  ImageDimensions? get dimensions => _dimensions;
  double get aspectRatio => _dimensions?.aspectRatio ?? 1.0;
  bool get isWide => _dimensions?.isWide ?? false;

  Future<Uint8List> getBytes() async {
    if (_cachedBytes != null) return _cachedBytes!;
    if (byteGetter != null) {
      _cachedBytes = await byteGetter!();
      if (_cachedBytes != null && _dimensions == null) {
        _dimensions = ImageDimensionUtils.parse(_cachedBytes!);
      }
      return _cachedBytes!;
    }
    throw StateError('ComicPage has no byte source');
  }

  void updateDimensions(ImageDimensions dims) {
    _dimensions = dims;
  }

  void clearCache() {
    if (byteGetter != null) {
      _cachedBytes = null;
    }
  }
}

