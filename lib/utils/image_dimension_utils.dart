import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../models/viewer_settings.dart';

class ImageDimensions {
  final int width;
  final int height;

  const ImageDimensions(this.width, this.height);

  double get aspectRatio => height == 0 ? 1.0 : width / height;
  bool get isWide => aspectRatio > 1.05; // 가로가 세로보다 넓은 경우 (양면 스캔본)
}

class ImageDimensionUtils {
  /// 원본 크기(sourceSize), 뷰어 가용 크기(availableSize), FitMode, fitSmallImages 설정에 따라
  /// 비율을 유지하면서 화면에 맞춘 최종 표시 크기(destination Size)를 계산합니다.
  static Size calculateDisplaySize({
    required Size sourceSize,
    required Size availableSize,
    required FitMode fitMode,
    bool fitSmallImages = true,
    bool isWebtoon = false,
  }) {
    if (sourceSize.width <= 0 || sourceSize.height <= 0) {
      return availableSize;
    }

    final double aspect = sourceSize.width / sourceSize.height;

    // 1. 웹툰 모드 (세로 스크롤, 높이 무한대)
    if (isWebtoon || availableSize.height.isInfinite) {
      final availW = availableSize.width;
      if (sourceSize.width < availW) {
        if (fitSmallImages) {
          // 원본 가로가 화면보다 작으면 가로 폭에 맞추면서 비율 유지 확대
          return Size(availW, availW / aspect);
        } else {
          return sourceSize;
        }
      } else {
        // 원본 가로가 화면보다 크면 가로 폭에 맞추어 축소
        return Size(availW, availW / aspect);
      }
    }

    // 2. 페이지 모드 (가용 영역 가로/세로 유한함)
    final availW = availableSize.width;
    final availH = availableSize.height;

    switch (fitMode) {
      case FitMode.fitWidth:
        if (fitSmallImages || sourceSize.width > availW) {
          return Size(availW, availW / aspect);
        }
        return sourceSize;

      case FitMode.fitHeight:
        if (fitSmallImages || sourceSize.height > availH) {
          return Size(availH * aspect, availH);
        }
        return sourceSize;

      case FitMode.contain:
        final boxFit = fitSmallImages ? BoxFit.contain : BoxFit.scaleDown;
        final fitted = applyBoxFit(boxFit, sourceSize, availableSize);
        return fitted.destination;
    }
  }
  /// 이미지 바이트의 헤더를 읽어 width와 height를 즉시 반환합니다.
  /// 지원 포맷: PNG, JPEG, GIF, WebP, BMP
  static ImageDimensions? parse(Uint8List bytes) {
    if (bytes.length < 10) return null;

    // 1. PNG: 89 50 4E 47 0D 0A 1A 0A
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      final bd = ByteData.sublistView(bytes);
      // IHDR 청크 시작은 12 (4 바이트 청크 길이 + 4 바이트 청크 타입 IHDR)
      // width: 16-19, height: 20-23 (Big Endian)
      final w = bd.getUint32(16, Endian.big);
      final h = bd.getUint32(20, Endian.big);
      return ImageDimensions(w, h);
    }

    // 2. GIF: "GIF87a" 또는 "GIF89a"
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getUint16(6, Endian.little);
      final h = bd.getUint16(8, Endian.little);
      return ImageDimensions(w, h);
    }

    // 3. BMP: "BM"
    if (bytes[0] == 0x42 && bytes[1] == 0x4D && bytes.length >= 26) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getUint32(18, Endian.little);
      final h = bd.getUint32(22, Endian.little).abs();
      return ImageDimensions(w, h);
    }

    // 4. WebP: "RIFF" .... "WEBP"
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
      final bd = ByteData.sublistView(bytes);
      // VP8 (Simple lossy)
      if (bytes[12] == 0x56 && bytes[13] == 0x50 && bytes[14] == 0x38 && bytes[15] == 0x20) {
        if (bytes.length >= 30) {
          final w = bd.getUint16(26, Endian.little) & 0x3fff;
          final h = bd.getUint16(28, Endian.little) & 0x3fff;
          return ImageDimensions(w, h);
        }
      }
      // VP8L (Lossless)
      if (bytes[12] == 0x56 && bytes[13] == 0x50 && bytes[14] == 0x38 && bytes[15] == 0x4C) {
        if (bytes.length >= 25) {
          final b1 = bytes[21];
          final b2 = bytes[22];
          final b3 = bytes[23];
          final b4 = bytes[24];
          final w = 1 + (((b2 & 0x3F) << 8) | b1);
          final h = 1 + ((((b4 & 0xF) << 10) | (b3 << 2) | ((b2 & 0xC0) >> 6)));
          return ImageDimensions(w, h);
        }
      }
      // VP8X (Extended)
      if (bytes[12] == 0x56 && bytes[13] == 0x50 && bytes[14] == 0x38 && bytes[15] == 0x58) {
        if (bytes.length >= 30) {
          final w = 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16));
          final h = 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16));
          return ImageDimensions(w, h);
        }
      }
    }

    // 5. JPEG: FF D8
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      int offset = 2;
      final bd = ByteData.sublistView(bytes);
      while (offset + 4 < bytes.length) {
        if (bytes[offset] != 0xFF) {
          offset++;
          continue;
        }
        final marker = bytes[offset + 1];
        if (marker == 0xD9 || marker == 0xDA) {
          // EOI or SOS (Start of Scan) - 헤더 세그먼트 끝
          break;
        }
        if (offset + 4 > bytes.length) break;
        final length = bd.getUint16(offset + 2, Endian.big);

        // SOF0 (0xC0), SOF1 (0xC1), SOF2 (0xC2) 등 프레임 헤더
        if ((marker >= 0xC0 && marker <= 0xC3) || (marker >= 0xC5 && marker <= 0xC7) ||
            (marker >= 0xC9 && marker <= 0xCB) || (marker >= 0xCD && marker <= 0xCF)) {
          if (offset + 9 <= bytes.length) {
            final h = bd.getUint16(offset + 5, Endian.big);
            final w = bd.getUint16(offset + 7, Endian.big);
            return ImageDimensions(w, h);
          }
        }
        offset += 2 + length;
      }
    }

    return null;
  }
}
