import 'package:flutter/material.dart';
import '../../models/ai_translation/translated_bubble.dart';
import '../../models/viewer_settings.dart';
import '../../services/ai_translation/comic_translation_service.dart';
import '../../services/viewer_settings_service.dart';

/// 이미지 렌더링 모드별 정규화 좌표 투영 모드
enum ComicOverlayViewportMode {
  fullPage,
  splitLeftHalf,
  splitRightHalf,
}

/// 만화 이미지 위젯과 동일한 `Stack` 좌표계 내부에 배치되는 말풍선 번역 오버레이.
///
/// InteractiveViewer의 줌/팬 행렬을 이미지와 동일하게 공유하므로
/// 확대/이동 시에도 말풍선 위치가 밀리지 않으며, 번역 모드가 OFF일 때는
/// 즉시 `SizedBox.shrink()`를 반환하여 기존 뷰어에 0% 사이드 이펙트를 보장합니다.
class ComicTranslationOverlay extends StatelessWidget {
  final String bookId;
  final int pageIndex;
  final ComicOverlayViewportMode viewportMode;

  /// 단위 테스트 또는 커스텀 주입 시 사용할 서비스 인스턴스 (기본: 싱글톤)
  final ComicTranslationService? translationService;
  final ViewerSettingsService? settingsService;

  const ComicTranslationOverlay({
    super.key,
    required this.bookId,
    required this.pageIndex,
    this.viewportMode = ComicOverlayViewportMode.fullPage,
    this.translationService,
    this.settingsService,
  });

  /// 뷰포트 모드(`fullPage` / `splitLeftHalf` / `splitRightHalf`)에 맞게
  /// 정규화 좌표(`[0.0, 1.0]`)를 현재 표시 영역 기준 좌표로 변환합니다.
  static Rect? projectNormalizedRect(
    Rect normRect,
    ComicOverlayViewportMode mode,
  ) {
    switch (mode) {
      case ComicOverlayViewportMode.fullPage:
        return normRect;
      case ComicOverlayViewportMode.splitLeftHalf:
        if (normRect.center.dx >= 0.5) return null;
        final l = (normRect.left * 2.0).clamp(0.0, 1.0);
        final r = (normRect.right * 2.0).clamp(0.0, 1.0);
        if (r - l <= 0.01) return null;
        return Rect.fromLTRB(l, normRect.top, r, normRect.bottom);
      case ComicOverlayViewportMode.splitRightHalf:
        if (normRect.center.dx < 0.5) return null;
        final l = ((normRect.left - 0.5) * 2.0).clamp(0.0, 1.0);
        final r = ((normRect.right - 0.5) * 2.0).clamp(0.0, 1.0);
        if (r - l <= 0.01) return null;
        return Rect.fromLTRB(l, normRect.top, r, normRect.bottom);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tService = translationService ?? ComicTranslationService.instance;
    final sService = settingsService ?? ViewerSettingsService.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([tService, sService]),
      builder: (context, _) {
        final settings = sService.settings;
        if (settings.translationMode == ComicTranslationMode.off ||
            !tService.isOverlayVisible) {
          return const SizedBox.shrink();
        }

        final bubbles = tService.getCachedBubblesSync(
          bookId,
          pageIndex,
          settings.translationSourceLang,
          engineType: settings.translationEngineType,
        );
        if (bubbles == null || bubbles.isEmpty) {
          return const SizedBox.shrink();
        }

        return IgnorePointer(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final h = constraints.maxHeight;
              if (w <= 0 || h <= 0 || !w.isFinite || !h.isFinite) {
                return const SizedBox.shrink();
              }

              final children = <Widget>[];
              for (final bubble in bubbles) {
                final projected = projectNormalizedRect(
                  bubble.normalizedRect,
                  viewportMode,
                );
                if (projected == null) continue;

                final boxLeft = projected.left * w;
                final boxTop = projected.top * h;
                final boxWidth = (projected.width * w).clamp(24.0, w);
                final boxHeight = (projected.height * h).clamp(18.0, h);

                children.add(
                  Positioned(
                    left: boxLeft.clamp(0.0, (w - boxWidth).clamp(0.0, w)),
                    top: boxTop.clamp(0.0, (h - boxHeight).clamp(0.0, h)),
                    width: boxWidth,
                    height: boxHeight,
                    child: _TranslatedBubblePatch(
                      bubble: bubble,
                      boxWidth: boxWidth,
                      boxHeight: boxHeight,
                    ),
                  ),
                );
              }

              if (children.isEmpty) return const SizedBox.shrink();
              return Stack(
                clipBehavior: Clip.none,
                children: children,
              );
            },
          ),
        );
      },
    );
  }
}

class _TranslatedBubblePatch extends StatelessWidget {
  final TranslatedBubble bubble;
  final double boxWidth;
  final double boxHeight;

  const _TranslatedBubblePatch({
    required this.bubble,
    required this.boxWidth,
    required this.boxHeight,
  });

  @override
  Widget build(BuildContext context) {
    final padH = (boxWidth * 0.06).clamp(2.0, 6.0);
    final padV = (boxHeight * 0.05).clamp(2.0, 5.0);
    final innerW = (boxWidth - padH * 2).clamp(10.0, boxWidth);
    final innerH = (boxHeight - padV * 2).clamp(10.0, boxHeight);

    final fontSize = _computeFittingFontSize(
      text: bubble.translatedText,
      maxWidth: innerW,
      maxHeight: innerH,
      textDirection: Directionality.of(context),
    );

    final isLightBg = bubble.backgroundColor.computeLuminance() > 0.45;
    final borderColor = isLightBg
        ? Colors.black.withValues(alpha: 0.10)
        : Colors.white.withValues(alpha: 0.16);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: bubble.backgroundColor.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: borderColor, width: 0.6),
      ),
      alignment: Alignment.center,
      child: Text(
        bubble.translatedText,
        textAlign: TextAlign.center,
        overflow: TextOverflow.fade,
        style: TextStyle(
          color: bubble.textColor,
          fontSize: fontSize,
          height: 1.15,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 이진 탐색(Binary Search)으로 말풍선 박스 크기에 딱 맞는 최대 폰트 크기를 산출합니다.
  static double _computeFittingFontSize({
    required String text,
    required double maxWidth,
    required double maxHeight,
    required TextDirection textDirection,
  }) {
    double low = 7.0;
    double high = 26.0;
    double best = low;

    final painter = TextPainter(
      textAlign: TextAlign.center,
      textDirection: textDirection,
    );

    for (int iter = 0; iter < 8; iter++) {
      final mid = (low + high) / 2.0;
      painter.text = TextSpan(
        text: text,
        style: TextStyle(
          fontSize: mid,
          height: 1.15,
          fontWeight: FontWeight.w600,
        ),
      );
      painter.layout(maxWidth: maxWidth);

      if (painter.height <= maxHeight && painter.width <= maxWidth + 0.5) {
        best = mid;
        low = mid;
      } else {
        high = mid;
      }
    }
    painter.dispose();
    return best;
  }
}
