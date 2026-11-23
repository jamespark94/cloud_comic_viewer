import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

class BubbleColors {
  final Color backgroundColor;
  final Color textColor;

  const BubbleColors({
    required this.backgroundColor,
    required this.textColor,
  });
}

/// 말풍선 바운딩 박스 테두리 링(Perimeter Ring) 픽셀을 샘플링하여
/// 원본 말풍선의 배경 대표색과 고대비 텍스트 색상을 자동 추정합니다.
class BubbleColorSampler {
  /// 인코딩된 이미지 바이트(JPEG/PNG/WebP 등)에서 말풍선별 배경색과 글자색을 추출합니다.
  static Future<List<BubbleColors>> sampleColors({
    required Uint8List imageBytes,
    required List<Rect> normalizedRects,
  }) async {
    if (normalizedRects.isEmpty) return const [];

    ui.Image? decoded;
    try {
      decoded = await _decodeImage(imageBytes);
      final byteData = await decoded.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) {
        return List.filled(
          normalizedRects.length,
          const BubbleColors(
            backgroundColor: Colors.white,
            textColor: Color(0xFF141414),
          ),
        );
      }

      final rgba = byteData.buffer.asUint8List();
      final w = decoded.width;
      final h = decoded.height;
      return normalizedRects
          .map((rect) => sampleFromRgbaBytes(rgba, w, h, rect))
          .toList();
    } catch (_) {
      return List.filled(
        normalizedRects.length,
        const BubbleColors(
          backgroundColor: Colors.white,
          textColor: Color(0xFF141414),
        ),
      );
    } finally {
      decoded?.dispose();
    }
  }

  /// RGBA raw 픽셀 버퍼에서 단일 말풍선 테두리 24포인트를 샘플링합니다.
  static BubbleColors sampleFromRgbaBytes(
    Uint8List rgba,
    int width,
    int height,
    Rect normalizedRect,
  ) {
    if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
      return const BubbleColors(
        backgroundColor: Colors.white,
        textColor: Color(0xFF141414),
      );
    }

    final left = (normalizedRect.left * width).round().clamp(0, width - 1);
    final right = (normalizedRect.right * width).round().clamp(0, width - 1);
    final top = (normalizedRect.top * height).round().clamp(0, height - 1);
    final bottom = (normalizedRect.bottom * height).round().clamp(0, height - 1);

    final boxW = (right - left).clamp(1, width);
    final boxH = (bottom - top).clamp(1, height);

    // 테두리에서 안쪽으로 5% 지점 링 샘플링 (총 24포인트: 상6 + 하6 + 좌6 + 우6)
    final insetX = (boxW * 0.05).round();
    final insetY = (boxH * 0.05).round();

    final innerL = (left + insetX).clamp(0, width - 1);
    final innerR = (right - insetX).clamp(0, width - 1);
    final innerT = (top + insetY).clamp(0, height - 1);
    final innerB = (bottom - insetY).clamp(0, height - 1);

    final samples = <Color>[];
    const steps = 6;
    for (int i = 0; i < steps; i++) {
      final frac = (i + 0.5) / steps;
      final sx = (innerL + ((innerR - innerL) * frac)).round().clamp(0, width - 1);
      final sy = (innerT + ((innerB - innerT) * frac)).round().clamp(0, height - 1);

      samples.add(_readPixel(rgba, width, sx, innerT));
      samples.add(_readPixel(rgba, width, sx, innerB));
      samples.add(_readPixel(rgba, width, innerL, sy));
      samples.add(_readPixel(rgba, width, innerR, sy));
    }

    if (samples.isEmpty) {
      return const BubbleColors(
        backgroundColor: Colors.white,
        textColor: Color(0xFF141414),
      );
    }

    // 명도(Luminance) 기준 정렬 후 검은 잉크/흰 잉크 아웃라이어 배제
    samples.sort((a, b) => a.computeLuminance().compareTo(b.computeLuminance()));

    final brightCount = samples.where((c) => c.computeLuminance() >= 0.5).length;
    final isLightBubble = brightCount >= samples.length / 2;

    // 밝은 말풍선이면 상위 70% 분위수 색상(검은 글씨 획 제거), 어두운 말풍선이면 하위 30% 분위수 색상(흰 글씨 획 제거)
    final targetIdx = isLightBubble
        ? ((samples.length - 1) * 0.70).round().clamp(0, samples.length - 1)
        : ((samples.length - 1) * 0.30).round().clamp(0, samples.length - 1);

    final picked = samples[targetIdx];
    final lum = picked.computeLuminance();

    // 거의 순백 또는 순흑이면 깔끔한 만화 식자용 색으로 정규화
    final bgColor = lum > 0.90
        ? const Color(0xFFFCFCFC)
        : (lum < 0.12 ? const Color(0xFF141414) : Color.fromARGB(255, (picked.r * 255).round(), (picked.g * 255).round(), (picked.b * 255).round()));

    final textColor = bgColor.computeLuminance() > 0.45
        ? const Color(0xFF141414)
        : const Color(0xFFF5F5F5);

    return BubbleColors(backgroundColor: bgColor, textColor: textColor);
  }

  static Color _readPixel(Uint8List rgba, int width, int x, int y) {
    final offset = (y * width + x) * 4;
    return Color.fromARGB(
      rgba[offset + 3],
      rgba[offset],
      rgba[offset + 1],
      rgba[offset + 2],
    );
  }

  static Future<ui.Image> _decodeImage(Uint8List bytes) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    return completer.future;
  }
}
