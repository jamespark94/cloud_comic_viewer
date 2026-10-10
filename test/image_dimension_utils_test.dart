import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
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
  });
}
