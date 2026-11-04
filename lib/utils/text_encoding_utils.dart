import 'dart:convert';
import 'dart:typed_data';
import 'package:charset_converter/charset_converter.dart';
import 'package:fast_gbk/fast_gbk.dart';

class DecodedTextResult {
  final String text;
  final String encoding;

  const DecodedTextResult({
    required this.text,
    required this.encoding,
  });
}

class TextEncodingUtils {
  static const List<String> supportedEncodings = [
    'AUTO',
    'UTF-8',
    'CP949',
    'EUC-KR',
    'UTF-16LE',
    'UTF-16BE',
    'GBK',
  ];

  /// 바이트 배열이 엄격한 UTF-8인지 검사합니다.
  static bool isStrictUtf8(Uint8List bytes) {
    try {
      utf8.decode(bytes, allowMalformed: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 텍스트 바이트 배열을 자동 감지 또는 지정된 인코딩으로 디코딩하여 반환합니다.
  static Future<DecodedTextResult> decodeBytes(
    List<int> rawBytes, {
    String? forceEncoding,
  }) async {
    final u8Bytes = rawBytes is Uint8List ? rawBytes : Uint8List.fromList(rawBytes);
    if (u8Bytes.isEmpty) {
      return const DecodedTextResult(text: '', encoding: 'UTF-8');
    }

    final forced = forceEncoding?.toUpperCase();
    if (forced != null && forced != 'AUTO') {
      final decoded = await _decodeWithSpecificEncoding(u8Bytes, forced);
      return DecodedTextResult(text: decoded, encoding: forced);
    }

    // 1. UTF-8 BOM (EF BB BF) 확인
    if (u8Bytes.length >= 3 &&
        u8Bytes[0] == 0xEF &&
        u8Bytes[1] == 0xBB &&
        u8Bytes[2] == 0xBF) {
      return DecodedTextResult(
        text: utf8.decode(u8Bytes.sublist(3), allowMalformed: true),
        encoding: 'UTF-8 (BOM)',
      );
    }

    // 2. UTF-16 LE BOM (FF FE) 확인
    if (u8Bytes.length >= 2 && u8Bytes[0] == 0xFF && u8Bytes[1] == 0xFE) {
      return DecodedTextResult(
        text: _decodeUtf16Le(u8Bytes.sublist(2)),
        encoding: 'UTF-16LE',
      );
    }

    // 3. UTF-16 BE BOM (FE FF) 확인
    if (u8Bytes.length >= 2 && u8Bytes[0] == 0xFE && u8Bytes[1] == 0xFF) {
      return DecodedTextResult(
        text: _decodeUtf16Be(u8Bytes.sublist(2)),
        encoding: 'UTF-16BE',
      );
    }

    // 4. 엄격한 UTF-8 검증
    if (isStrictUtf8(u8Bytes)) {
      return DecodedTextResult(
        text: utf8.decode(u8Bytes, allowMalformed: false),
        encoding: 'UTF-8',
      );
    }

    // 5. 한국어 레거시 인코딩 (CP949 / EUC-KR) 시도
    try {
      final cp949Str = await CharsetConverter.decode('cp949', u8Bytes);
      if (cp949Str.isNotEmpty && _looksLikeValidKoreanText(cp949Str)) {
        return DecodedTextResult(text: cp949Str, encoding: 'CP949');
      }
    } catch (_) {}

    try {
      final eucKrStr = await CharsetConverter.decode('euc-kr', u8Bytes);
      if (eucKrStr.isNotEmpty) {
        return DecodedTextResult(text: eucKrStr, encoding: 'EUC-KR');
      }
    } catch (_) {}

    // 6. GBK (중국어 및 한자 텍스트 호환 - fast_gbk 순수 다트 폴백 포함)
    try {
      final gbkStr = gbk.decode(u8Bytes, allowMalformed: true);
      if (gbkStr.isNotEmpty) {
        return DecodedTextResult(text: gbkStr, encoding: 'GBK');
      }
    } catch (_) {}

    // 7. 최종 폴백: UTF-8 allowMalformed
    return DecodedTextResult(
      text: utf8.decode(u8Bytes, allowMalformed: true),
      encoding: 'UTF-8',
    );
  }

  static Future<String> _decodeWithSpecificEncoding(Uint8List bytes, String encoding) async {
    switch (encoding) {
      case 'UTF-8':
        if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
          return utf8.decode(bytes.sublist(3), allowMalformed: true);
        }
        return utf8.decode(bytes, allowMalformed: true);
      case 'CP949':
        try {
          return await CharsetConverter.decode('cp949', bytes);
        } catch (_) {
          return gbk.decode(bytes, allowMalformed: true);
        }
      case 'EUC-KR':
        try {
          return await CharsetConverter.decode('euc-kr', bytes);
        } catch (_) {
          return utf8.decode(bytes, allowMalformed: true);
        }
      case 'UTF-16LE':
        final offset = (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) ? 2 : 0;
        return _decodeUtf16Le(bytes.sublist(offset));
      case 'UTF-16BE':
        final offset = (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) ? 2 : 0;
        return _decodeUtf16Be(bytes.sublist(offset));
      case 'GBK':
        return gbk.decode(bytes, allowMalformed: true);
      default:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static bool _looksLikeValidKoreanText(String text) {
    final sample = text.length > 4000 ? text.substring(0, 4000) : text;
    final hangulMatches = RegExp(r'[\uAC00-\uD7A3]').allMatches(sample).length;
    return hangulMatches >= 3 || sample.isNotEmpty;
  }

  static String _decodeUtf16Le(Uint8List bytes) {
    final len = bytes.length ~/ 2;
    final codeUnits = Uint16List(len);
    final bd = ByteData.sublistView(bytes);
    for (int i = 0; i < len; i++) {
      codeUnits[i] = bd.getUint16(i * 2, Endian.little);
    }
    return String.fromCharCodes(codeUnits);
  }

  static String _decodeUtf16Be(Uint8List bytes) {
    final len = bytes.length ~/ 2;
    final codeUnits = Uint16List(len);
    final bd = ByteData.sublistView(bytes);
    for (int i = 0; i < len; i++) {
      codeUnits[i] = bd.getUint16(i * 2, Endian.big);
    }
    return String.fromCharCodes(codeUnits);
  }
}
