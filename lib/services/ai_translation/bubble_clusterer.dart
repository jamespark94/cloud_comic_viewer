import 'dart:math';
import 'dart:ui';

/// 플랫폼 독립적 OCR 라인 DTO (ML Kit 의존성을 클러스터링 알고리즘에서 분리)
class OcrTextLine {
  final String text;
  final Rect boundingBox;
  final double? angle;

  const OcrTextLine({
    required this.text,
    required this.boundingBox,
    this.angle,
  });
}

/// 병합된 단일 말풍선 클러스터 결과 (픽셀 좌표 + 정규화 좌표 + 결합된 문장)
class ClusteredBubble {
  final Rect pixelRect;
  final Rect normalizedRect;
  final String mergedText;
  final bool isVertical;

  const ClusteredBubble({
    required this.pixelRect,
    required this.normalizedRect,
    required this.mergedText,
    required this.isVertical,
  });
}

class _LineItem {
  final OcrTextLine line;
  final bool isVertical;
  final double charScale;

  const _LineItem({
    required this.line,
    required this.isVertical,
    required this.charScale,
  });
}

/// OCR로 추출된 조각난 텍스트 라인들을 만화 말풍선(문맥) 단위로 병합하는 순수 Dart 엔진
class BubbleClusterer {
  static final RegExp _meaningfulCharPattern = RegExp(
    r'[A-Za-z0-9\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\uAC00-\uD7AF]',
  );

  static final RegExp _cjkOrKanaPattern = RegExp(
    r'[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF]',
  );

  /// OCR 라인 목록을 말풍선 단위로 병합하고 정규화 좌표(`[0.0, 1.0]`)를 생성합니다.
  static List<ClusteredBubble> clusterLines({
    required List<OcrTextLine> lines,
    required int imageWidth,
    required int imageHeight,
    bool preferVerticalRtl = true,
  }) {
    if (lines.isEmpty || imageWidth <= 0 || imageHeight <= 0) return const [];

    final filtered = <_LineItem>[];
    for (final line in lines) {
      final cleanText = line.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (cleanText.isEmpty) continue;

      final box = line.boundingBox;
      if (box.width < 6 || box.height < 6) continue;
      if (!_meaningfulCharPattern.hasMatch(cleanText)) continue;

      final isVert = _detectVertical(box, cleanText, preferVerticalRtl);
      final charScale = isVert
          ? box.width.clamp(8.0, imageWidth * 0.15)
          : box.height.clamp(8.0, imageHeight * 0.15);

      filtered.add(_LineItem(
        line: OcrTextLine(text: cleanText, boundingBox: box, angle: line.angle),
        isVertical: isVert,
        charScale: charScale,
      ));
    }

    if (filtered.isEmpty) return const [];

    final n = filtered.length;
    final parent = List<int>.generate(n, (i) => i);

    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) {
      final ra = find(a);
      final rb = find(b);
      if (ra != rb) parent[rb] = ra;
    }

    for (int i = 0; i < n; i++) {
      for (int j = i + 1; j < n; j++) {
        if (_shouldMerge(filtered[i], filtered[j])) {
          union(i, j);
        }
      }
    }

    final groups = <int, List<_LineItem>>{};
    for (int i = 0; i < n; i++) {
      groups.putIfAbsent(find(i), () => []).add(filtered[i]);
    }

