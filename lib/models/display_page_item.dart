import 'package:flutter/widgets.dart';
import 'comic_page.dart';
import 'viewer_settings.dart';

enum DisplayItemType {
  single,     // 1페이지 원본 전체
  splitLeft,  // 좌우 분할 중 왼쪽 절반
  splitRight, // 좌우 분할 중 오른쪽 절반
  spread,     // 두 페이지 나란히 합쳐보기
}

class DisplayPageItem {
  final DisplayItemType type;
  final ComicPage primaryPage;
  final ComicPage? secondaryPage;
  final int primaryOriginalIndex;
  final int? secondaryOriginalIndex;
  final String label;

  const DisplayPageItem({
    required this.type,
    required this.primaryPage,
    this.secondaryPage,
    required this.primaryOriginalIndex,
    this.secondaryOriginalIndex,
    required this.label,
  });

  /// 두 장 합쳐보기(spread)일 때 좌/우 페이지 지정 (읽기 방향 반영)
  ComicPage get leftPage => primaryPage;
  ComicPage? get rightPage => secondaryPage;
}

class DisplayPageBuilder {
  /// 현재 설정(PageDisplayMode, ReadingDirection, Orientation)에 따라
  /// 화면에 표시할 [DisplayPageItem] 목록을 생성합니다.
  static List<DisplayPageItem> buildItems({
    required List<ComicPage> pages,
    required PageDisplayMode mode,
    required ReadingDirection direction,
    required Orientation orientation,
  }) {
    if (pages.isEmpty) return [];

    final isRtoL = direction == ReadingDirection.rightToLeft;
    final isLandscape = orientation == Orientation.landscape;

    // 1. 1페이지 강제 모드
    if (mode == PageDisplayMode.single) {
      return pages.map((p) => DisplayPageItem(
        type: DisplayItemType.single,
        primaryPage: p,
        primaryOriginalIndex: p.index,
        label: '${p.index + 1}p',
      )).toList();
    }

    // 2. 좌우 나눠보기 모드 (Split)
    if (mode == PageDisplayMode.split) {
      final List<DisplayPageItem> items = [];
      for (final p in pages) {
        if (isRtoL) {
          // 일본 만화: 오른쪽 절반 먼저 ➔ 왼쪽 절반 나중
          items.add(DisplayPageItem(
            type: DisplayItemType.splitRight,
            primaryPage: p,
            primaryOriginalIndex: p.index,
            label: '${p.index + 1}p (우)',
          ));
          items.add(DisplayPageItem(
            type: DisplayItemType.splitLeft,
            primaryPage: p,
            primaryOriginalIndex: p.index,
            label: '${p.index + 1}p (좌)',
          ));
        } else {
          // 한국/서양 만화: 왼쪽 절반 먼저 ➔ 오른쪽 절반 나중
          items.add(DisplayPageItem(
            type: DisplayItemType.splitLeft,
            primaryPage: p,
            primaryOriginalIndex: p.index,
            label: '${p.index + 1}p (좌)',
          ));
          items.add(DisplayPageItem(
            type: DisplayItemType.splitRight,
            primaryPage: p,
            primaryOriginalIndex: p.index,
            label: '${p.index + 1}p (우)',
          ));
        }
      }
      return items;
    }

    // 3. 두 장 합쳐보기 모드 (Spread)
    if (mode == PageDisplayMode.spread) {
      return _buildSpreadItems(pages, isRtoL);
    }

    // 4. 자동 모드 (Auto): 기기 방향 및 이미지 가로/세로 비율에 맞춰 지능형 적응
    if (mode == PageDisplayMode.auto) {
      if (isLandscape) {
        // [가로 모드]:
        // 와이드(양면 스캔) 이미지는 1페이지로 크게 보여주고,
        // 낱장 세로 이미지는 두 장씩 합쳐보기(Spread) 적용
        return _buildAutoLandscapeItems(pages, isRtoL);
      } else {
        // [세로 모드]:
        // 와이드(양면 스캔) 이미지는 세로 화면에서 글씨가 작아지므로 좌우 나눠보기(Split) 적용!
        // 낱장 세로 이미지는 1페이지씩 보기
        return _buildAutoPortraitItems(pages, isRtoL);
      }
    }

    return pages.map((p) => DisplayPageItem(
      type: DisplayItemType.single,
      primaryPage: p,
      primaryOriginalIndex: p.index,
      label: '${p.index + 1}p',
    )).toList();
  }

