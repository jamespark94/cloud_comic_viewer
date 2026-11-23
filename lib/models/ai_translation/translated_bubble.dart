import 'package:flutter/material.dart';

/// 번역된 단일 말풍선(또는 텍스트 박스) 오버레이 모델
class TranslatedBubble {
  /// 원본 이미지 전체 크기 대비 정규화된 좌표 (left, top, right, bottom ∈ [0.0, 1.0])
  final Rect normalizedRect;

  /// 말풍선 단위로 병합된 원문 텍스트
  final String originalText;

  /// 한국어로 번역된 텍스트
  final String translatedText;

  /// 원본 말풍선 테두리 픽셀 샘플링으로 추정한 배경 대표색 (기본값: 흰색)
  final Color backgroundColor;

  /// 배경색의 명도(Luminance)에 따라 자동 결정된 고대비 글자색
  final Color textColor;

  /// 원본 텍스트가 세로쓰기(일본 만화 등)였는지 여부
  final bool isVerticalSource;

  const TranslatedBubble({
    required this.normalizedRect,
    required this.originalText,
    required this.translatedText,
    this.backgroundColor = Colors.white,
    this.textColor = const Color(0xFF141414),
    this.isVerticalSource = false,
  });

  TranslatedBubble copyWith({
    Rect? normalizedRect,
    String? originalText,
    String? translatedText,
    Color? backgroundColor,
    Color? textColor,
    bool? isVerticalSource,
  }) {
    return TranslatedBubble(
      normalizedRect: normalizedRect ?? this.normalizedRect,
      originalText: originalText ?? this.originalText,
      translatedText: translatedText ?? this.translatedText,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      textColor: textColor ?? this.textColor,
      isVerticalSource: isVerticalSource ?? this.isVerticalSource,
    );
  }

  Map<String, dynamic> toJson() => {
        'l': normalizedRect.left,
        't': normalizedRect.top,
        'r': normalizedRect.right,
        'b': normalizedRect.bottom,
        'orig': originalText,
        'trans': translatedText,
        'bg': backgroundColor.toARGB32(),
        'fg': textColor.toARGB32(),
        'vert': isVerticalSource,
      };

  factory TranslatedBubble.fromJson(Map<String, dynamic> json) =>
      TranslatedBubble(
        normalizedRect: Rect.fromLTRB(
          (json['l'] as num).toDouble().clamp(0.0, 1.0),
          (json['t'] as num).toDouble().clamp(0.0, 1.0),
          (json['r'] as num).toDouble().clamp(0.0, 1.0),
          (json['b'] as num).toDouble().clamp(0.0, 1.0),
        ),
        originalText: json['orig'] as String? ?? '',
        translatedText: json['trans'] as String? ?? '',
        backgroundColor: Color(json['bg'] as int? ?? 0xFFFFFFFF),
        textColor: Color(json['fg'] as int? ?? 0xFF141414),
        isVerticalSource: json['vert'] as bool? ?? false,
      );
}
