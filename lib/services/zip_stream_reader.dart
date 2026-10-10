import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import '../models/comic_page.dart';
import '../models/media_item.dart';
import '../utils/natural_sort_utils.dart';
import 'cloud_service_interface.dart';
import 'comic_archive_service.dart';

class ZipEntryMeta {
  final String name;
  final int compressionMethod; // 0 = Store, 8 = Deflate
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;

  ZipEntryMeta({
    required this.name,
    required this.compressionMethod,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });
}

abstract class RangeByteReader {
  Future<int> getTotalLength();
  Future<Uint8List> readRange(int start, int end);
  void close();
}

class LocalFileRangeReader implements RangeByteReader {
  final File file;
  int? _length;

  LocalFileRangeReader(this.file);

  @override
  Future<int> getTotalLength() async {
    if (_length != null) return _length!;
    _length = await file.length();
    return _length!;
  }

  @override
  Future<Uint8List> readRange(int start, int end) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(start);
      final count = end - start + 1;
      final bytes = await raf.read(count);
      return bytes;
    } finally {
      await raf.close();
    }
  }

  @override
  void close() {}
}

class HttpCloudRangeReader implements RangeByteReader {
  final CloudService service;
  final MediaItem item;
  String? _streamUrl;
  Map<String, String>? _headers;
  int? _totalLength;
  final http.Client _client = http.Client();

  HttpCloudRangeReader(this.service, this.item);

  Future<void> _initUrlAndHeaders() async {
    if (_streamUrl == null) {
      await service.refreshTokensIfNeeded();
      _streamUrl = await service.getStreamUrl(item);
      _headers = await service.getStreamHeaders();
    }
  }

  @override
  Future<int> getTotalLength() async {
    if (_totalLength != null && _totalLength! > 0) return _totalLength!;
    if (item.size != null && item.size! > 0) {
      _totalLength = item.size;
      return _totalLength!;
    }

    await _initUrlAndHeaders();
    // 0-0 range 요청으로 Content-Range 헤더에서 전체 길이 파악
    final req = http.Request('GET', Uri.parse(_streamUrl!));
    req.headers.addAll(_headers ?? {});
    req.headers['Range'] = 'bytes=0-0';

    final res = await _client.send(req);
    final contentRange = res.headers['content-range'];
    if (contentRange != null) {
      // Content-Range: bytes 0-0/1234567
      final match = RegExp(r'/(\d+)').firstMatch(contentRange);
      if (match != null) {
        _totalLength = int.parse(match.group(1)!);
        return _totalLength!;
      }
    }

    final cl = res.headers['content-length'];
    if (cl != null) {
      _totalLength = int.tryParse(cl);
      if (_totalLength != null) return _totalLength!;
    }

    throw Exception('파일 전체 크기를 확인할 수 없습니다.');
  }

  @override
  Future<Uint8List> readRange(int start, int end) async {
    await _initUrlAndHeaders();
    final req = http.Request('GET', Uri.parse(_streamUrl!));
    req.headers.addAll(_headers ?? {});
    req.headers['Range'] = 'bytes=$start-$end';

    final streamedRes = await _client.send(req);
    if (streamedRes.statusCode == 206) {
      final bytes = await streamedRes.stream.toBytes();
      return bytes;
    } else if (streamedRes.statusCode == 200 && start == 0 && end >= (streamedRes.contentLength ?? 0) - 1) {
      return await streamedRes.stream.toBytes();
    } else {
      throw Exception('Range 요청 실패: HTTP ${streamedRes.statusCode}');
    }
  }

  @override
  void close() {
    _client.close();
  }
}