    final results = <ClusteredBubble>[];
    for (final group in groups.values) {
      final verticalCount = group.where((e) => e.isVertical).length;
      final isGroupVertical = verticalCount >= (group.length / 2);

      // 만화 읽기 순서 정렬 및 문장 결합
      final ordered = List<_LineItem>.from(group);
      if (isGroupVertical && preferVerticalRtl) {
        _sortVerticalRtl(ordered);
      } else {
        _sortHorizontalLtr(ordered);
      }

      final mergedText = _joinTexts(ordered, isGroupVertical);
      if (mergedText.isEmpty) continue;

      double minL = double.infinity;
      double minT = double.infinity;
      double maxR = double.negativeInfinity;
      double maxB = double.negativeInfinity;
      double maxCharScale = 0;

      for (final item in ordered) {
        final r = item.line.boundingBox;
        minL = min(minL, r.left);
        minT = min(minT, r.top);
        maxR = max(maxR, r.right);
        maxB = max(maxB, r.bottom);
        maxCharScale = max(maxCharScale, item.charScale);
      }

      // 원본 글자 획이 가림 패치 밖으로 삐져나오지 않도록 소폭 패딩 추가
      final padX = max(4.0, maxCharScale * 0.14);
      final padY = max(4.0, maxCharScale * 0.14);

      final paddedPixelRect = Rect.fromLTRB(
        (minL - padX).clamp(0.0, imageWidth.toDouble()),
        (minT - padY).clamp(0.0, imageHeight.toDouble()),
        (maxR + padX).clamp(0.0, imageWidth.toDouble()),
        (maxB + padY).clamp(0.0, imageHeight.toDouble()),
      );

      if (paddedPixelRect.width <= 2 || paddedPixelRect.height <= 2) continue;

      final normRect = Rect.fromLTRB(
        (paddedPixelRect.left / imageWidth).clamp(0.0, 1.0),
        (paddedPixelRect.top / imageHeight).clamp(0.0, 1.0),
        (paddedPixelRect.right / imageWidth).clamp(0.0, 1.0),
        (paddedPixelRect.bottom / imageHeight).clamp(0.0, 1.0),
      );

      results.add(ClusteredBubble(
        pixelRect: paddedPixelRect,
        normalizedRect: normRect,
        mergedText: mergedText,
        isVertical: isGroupVertical,
      ));
    }

    // 페이지 내 읽기 순서로 최종 정렬 (일본 만화: 우상 -> 좌하 / 일반: 좌상 -> 우하)
    results.sort((a, b) {
      final rowDiff = (a.normalizedRect.top - b.normalizedRect.top).abs();
      if (rowDiff < 0.12) {
        return preferVerticalRtl
            ? b.normalizedRect.right.compareTo(a.normalizedRect.right)
            : a.normalizedRect.left.compareTo(b.normalizedRect.left);
      }
      return a.normalizedRect.top.compareTo(b.normalizedRect.top);
    });

