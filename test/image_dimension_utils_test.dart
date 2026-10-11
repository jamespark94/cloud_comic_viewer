import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_comic_viewer/models/viewer_settings.dart';
import 'package:cloud_comic_viewer/utils/image_dimension_utils.dart';

void main() {
  group('ImageDimensionUtils Tests', () {
    test('parses PNG dimensions correctly', () {
      // PNG header: 8-byte signature + 4 bytes len + "IHDR" + 4 bytes w (800) + 4 bytes h (1200)
      final bytes = Uint8List(32);
      bytes.setRange(0, 8, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      bytes.setRange(12, 16, [0x49, 0x48, 0x44, 0x52]); // IHDR
      ByteData.sublistView(bytes).setUint32(16, 800, Endian.big);
      ByteData.sublistView(bytes).setUint32(20, 1200, Endian.big);

      final dims = ImageDimensionUtils.parse(bytes)!;
      expect(dims.width, 800);
      expect(dims.height, 1200);
      expect(dims.aspectRatio, closeTo(800 / 1200, 0.001));
      expect(dims.isWide, isFalse);
    });

    test('detects wide PNG correctly (spread)', () {
      final bytes = Uint8List(32);
      bytes.setRange(0, 8, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      ByteData.sublistView(bytes).setUint32(16, 1600, Endian.big);
      ByteData.sublistView(bytes).setUint32(20, 1000, Endian.big);

      final dims = ImageDimensionUtils.parse(bytes)!;
      expect(dims.width, 1600);
      expect(dims.height, 1000);
      expect(dims.isWide, isTrue);
    });

    test('parses GIF dimensions correctly', () {
      final bytes = Uint8List(16);
      bytes.setRange(0, 6, [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]); // GIF89a
      ByteData.sublistView(bytes).setUint16(6, 640, Endian.little);
      ByteData.sublistView(bytes).setUint16(8, 480, Endian.little);
      final dims = ImageDimensionUtils.parse(bytes)!;
      expect(dims.width, 640);
      expect(dims.height, 480);
      expect(dims.isWide, isTrue);
    });

    test('parses JPEG dimensions correctly', () {
      final bytes = Uint8List(32);
      bytes[0] = 0xFF;
      bytes[1] = 0xD8; // SOI
      bytes[2] = 0xFF;
      bytes[3] = 0xC0; // SOF0
      ByteData.sublistView(bytes).setUint16(4, 15, Endian.big); // length
      bytes[6] = 8; // precision
      ByteData.sublistView(bytes).setUint16(7, 1920, Endian.big); // height
      ByteData.sublistView(bytes).setUint16(9, 1080, Endian.big); // width

      final dims = ImageDimensionUtils.parse(bytes)!;
      expect(dims.width, 1080);
      expect(dims.height, 1920);
      expect(dims.isWide, isFalse);
    });

    test('calculateDisplaySize scales up small image while preserving aspect ratio in contain mode', () {
      // 원본: 400x600, 화면: 1080x1920
      const source = Size(400, 600);
      const screen = Size(1080, 1920);

      final result = ImageDimensionUtils.calculateDisplaySize(
        sourceSize: source,
        availableSize: screen,
        fitMode: FitMode.contain,
        fitSmallImages: true,
      );

      // 1080 / 400 = 2.7 -> width: 1080, height: 1620 (비율 400/600 유지)
      expect(result.width, 1080);
      expect(result.height, 1620);
      expect(result.width / result.height, closeTo(400 / 600, 0.001));
    });

    test('calculateDisplaySize scales up small image to fitWidth', () {
      const source = Size(400, 800);
      const screen = Size(1080, 1920);

      final result = ImageDimensionUtils.calculateDisplaySize(
        sourceSize: source,
        availableSize: screen,
        fitMode: FitMode.fitWidth,
        fitSmallImages: true,
      );

      expect(result.width, 1080);
      expect(result.height, 2160);
      expect(result.width / result.height, closeTo(400 / 800, 0.001));
    });

    test('calculateDisplaySize keeps original size when fitSmallImages is false', () {
      const source = Size(400, 600);
      const screen = Size(1080, 1920);

      final result = ImageDimensionUtils.calculateDisplaySize(
        sourceSize: source,
        availableSize: screen,
        fitMode: FitMode.contain,
        fitSmallImages: false,
      );

      expect(result.width, 400);
      expect(result.height, 600);
    });

    test('calculateDisplaySize handles webtoon mode (unbounded height)', () {
      const source = Size(600, 1200);
      const screen = Size(1080, double.infinity);

      final result = ImageDimensionUtils.calculateDisplaySize(
        sourceSize: source,
        availableSize: screen,
        fitMode: FitMode.contain,
        fitSmallImages: true,
        isWebtoon: true,
      );

      expect(result.width, 1080);
      expect(result.height, 2160);
      expect(result.width / result.height, closeTo(600 / 1200, 0.001));
    });

    test('calculateDisplaySize scales down large image normally', () {
      const source = Size(2000, 3000);
      const screen = Size(1000, 2000);

      final result = ImageDimensionUtils.calculateDisplaySize(
        sourceSize: source,
        availableSize: screen,
        fitMode: FitMode.contain,
        fitSmallImages: true,
      );

      expect(result.width, 1000);
      expect(result.height, 1500);
      expect(result.width / result.height, closeTo(2000 / 3000, 0.001));
    });
  });
}