class ZipStreamReader {
  /// Range 요청을 통해 ZIP 파일 전체를 다운로드하지 않고 목차 및 페이지 목록을 즉시 파싱합니다.
  static Future<List<ComicPage>> extractPagesStreamed({
    required CloudService service,
    required MediaItem item,
  }) async {
    final RangeByteReader reader = service.account.id == 'local'
        ? LocalFileRangeReader(File(item.id))
        : HttpCloudRangeReader(service, item);

    try {
      final totalLength = await reader.getTotalLength();
      if (totalLength < 22) {
        throw Exception('잘못된 ZIP 파일 크기입니다.');
      }

      // 1. EOCD(End of Central Directory) 검색 (파일 끝 최대 65KB 읽기)
      final readSize = min(65557, totalLength);
      final eocdStart = totalLength - readSize;
      final tailBytes = await reader.readRange(eocdStart, totalLength - 1);

      int eocdOffsetInTail = -1;
      for (int i = tailBytes.length - 22; i >= 0; i--) {
        if (tailBytes[i] == 0x50 &&
            tailBytes[i + 1] == 0x4b &&
            tailBytes[i + 2] == 0x05 &&
            tailBytes[i + 3] == 0x06) {
          eocdOffsetInTail = i;
          break;
        }
      }

      if (eocdOffsetInTail == -1) {
        throw Exception('ZIP EOCD 시그니처를 찾을 수 없습니다.');
      }

      final ByteData tailData = ByteData.sublistView(tailBytes);
      final cdSize = tailData.getUint32(eocdOffsetInTail + 12, Endian.little);
      final cdOffset = tailData.getUint32(eocdOffsetInTail + 16, Endian.little);

      // 2. Central Directory 버퍼 Range 읽기
      final cdBytes = await reader.readRange(cdOffset, cdOffset + cdSize - 1);
      final ByteData cdData = ByteData.sublistView(cdBytes);

      final List<ZipEntryMeta> entries = [];
      int pos = 0;

      while (pos + 46 <= cdBytes.length) {
        if (cdBytes[pos] != 0x50 ||
            cdBytes[pos + 1] != 0x4b ||
            cdBytes[pos + 2] == 0x01 && cdBytes[pos + 3] != 0x02) {
          // Central Directory signature 0x02014b50
        }
        final sig = cdData.getUint32(pos, Endian.little);
        if (sig != 0x02014b50) break;

        final method = cdData.getUint16(pos + 10, Endian.little);
        final compressedSize = cdData.getUint32(pos + 20, Endian.little);
        final uncompressedSize = cdData.getUint32(pos + 24, Endian.little);
        final nameLen = cdData.getUint16(pos + 28, Endian.little);
        final extraLen = cdData.getUint16(pos + 30, Endian.little);
        final commentLen = cdData.getUint16(pos + 32, Endian.little);
        final localHeaderOffset = cdData.getUint32(pos + 42, Endian.little);

        final nameBytes = cdBytes.sublist(pos + 46, pos + 46 + nameLen);
        String fileName;
        try {
          fileName = utf8.decode(nameBytes);
        } catch (_) {
          fileName = String.fromCharCodes(nameBytes);
        }

        if (!fileName.startsWith('__MACOSX') &&
            !fileName.endsWith('/') &&
            ComicArchiveService.isImageFileName(fileName)) {
          entries.add(
            ZipEntryMeta(
              name: fileName,
              compressionMethod: method,
              compressedSize: compressedSize,
              uncompressedSize: uncompressedSize,
              localHeaderOffset: localHeaderOffset,
            ),
          );
        }

        pos += 46 + nameLen + extraLen + commentLen;
      }

      // 자연어 정렬 (Natural Sort Order)
      entries.sort((a, b) => NaturalSortUtils.compare(a.name, b.name));

      final List<ComicPage> pages = [];
      for (int i = 0; i < entries.length; i++) {
        final meta = entries[i];
        final pageName = meta.name.split('/').last;

        pages.add(
          ComicPage(
            index: i,
            name: pageName,
            byteGetter: () => _fetchPageBytes(reader, meta),
          ),
        );
      }

      return pages;
    } catch (e) {
      reader.close();
      rethrow;
    }
  }

  /// 개별 페이지의 데이터 블록만 HTTP Range로 가져와 압축 해제합니다.
  static Future<Uint8List> _fetchPageBytes(RangeByteReader reader, ZipEntryMeta meta) async {
    // 1. Local Header의 extra field 길이를 정확히 파악하기 위해 30바이트 읽기
    final localHdrBytes = await reader.readRange(
      meta.localHeaderOffset,
      meta.localHeaderOffset + 29,
    );
    final ByteData hdrData = ByteData.sublistView(localHdrBytes);
    final localNameLen = hdrData.getUint16(26, Endian.little);
    final localExtraLen = hdrData.getUint16(28, Endian.little);

    final dataStart = meta.localHeaderOffset + 30 + localNameLen + localExtraLen;
    final dataEnd = dataStart + meta.compressedSize - 1;

    // 2. 압축된 이미지 데이터 블록만 Range 읽기
    final compressedBytes = await reader.readRange(dataStart, dataEnd);

    // 3. 압축 방식에 따라 디코딩
    if (meta.compressionMethod == 0) {
      // Store (무압축)
      return compressedBytes;
    } else if (meta.compressionMethod == 8) {
      // Deflate 압축 해제
      return Inflate(compressedBytes).getBytes();
    } else {
      throw Exception('지원되지 않는 압축 방식입니다: ${meta.compressionMethod}');
    }
  }
}
