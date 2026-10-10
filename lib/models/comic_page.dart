import 'dart:typed_data';

class ComicPage {
  final int index;
  final String name;
  final String? filePath;
  Uint8List? _cachedBytes;
  final Future<Uint8List> Function()? byteGetter;

  ComicPage({
    required this.index,
    required this.name,
    this.filePath,
    Uint8List? initialBytes,
    this.byteGetter,
  }) : _cachedBytes = initialBytes;

  bool get hasBytes => _cachedBytes != null;
  Uint8List? get cachedBytes => _cachedBytes;

  Future<Uint8List> getBytes() async {
    if (_cachedBytes != null) return _cachedBytes!;
    if (byteGetter != null) {
      _cachedBytes = await byteGetter!();
      return _cachedBytes!;
    }
    throw StateError('ComicPage has no byte source');
  }

  void clearCache() {
    if (byteGetter != null) {
      _cachedBytes = null;
    }
  }
}