  static List<DisplayPageItem> _buildSpreadItems(List<ComicPage> pages, bool isRtoL) {
    final List<DisplayPageItem> items = [];
    int i = 0;
    while (i < pages.length) {
      if (i + 1 < pages.length) {
        final p1 = pages[i];
        final p2 = pages[i + 1];
        // RtoL 만화: 책 펼쳤을 때 오른쪽이 p1, 왼쪽이 p2
        // LtoR 만화: 책 펼쳤을 때 왼쪽이 p1, 오른쪽이 p2
        items.add(DisplayPageItem(
          type: DisplayItemType.spread,
          primaryPage: isRtoL ? p2 : p1,   // leftPage
          secondaryPage: isRtoL ? p1 : p2, // rightPage
          primaryOriginalIndex: p1.index,
          secondaryOriginalIndex: p2.index,
          label: '${p1.index + 1}-${p2.index + 1}p',
        ));
        i += 2;
      } else {
        final p = pages[i];
        items.add(DisplayPageItem(
          type: DisplayItemType.single,
          primaryPage: p,
          primaryOriginalIndex: p.index,
          label: '${p.index + 1}p',
        ));
        i += 1;
      }
    }
    return items;
  }

  static List<DisplayPageItem> _buildAutoLandscapeItems(List<ComicPage> pages, bool isRtoL) {
    final List<DisplayPageItem> items = [];
    int i = 0;
    while (i < pages.length) {
      final p1 = pages[i];
      if (p1.isWide) {
        // 이미 가로로 긴 2페이지 합본 스캔 이미지인 경우 1장만 가로 화면 가득 표시
        items.add(DisplayPageItem(
          type: DisplayItemType.single,
          primaryPage: p1,
          primaryOriginalIndex: p1.index,
          label: '${p1.index + 1}p',
        ));
        i += 1;
      } else {
        // 낱장 세로 이미지: 다음 장도 세로 이미지면 2장 합쳐보기
        if (i + 1 < pages.length && !pages[i + 1].isWide) {
          final p2 = pages[i + 1];
          items.add(DisplayPageItem(
            type: DisplayItemType.spread,
            primaryPage: isRtoL ? p2 : p1,
            secondaryPage: isRtoL ? p1 : p2,
            primaryOriginalIndex: p1.index,
            secondaryOriginalIndex: p2.index,
            label: '${p1.index + 1}-${p2.index + 1}p',
          ));
          i += 2;
        } else {
          items.add(DisplayPageItem(
            type: DisplayItemType.single,
            primaryPage: p1,
            primaryOriginalIndex: p1.index,
            label: '${p1.index + 1}p',
          ));
          i += 1;
        }
      }
    }
    return items;
  }

  static List<DisplayPageItem> _buildAutoPortraitItems(List<ComicPage> pages, bool isRtoL) {
    final List<DisplayPageItem> items = [];
    for (final p in pages) {
      if (p.isWide) {
        // 세로 화면인데 가로 와이드 이미지인 경우 좌우로 분할 표시!
        if (isRtoL) {
          items.add(DisplayPageItem(
            type: DisplayItemType.splitRight,
            primaryPage: p,
            primaryOriginalIndex: p.index,
            label: '${p.index + 1}p (우)',
          ));
          items.add(DisplayPageItem(
            type: DisplayItemType.splitLeft,
            primaryPage: p,
            primaryOriginalIndex: p.index,
            label: '${p.index + 1}p (좌)',
          ));
        } else {
          items.add(DisplayPageItem(
            type: DisplayItemType.splitLeft,
            primaryPage: p,
            primaryOriginalIndex: p.index,
            label: '${p.index + 1}p (좌)',
          ));
          items.add(DisplayPageItem(
            type: DisplayItemType.splitRight,
            primaryPage: p,
            primaryOriginalIndex: p.index,
            label: '${p.index + 1}p (우)',
          ));
        }
      } else {
        // 일반 세로 이미지는 1페이지씩 표시
        items.add(DisplayPageItem(
          type: DisplayItemType.single,
          primaryPage: p,
          primaryOriginalIndex: p.index,
          label: '${p.index + 1}p',
        ));
      }
    }
    return items;
  }

  /// 원본 페이지 인덱스에 해당하는 displayItems의 인덱스를 반환합니다.
  static int findDisplayIndex(List<DisplayPageItem> items, int originalPageIndex) {
    if (items.isEmpty) return 0;
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.primaryOriginalIndex == originalPageIndex ||
          item.secondaryOriginalIndex == originalPageIndex) {
        return i;
      }
      if (item.primaryOriginalIndex > originalPageIndex) {
        return (i - 1).clamp(0, items.length - 1);
      }
    }
    return items.length - 1;
  }
}
