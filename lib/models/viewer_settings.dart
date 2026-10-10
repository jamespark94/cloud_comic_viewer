import 'package:flutter/material.dart';

/// 읽기 방향
enum ReadingDirection {
  leftToRight, // 한국/서양 만화: 왼쪽 -> 오른쪽으로 넘김
  rightToLeft, // 일본 출판만화: 오른쪽 -> 왼쪽으로 넘김
  vertical,    // 웹툰 / 연속 스크롤: 위에서 아래로 스크롤
}

/// 뷰어 보기 모드
enum ViewerMode {
  singlePage, // 한 페이지씩 보기
  doublePage, // 두 페이지 펼쳐보기 (태블릿/PC 가로 화면)
  webtoon,    // 웹툰 연속 스크롤
}

/// 화면 분할 / 합침 모드
enum PageDisplayMode {
  auto('자동 (비율/방향 맞춤)', Icons.auto_awesome),
  single('1페이지 원본 보기', Icons.crop_portrait),
  split('좌우 나눠보기', Icons.vertical_split),
  spread('두 장 합쳐보기', Icons.menu_book);

  final String label;
  final IconData icon;
  const PageDisplayMode(this.label, this.icon);
}

/// 페이지 넘김 탐색 방식
enum PageNavigationMode {
  leftRightTap('좌우 탭 이동', Icons.touch_app),
  topBottomTap('상하 탭 이동', Icons.swap_vert),
  swipeOnly('스크롤/스와이프만', Icons.swipe);

  final String label;
  final IconData icon;
  const PageNavigationMode(this.label, this.icon);
}

/// 이미지 맞춤 비율
enum FitMode {
  contain,  // 화면 전체에 비율 유지 맞춤 (여백 있음)
  fitWidth, // 가로 폭에 맞춤 (세로 스크롤 또는 긴 웹툰)
  fitHeight,// 세로 높이에 맞춤
}

/// 뷰어 배경 테마
enum ViewerTheme {
  black(Color(0xFF000000), '블랙'),
  darkGray(Color(0xFF1E1E1E), '다크 그레이'),
  white(Color(0xFFFFFFFF), '화이트'),
  sepia(Color(0xFFFBF0D9), '세피아');

  final Color color;
  final String label;
  const ViewerTheme(this.color, this.label);
}

class ViewerSettings {
  final ReadingDirection readingDirection;
  final ViewerMode viewerMode;
  final PageDisplayMode displayMode;
  final PageNavigationMode pageNavigationMode;
  final FitMode fitMode;
  final ViewerTheme theme;
  final bool keepScreenOn;
  final bool showPageNumber;
  final bool showClockAndBattery;

  const ViewerSettings({
    this.readingDirection = ReadingDirection.leftToRight,
    this.viewerMode = ViewerMode.singlePage,
    this.displayMode = PageDisplayMode.auto,
    this.pageNavigationMode = PageNavigationMode.leftRightTap,
    this.fitMode = FitMode.contain,
    this.theme = ViewerTheme.black,
    this.keepScreenOn = true,
    this.showPageNumber = true,
    this.showClockAndBattery = true,
  });

  ViewerSettings copyWith({
    ReadingDirection? readingDirection,
    ViewerMode? viewerMode,
    PageDisplayMode? displayMode,
    PageNavigationMode? pageNavigationMode,
    FitMode? fitMode,
    ViewerTheme? theme,
    bool? keepScreenOn,
    bool? showPageNumber,
    bool? showClockAndBattery,
  }) {
    return ViewerSettings(
      readingDirection: readingDirection ?? this.readingDirection,
      viewerMode: viewerMode ?? this.viewerMode,
      displayMode: displayMode ?? this.displayMode,
      pageNavigationMode: pageNavigationMode ?? this.pageNavigationMode,
      fitMode: fitMode ?? this.fitMode,
      theme: theme ?? this.theme,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      showPageNumber: showPageNumber ?? this.showPageNumber,
      showClockAndBattery: showClockAndBattery ?? this.showClockAndBattery,
    );
  }

  Map<String, dynamic> toJson() => {
        'readingDirection': readingDirection.name,
        'viewerMode': viewerMode.name,
        'displayMode': displayMode.name,
        'pageNavigationMode': pageNavigationMode.name,
        'fitMode': fitMode.name,
        'theme': theme.name,
        'keepScreenOn': keepScreenOn,
        'showPageNumber': showPageNumber,
        'showClockAndBattery': showClockAndBattery,
      };

  factory ViewerSettings.fromJson(Map<String, dynamic> json) => ViewerSettings(
        readingDirection: ReadingDirection.values.firstWhere(
          (e) => e.name == json['readingDirection'],
          orElse: () => ReadingDirection.leftToRight,
        ),
        viewerMode: ViewerMode.values.firstWhere(
          (e) => e.name == json['viewerMode'],
          orElse: () => ViewerMode.singlePage,
        ),
        displayMode: PageDisplayMode.values.firstWhere(
          (e) => e.name == json['displayMode'],
          orElse: () => PageDisplayMode.auto,
        ),
        pageNavigationMode: PageNavigationMode.values.firstWhere(
          (e) => e.name == json['pageNavigationMode'],
          orElse: () => PageNavigationMode.leftRightTap,
        ),
        fitMode: FitMode.values.firstWhere(
          (e) => e.name == json['fitMode'],
          orElse: () => FitMode.contain,
        ),
        theme: ViewerTheme.values.firstWhere(
          (e) => e.name == json['theme'],
          orElse: () => ViewerTheme.black,
        ),
        keepScreenOn: json['keepScreenOn'] as bool? ?? true,
        showPageNumber: json['showPageNumber'] as bool? ?? true,
        showClockAndBattery: json['showClockAndBattery'] as bool? ?? true,
      );
}
