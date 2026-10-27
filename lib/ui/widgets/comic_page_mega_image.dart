import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../services/mega_storage_provider.dart';

/// 복호화된 MEGA 만화 페이지 이미지를 메모리에 캐싱하는 LRU 캐시
class MegaImageMemoryCache {
  static final MegaImageMemoryCache instance = MegaImageMemoryCache._();
  MegaImageMemoryCache._();

  final int maxEntries = 30; // 최대 30페이지 캐싱
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap<String, Uint8List>();

  Uint8List? get(String key) {
    final value = _cache.remove(key);
    if (value != null) {
      _cache[key] = value; // 최근 사용으로 갱신
    }
    return value;
  }

  void put(String key, Uint8List bytes) {
    if (_cache.containsKey(key)) {
      _cache.remove(key);
    } else if (_cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = bytes;
  }

  void clear() => _cache.clear();
}

/// MEGA 클라우드에서 개별 이미지 파일을 다운로드 + AES-128-CTR 복호화 후 렌더링하는 위젯
class ComicPageMegaImage extends StatefulWidget {
  final MegaStorageProvider provider;
  final String fileId;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;

  const ComicPageMegaImage({
    super.key,
    required this.provider,
    required this.fileId,
    this.fit = BoxFit.contain,
    this.placeholder,
    this.errorWidget,
  });

  @override
  State<ComicPageMegaImage> createState() => _ComicPageMegaImageState();
}

class _ComicPageMegaImageState extends State<ComicPageMegaImage> {
  Uint8List? _decryptedBytes;
  bool _isLoading = true;
  Object? _error;
  double _progress = 0.0;

  String get _cacheKey => '${widget.provider.account.id}:${widget.fileId}';

  @override
  void initState() {
    super.initState();
    _loadAndDecryptImage();
  }

  @override
  void didUpdateWidget(covariant ComicPageMegaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fileId != widget.fileId ||
        oldWidget.provider.account.id != widget.provider.account.id) {
      _loadAndDecryptImage();
    }
  }

  Future<void> _loadAndDecryptImage() async {
    // 1. 메모리 캐시 히트 확인
    final cached = MegaImageMemoryCache.instance.get(_cacheKey);
    if (cached != null) {
      if (mounted) {
        setState(() {
          _decryptedBytes = cached;
          _isLoading = false;
          _error = null;
        });
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _progress = 0.0;
    });

    try {
      // 2. MEGA 다운로드 + AES-128-CTR 복호화 수행
      final bytes = await widget.provider.getDecryptedFileBytes(
        widget.fileId,
        onProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() {
              _progress = (received / total).clamp(0.0, 1.0);
            });
          }
        },
      );

      // 3. 메모리 캐시 저장
      MegaImageMemoryCache.instance.put(_cacheKey, bytes);

      if (mounted) {
        setState(() {
          _decryptedBytes = bytes;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return widget.placeholder ??
          Center(
            child: SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                value: _progress > 0 ? _progress : null,
              ),
            ),
          );
    }

    if (_error != null || _decryptedBytes == null) {
      return widget.errorWidget ??
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.enhanced_encryption_outlined, size: 40, color: Colors.redAccent),
                const SizedBox(height: 8),
                Text(
                  'MEGA 이미지 복호화/로딩 실패\n($_error)',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _loadAndDecryptImage,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('다시 시도'),
                ),
              ],
            ),
          );
    }

    return Image.memory(
      _decryptedBytes!,
      fit: widget.fit,
      gaplessPlayback: true,
    );
  }
}
