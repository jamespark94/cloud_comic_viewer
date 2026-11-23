import 'dart:math';
import 'dart:ui';
import '../../models/viewer_settings.dart';

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
    r'[A-Za-z0-9\u00C0-\u024F\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u3400-\u4DBF\uAC00-\uD7AF]',
  );

  static final RegExp _cjkOrKanaPattern = RegExp(
    r'[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u3400-\u4DBF]',
  );

  static final RegExp _latinWordCharPattern = RegExp(
    r'[A-Za-z0-9\u00C0-\u024F]',
  );

  static final RegExp _singleAsciiNoisePattern = RegExp(r'^[A-Za-z0-9]$');

  static final RegExp _cjkNoiseTokenPattern = RegExp(
    r'^[々ゝゞヽヾー\uFF61-\uFF9F]$',
  );

  static final RegExp _invisibleCharPattern = RegExp(
    r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\u200B-\u200D\uFEFF\uFFFD]',
  );

  static final RegExp _ocrArtifactSymbolPattern = RegExp(
    r'[|¦│┃┆┇┊┋^_`\\<>\[\]{}•·∙◦※†‡§¶°¬¯¨´¸\u2500-\u25FF\u2700-\u27BF]+',
  );

  static final RegExp _repeatedSymbolRunPattern = RegExp(
    r'(?:={2,}|\*{2,}|\+{2,}|/{2,}|~{2,}|-{3,})',
  );

  static final RegExp _leadingStraySymbolPattern = RegExp(
    r'^(?:\.{1,2}(?!\.)|[,;:/\\*+=~_^|<>]|-(?!\d))+\s*',
  );

  static final RegExp _trailingStraySymbolPattern = RegExp(
    r'[\s/\\*+=_^|<>-]+$',
  );

  static final RegExp _cjkInternalSpacePattern = RegExp(
    r'(?<=[\u3000-\u303F\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u3400-\u4DBF\uFF00-\uFFEF])\s+(?=[\u3000-\u303F\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u3400-\u4DBF\uFF00-\uFFEF])',
  );

  /// OCR 텍스트에서 오인식된 특수기호/제어문자를 정제하고 언어 스크립트에 맞게 줄바꿈·공백을 정규화합니다.
  static String cleanAndNormalizeText(
    String text, {
    bool? isCjkScript,
    bool isVertical = false,
  }) {
    if (text.isEmpty) return '';

    var cleaned = text
        .replaceAll(_invisibleCharPattern, '')
        .replaceAll(_ocrArtifactSymbolPattern, ' ')
        .replaceAll(_repeatedSymbolRunPattern, ' ');

    final bool cjk = isCjkScript ?? _cjkOrKanaPattern.hasMatch(cleaned);

    if (cjk) {
      // 일본어·중국어는 줄바꿈을 제거하고 공백 없이 연결 (단, 가로쓰기 영문 단어 경계는 공백 유지)
      if (!isVertical) {
        cleaned = cleaned.replaceAllMapped(
          RegExp(r'([A-Za-z0-9\u00C0-\u024F])[\r\n]+([A-Za-z0-9\u00C0-\u024F])'),
          (m) => '${m.group(1)} ${m.group(2)}',
        );
      }
      cleaned = cleaned
          .replaceAll(RegExp(r'[\r\n]+'), '')
          .replaceAll(RegExp(r'[ \t\u3000]+'), ' ')
          .replaceAll(_cjkInternalSpacePattern, '')
          // 일본어/중국어 문장 앞뒤에 말풍선 테두리 오인식으로 붙은 단일 ASCII 노이즈 제거
          .replaceAll(
            RegExp(r'^[lIi10oO]\s+(?=[\u3040-\u30FF\u4E00-\u9FFF\u3400-\u4DBF「『（])'),
            '',
          )
          .replaceAll(
            RegExp(r'(?<=[\u3000-\u303F\u3040-\u30FF\u4E00-\u9FFF\u3400-\u4DBF\uFF00-\uFFEF])\s+[lIi10oO]$'),
            '',
          );
    } else {
      // 영어·스페인어·한국어 등 띄어쓰기 언어는 줄바꿈을 단일 공백으로 치환
      cleaned = cleaned.replaceAll(RegExp(r'[\r\n\s]+'), ' ');
    }

    cleaned = cleaned
        .replaceAll(RegExp(r'\.{4,}'), '...')
        .replaceAll(RegExp(r'…{2,}'), '…')
        .replaceAll(RegExp(r'!{3,}'), '!!')
        .replaceAll(RegExp(r'\?{3,}'), '??')
        .replaceAll(RegExp(r'！{3,}'), '！！')
        .replaceAll(RegExp(r'？{3,}'), '？？')
        .trim()
        .replaceFirst(_leadingStraySymbolPattern, '')
        .replaceFirst(_trailingStraySymbolPattern, '')
        .trim();

    return cleaned;
  }

  /// 정제된 텍스트가 번역 가치가 없는 특수기호/단일 문자 노이즈인지 판별합니다.
  static bool isNoiseText(
    String text, {
    bool preferNoSpace = false,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return true;
    if (!_meaningfulCharPattern.hasMatch(trimmed)) return true;

    final core = trimmed.replaceAll(
      RegExp(
        r'[^A-Za-z0-9\u00C0-\u024F\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\u3400-\u4DBF\uAC00-\uD7AF]',
      ),
      '',
    );
    if (core.isEmpty) return true;
    if (_cjkNoiseTokenPattern.hasMatch(core)) return true;

    // 단독 1글자 영문/숫자(말풍선 테두리·스크린톤 오인식 'a', 'l', 'I', 'o', '1' 등) 필터링
    if (core.length == 1 && _singleAsciiNoisePattern.hasMatch(core)) {
      if (preferNoSpace || trimmed.length == 1) {
        return true;
      }
    }
    return false;
  }

  /// OCR 라인 목록을 말풍선 단위로 병합하고 정규화 좌표(`[0.0, 1.0]`)를 생성합니다.
  static List<ClusteredBubble> clusterLines({
    required List<OcrTextLine> lines,
    required int imageWidth,
    required int imageHeight,
    bool preferVerticalRtl = true,
    ComicSourceLanguage? sourceLanguage,
  }) {
    if (lines.isEmpty || imageWidth <= 0 || imageHeight <= 0) return const [];

    final bool isForcedCjk = sourceLanguage == ComicSourceLanguage.japanese ||
        sourceLanguage == ComicSourceLanguage.chinese;
    final bool isForcedSpaceDelimited =
        sourceLanguage == ComicSourceLanguage.english;
    final bool? lineCjkHint =
        isForcedCjk ? true : (isForcedSpaceDelimited ? false : null);

    final filtered = <_LineItem>[];
    for (final line in lines) {
      final box = line.boundingBox;
      if (box.width < 6 || box.height < 6) continue;

      final isVert = _detectVertical(box, line.text, preferVerticalRtl);
      final cleanText = cleanAndNormalizeText(
        line.text,
        isCjkScript: lineCjkHint,
        isVertical: isVert,
      );
      if (cleanText.isEmpty) continue;
      if (!_meaningfulCharPattern.hasMatch(cleanText)) continue;
      if (_cjkNoiseTokenPattern.hasMatch(cleanText)) continue;

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
      final isGroupVertical = _isGroupVertical(group);
      final groupHasCjk =
          isForcedCjk || group.any((e) => _cjkOrKanaPattern.hasMatch(e.line.text));

      // 만화 읽기 순서 정렬 및 문장 결합
      final ordered = List<_LineItem>.from(group);
      if (isGroupVertical && (preferVerticalRtl || groupHasCjk)) {
        _sortVerticalRtl(ordered);
      } else if (isGroupVertical) {
        _sortVerticalLtr(ordered);
      } else {
        _sortHorizontalLtr(ordered);
      }

      final mergedText = _joinTexts(
        ordered,
        isVertical: isGroupVertical,
        isForcedCjk: isForcedCjk,
        isForcedSpaceDelimited: isForcedSpaceDelimited,
      );
      if (mergedText.isEmpty ||
          isNoiseText(mergedText, preferNoSpace: groupHasCjk)) {
        continue;
      }

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

  static bool _isGroupVertical(List<_LineItem> group) {
    int verticalCount = 0;
    int verticalChars = 0;
    int totalChars = 0;
    for (final item in group) {
      final len = item.line.text.length;
      totalChars += len;
      if (item.isVertical) {
        verticalCount++;
        verticalChars += len;
      }
    }
    if (verticalCount == 0) return false;
    return verticalChars * 2 >= totalChars || verticalCount * 2 >= group.length;
  }

  static bool _detectVertical(Rect box, String text, bool preferVerticalRtl) {
    if (box.height > box.width * 1.15) {
      return true;
    }
    final trimmed = text.trim();
    if (_cjkOrKanaPattern.hasMatch(trimmed) && trimmed.length >= 2) {
      if (box.height > box.width * 1.05) {
        return true;
      }
      if (preferVerticalRtl && box.height >= box.width) {
        return true;
      }
    }
    return false;
  }

  static bool _shouldMerge(_LineItem a, _LineItem b) {
    final r1 = a.line.boundingBox;
    final r2 = b.line.boundingBox;
    final scale = max(a.charScale, b.charScale);

    // 두 라인 모두 세로쓰기이거나, 한쪽이 세로쓰기이고 다른 쪽이 짧은 CJK 열 조각인 경우
    final aShortCjk = !a.isVertical &&
        a.line.text.length <= 2 &&
        _cjkOrKanaPattern.hasMatch(a.line.text);
    final bShortCjk = !b.isVertical &&
        b.line.text.length <= 2 &&
        _cjkOrKanaPattern.hasMatch(b.line.text);

    if ((a.isVertical || aShortCjk) &&
        (b.isVertical || bShortCjk) &&
        (a.isVertical || b.isVertical)) {
      final hGap = _axisGap(r1.left, r1.right, r2.left, r2.right);
      final vGap = _axisGap(r1.top, r1.bottom, r2.top, r2.bottom);
      final vOverlap = _overlapRatio(r1.top, r1.bottom, r2.top, r2.bottom);
      final topDiff = (r1.top - r2.top).abs();
      final avgLen = (r1.height + r2.height) / 2.0;

      // 같은 말풍선 내 인접 세로 열 (오른쪽 열 <-> 왼쪽 열)
      final adjacentColumns = hGap <= scale * 1.45 &&
          (vOverlap >= 0.20 ||
              (vGap <= scale * 0.6 && topDiff <= avgLen * 0.45));

      // 같은 세로 열이 위/아래로 두 조각 난 경우
      final sameColumnSplit =
          _overlapRatio(r1.left, r1.right, r2.left, r2.right) >= 0.45 &&
              vGap <= scale * 1.15;

      return adjacentColumns || sameColumnSplit;
    }

    // 가로쓰기 조합 (영미 코믹스, 스페인어, 한국어, 가로 말풍선)
    if (!a.isVertical && !b.isVertical) {
      final vGap = _axisGap(r1.top, r1.bottom, r2.top, r2.bottom);
      final hGap = _axisGap(r1.left, r1.right, r2.left, r2.right);
      final hOverlap = _overlapRatio(r1.left, r1.right, r2.left, r2.right);

      final adjacentLines = vGap <= scale * 1.30 && hOverlap >= 0.25;
      final sameLineSplit =
          _overlapRatio(r1.top, r1.bottom, r2.top, r2.bottom) >= 0.45 &&
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

  /// 일본 만화 세로쓰기 순서: X좌표가 큰 쪽(오른쪽 줄) ➔ 작은 쪽(왼쪽 줄), 같은 줄 내에서는 위 ➔ 아래
  /// (열 그룹화를 먼저 수행해 Comparator의 추이성 위반 없이 결정적으로 정렬)
  static void _sortVerticalRtl(List<_LineItem> items) {
    _sortVerticalColumns(items, rightToLeft: true);
  }

  static void _sortVerticalLtr(List<_LineItem> items) {
    _sortVerticalColumns(items, rightToLeft: false);
  }

  static void _sortVerticalColumns(
    List<_LineItem> items, {
    required bool rightToLeft,
  }) {
    if (items.length <= 1) return;

    final byX = List<_LineItem>.from(items)
      ..sort((a, b) => rightToLeft
          ? b.line.boundingBox.center.dx.compareTo(a.line.boundingBox.center.dx)
          : a.line.boundingBox.center.dx.compareTo(b.line.boundingBox.center.dx));

    final columns = <List<_LineItem>>[];
    for (final item in byX) {
      final box = item.line.boundingBox;
      List<_LineItem>? targetCol;
      for (final col in columns) {
        final colCenterX = col
                .map((e) => e.line.boundingBox.center.dx)
                .reduce((a, b) => a + b) /
            col.length;
        final maxScale = max(
          item.charScale,
          col.map((e) => e.charScale).reduce(max),
        );
        final threshold = maxScale * 0.55;
        final colLeft = col.map((e) => e.line.boundingBox.left).reduce(min);
        final colRight = col.map((e) => e.line.boundingBox.right).reduce(max);
        final hOverlap = _overlapRatio(colLeft, colRight, box.left, box.right);

        if ((box.center.dx - colCenterX).abs() <= threshold || hOverlap >= 0.45) {
          targetCol = col;
          break;
        }
      }
      if (targetCol != null) {
        targetCol.add(item);
      } else {
        columns.add([item]);
      }
    }

    double colMeanX(List<_LineItem> col) =>
        col.map((e) => e.line.boundingBox.center.dx).reduce((a, b) => a + b) /
        col.length;

    columns.sort((a, b) => rightToLeft
        ? colMeanX(b).compareTo(colMeanX(a))
        : colMeanX(a).compareTo(colMeanX(b)));

    items.clear();
    for (final col in columns) {
      col.sort((a, b) => a.line.boundingBox.top.compareTo(b.line.boundingBox.top));
      items.addAll(col);
    }
  }

  /// 가로쓰기 순서: 위 ➔ 아래, 같은 줄 내에서는 왼쪽 ➔ 오른쪽
  static void _sortHorizontalLtr(List<_LineItem> items) {
    if (items.length <= 1) return;

    final byY = List<_LineItem>.from(items)
      ..sort((a, b) =>
          a.line.boundingBox.center.dy.compareTo(b.line.boundingBox.center.dy));

    final rows = <List<_LineItem>>[];
    for (final item in byY) {
      final box = item.line.boundingBox;
      List<_LineItem>? targetRow;
      for (final row in rows) {
        final rowCenterY = row
                .map((e) => e.line.boundingBox.center.dy)
                .reduce((a, b) => a + b) /
            row.length;
        final maxScale = max(
          item.charScale,
          row.map((e) => e.charScale).reduce(max),
        );
        final threshold = maxScale * 0.55;
        final rowTop = row.map((e) => e.line.boundingBox.top).reduce(min);
        final rowBottom = row.map((e) => e.line.boundingBox.bottom).reduce(max);
        final vOverlap = _overlapRatio(rowTop, rowBottom, box.top, box.bottom);

        if ((box.center.dy - rowCenterY).abs() <= threshold || vOverlap >= 0.45) {
          targetRow = row;
          break;
        }
      }
      if (targetRow != null) {
        targetRow.add(item);
      } else {
        rows.add([item]);
      }
    }

    double rowMeanY(List<_LineItem> row) =>
        row.map((e) => e.line.boundingBox.center.dy).reduce((a, b) => a + b) /
        row.length;

    rows.sort((a, b) => rowMeanY(a).compareTo(rowMeanY(b)));

    items.clear();
    for (final row in rows) {
      row.sort((a, b) => a.line.boundingBox.left.compareTo(b.line.boundingBox.left));
      items.addAll(row);
    }
  }

  static String _joinTexts(
    List<_LineItem> ordered, {
    required bool isVertical,
    required bool isForcedCjk,
    required bool isForcedSpaceDelimited,
  }) {
    if (ordered.isEmpty) return '';

    final hasCjkInGroup = ordered.any((e) => _cjkOrKanaPattern.hasMatch(e.line.text));
    final bool isCjkGroup =
        isForcedCjk || (!isForcedSpaceDelimited && hasCjkInGroup);

    // 일본어/중국어 말풍선 내부에 말풍선 테두리 오인식으로 섞인 단일 ASCII 문자 라인 제거
    final effectiveItems = isCjkGroup && hasCjkInGroup
        ? ordered
            .where((e) => !_singleAsciiNoisePattern.hasMatch(e.line.text.trim()))
            .toList()
        : ordered;

    if (effectiveItems.isEmpty) return '';
    if (effectiveItems.length == 1) {
      return cleanAndNormalizeText(
        effectiveItems.first.line.text,
        isCjkScript: isCjkGroup,
        isVertical: isVertical,
      );
    }

    final buffer = StringBuffer();
    for (int i = 0; i < effectiveItems.length; i++) {
      final text = effectiveItems[i].line.text;
      if (i > 0) {
        final prev = effectiveItems[i - 1].line.text;
        final prevLast = prev.charactersLast;
        final currFirst = text.charactersFirst;

        final bool needsSpace;
        if (isCjkGroup) {
          // 일본어·중국어 스크립트는 공백 없이 연결 (가로쓰기 영문 단어끼리 이어지는 경우만 예외)
          needsSpace = !isVertical &&
              prev.length >= 2 &&
              text.length >= 2 &&
              _latinWordCharPattern.hasMatch(prevLast) &&
              _latinWordCharPattern.hasMatch(currFirst);
        } else {
          // 영어·스페인어·한국어 등 띄어쓰기 언어는 공백(' ')으로 연결
          needsSpace = true;
        }

        if (needsSpace) {
          buffer.write(' ');
        }
      }
      buffer.write(text);
    }

    return cleanAndNormalizeText(
      buffer.toString(),
      isCjkScript: isCjkGroup,
      isVertical: isVertical,
    );
  }
}

extension _StringEdgeChar on String {
  String get charactersFirst => isEmpty ? '' : substring(0, 1);
  String get charactersLast => isEmpty ? '' : substring(length - 1);
}