    return results;
  }

  static bool _detectVertical(Rect box, String text, bool preferVerticalRtl) {
    if (box.height > box.width * 1.15) {
      return true;
    }
    if (preferVerticalRtl &&
        _cjkOrKanaPattern.hasMatch(text) &&
        box.height >= box.width * 0.95 &&
        text.length >= 2) {
      // 세로로 놓인 짧은 CJK 단어(예: 2~3글자)는 정사각형에 가까울 수 있음
      return box.height >= box.width;
    }
    return false;
  }

  static bool _shouldMerge(_LineItem a, _LineItem b) {
    final r1 = a.line.boundingBox;
    final r2 = b.line.boundingBox;
    final scale = max(a.charScale, b.charScale);

    // 두 라인 모두 세로쓰기이거나 CJK 세로 열 조합인 경우
    if (a.isVertical && b.isVertical) {
      final hGap = _axisGap(r1.left, r1.right, r2.left, r2.right);
      final vGap = _axisGap(r1.top, r1.bottom, r2.top, r2.bottom);
      final vOverlap = _overlapRatio(r1.top, r1.bottom, r2.top, r2.bottom);
      final topDiff = (r1.top - r2.top).abs();
      final avgLen = (r1.height + r2.height) / 2.0;

      // 같은 말풍선 내 인접 세로 열 (오른쪽 열 <-> 왼쪽 열)
      final adjacentColumns = hGap <= scale * 1.45 &&
          (vOverlap >= 0.20 || (vGap <= scale * 0.6 && topDiff <= avgLen * 0.45));

      // 같은 세로 열이 위/아래로 두 조각 난 경우
      final sameColumnSplit = _overlapRatio(r1.left, r1.right, r2.left, r2.right) >= 0.45 &&
          vGap <= scale * 1.15;

      return adjacentColumns || sameColumnSplit;
    }

    // 가로쓰기 조합 (영미 코믹스, 한국어, 가로 말풍선)
    if (!a.isVertical && !b.isVertical) {
      final vGap = _axisGap(r1.top, r1.bottom, r2.top, r2.bottom);
      final hGap = _axisGap(r1.left, r1.right, r2.left, r2.right);
      final hOverlap = _overlapRatio(r1.left, r1.right, r2.left, r2.right);

      final adjacentLines = vGap <= scale * 1.30 && hOverlap >= 0.25;
      final sameLineSplit = _overlapRatio(r1.top, r1.bottom, r2.top, r2.bottom) >= 0.45 &&
          hGap <= scale * 1.2;

      return adjacentLines || sameLineSplit;
    }

    // 한 글자짜리 세로/가로 혼재 조각이 바로 옆에 붙어 있는 경우 보조 병합
    final hGap = _axisGap(r1.left, r1.right, r2.left, r2.right);
    final vGap = _axisGap(r1.top, r1.bottom, r2.top, r2.bottom);
    return hGap <= scale * 0.65 && vGap <= scale * 0.65;
  }

  static double _axisGap(double aStart, double aEnd, double bStart, double bEnd) {
    if (aEnd < bStart) return bStart - aEnd;
    if (bEnd < aStart) return aStart - bEnd;
    return 0.0;
  }

  static double _overlapRatio(
    double aStart,
    double aEnd,
    double bStart,
    double bEnd,
  ) {
    final overlap = min(aEnd, bEnd) - max(aStart, bStart);
    if (overlap <= 0) return 0.0;
    final minLen = min(aEnd - aStart, bEnd - bStart);
    if (minLen <= 0) return 0.0;
    return overlap / minLen;
  }

  /// 일본 만화 세로쓰기 순서: 오른쪽 열 ➔ 왼쪽 열, 같은 열 내에서는 위 ➔ 아래
  static void _sortVerticalRtl(List<_LineItem> items) {
    items.sort((a, b) {
      final ra = a.line.boundingBox;
      final rb = b.line.boundingBox;
      final sameColThreshold = max(a.charScale, b.charScale) * 0.55;
      if ((ra.center.dx - rb.center.dx).abs() <= sameColThreshold) {
        return ra.top.compareTo(rb.top);
      }
      return rb.center.dx.compareTo(ra.center.dx);
    });
  }

  /// 가로쓰기 순서: 위 ➔ 아래, 같은 줄 내에서는 왼쪽 ➔ 오른쪽
  static void _sortHorizontalLtr(List<_LineItem> items) {
    items.sort((a, b) {
      final ra = a.line.boundingBox;
      final rb = b.line.boundingBox;
      final sameRowThreshold = max(a.charScale, b.charScale) * 0.55;
      if ((ra.center.dy - rb.center.dy).abs() <= sameRowThreshold) {
        return ra.left.compareTo(rb.left);
      }
      return ra.top.compareTo(rb.top);
    });
  }

  static String _joinTexts(List<_LineItem> ordered, bool isVertical) {
    if (ordered.isEmpty) return '';
    if (ordered.length == 1) return ordered.first.line.text;

    final buffer = StringBuffer();
    for (int i = 0; i < ordered.length; i++) {
      final text = ordered[i].line.text;
      if (i > 0) {
        final prev = ordered[i - 1].line.text;
        final needsSpace = !isVertical &&
            !_cjkOrKanaPattern.hasMatch(prev.charactersLast) &&
            !_cjkOrKanaPattern.hasMatch(text.charactersFirst);
        if (needsSpace) {
          buffer.write(' ');
        }
      }
      buffer.write(text);
    }
    return buffer.toString().trim();
  }
}

extension _StringEdgeChar on String {
  String get charactersFirst => isEmpty ? '' : substring(0, 1);
  String get charactersLast => isEmpty ? '' : substring(length - 1);
}
