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

/// 뷰어 배경 테마 (만화 & 이북 공통)
enum ViewerTheme {
  black(Color(0xFF000000), Color(0xFFBDBDBD), '블랙'),
  darkGray(Color(0xFF1E1E1E), Color(0xFFD6D6D6), '다크 그레이'),
  white(Color(0xFFFFFFFF), Color(0xFF1A1A1A), '화이트'),
  sepia(Color(0xFFFBF0D9), Color(0xFF3E3224), '세피아'),
  eyeGreen(Color(0xFFC7EDCC), Color(0xFF1B2E1E), '눈보호 그린');

  final Color color;
  final Color textColor;
  final String label;
  const ViewerTheme(this.color, this.textColor, this.label);

  bool get isDark => this == ViewerTheme.black || this == ViewerTheme.darkGray;
}

/// 이북(TXT/EPUB) 뷰어 넘김 모드
enum EbookPageMode {
  paged('좌우 페이지 넘김', Icons.auto_stories),
  scroll('상하 웹소설 스크롤', Icons.view_day_outlined);

  final String label;
  final IconData icon;
  const EbookPageMode(this.label, this.icon);
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
  final bool fitSmallImages; // 화면보다 작은 이미지 확대 맞춤

  // 이북(TXT / EPUB / PDF) 전용 추가 설정
  final EbookPageMode ebookPageMode;
  final double ebookFontSize;
  final double ebookLineHeight;
  final double ebookParagraphSpacing;
  final double ebookHorizontalMargin;
  final double ebookVerticalMargin;
  final String ebookFontFamily; // 'default', 'serif', 'monospace'
  final bool ebookJustifyText;
  final bool ebookFirstLineIndent;
  final bool useVolumeKeysForPageTurn;
  final bool pdfDarkInvert;

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
    this.fitSmallImages = true,
    this.ebookPageMode = EbookPageMode.paged,
    this.ebookFontSize = 18.0,
    this.ebookLineHeight = 1.65,
    this.ebookParagraphSpacing = 12.0,
    this.ebookHorizontalMargin = 22.0,
    this.ebookVerticalMargin = 20.0,
    this.ebookFontFamily = 'default',
    this.ebookJustifyText = true,
    this.ebookFirstLineIndent = false,
    this.useVolumeKeysForPageTurn = true,
    this.pdfDarkInvert = false,
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
    bool? fitSmallImages,
    EbookPageMode? ebookPageMode,
    double? ebookFontSize,
    double? ebookLineHeight,
    double? ebookParagraphSpacing,
    double? ebookHorizontalMargin,
    double? ebookVerticalMargin,
    String? ebookFontFamily,
    bool? ebookJustifyText,
    bool? ebookFirstLineIndent,
    bool? useVolumeKeysForPageTurn,
    bool? pdfDarkInvert,
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
      fitSmallImages: fitSmallImages ?? this.fitSmallImages,
      ebookPageMode: ebookPageMode ?? this.ebookPageMode,
      ebookFontSize: ebookFontSize ?? this.ebookFontSize,
      ebookLineHeight: ebookLineHeight ?? this.ebookLineHeight,
      ebookParagraphSpacing: ebookParagraphSpacing ?? this.ebookParagraphSpacing,
      ebookHorizontalMargin: ebookHorizontalMargin ?? this.ebookHorizontalMargin,
      ebookVerticalMargin: ebookVerticalMargin ?? this.ebookVerticalMargin,
      ebookFontFamily: ebookFontFamily ?? this.ebookFontFamily,
      ebookJustifyText: ebookJustifyText ?? this.ebookJustifyText,
      ebookFirstLineIndent: ebookFirstLineIndent ?? this.ebookFirstLineIndent,
      useVolumeKeysForPageTurn: useVolumeKeysForPageTurn ?? this.useVolumeKeysForPageTurn,
      pdfDarkInvert: pdfDarkInvert ?? this.pdfDarkInvert,
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
        'fitSmallImages': fitSmallImages,
        'ebookPageMode': ebookPageMode.name,
        'ebookFontSize': ebookFontSize,
        'ebookLineHeight': ebookLineHeight,
        'ebookParagraphSpacing': ebookParagraphSpacing,
        'ebookHorizontalMargin': ebookHorizontalMargin,
        'ebookVerticalMargin': ebookVerticalMargin,
        'ebookFontFamily': ebookFontFamily,
        'ebookJustifyText': ebookJustifyText,
        'ebookFirstLineIndent': ebookFirstLineIndent,
        'useVolumeKeysForPageTurn': useVolumeKeysForPageTurn,
        'pdfDarkInvert': pdfDarkInvert,
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
        fitSmallImages: json['fitSmallImages'] as bool? ?? true,
        ebookPageMode: EbookPageMode.values.firstWhere(
          (e) => e.name == json['ebookPageMode'],
          orElse: () => EbookPageMode.paged,
        ),
        ebookFontSize: (json['ebookFontSize'] as num?)?.toDouble() ?? 18.0,
        ebookLineHeight: (json['ebookLineHeight'] as num?)?.toDouble() ?? 1.65,
        ebookParagraphSpacing: (json['ebookParagraphSpacing'] as num?)?.toDouble() ?? 12.0,
        ebookHorizontalMargin: (json['ebookHorizontalMargin'] as num?)?.toDouble() ?? 22.0,
        ebookVerticalMargin: (json['ebookVerticalMargin'] as num?)?.toDouble() ?? 20.0,
        ebookFontFamily: json['ebookFontFamily'] as String? ?? 'default',
        ebookJustifyText: json['ebookJustifyText'] as bool? ?? true,
        ebookFirstLineIndent: json['ebookFirstLineIndent'] as bool? ?? false,
        useVolumeKeysForPageTurn: json['useVolumeKeysForPageTurn'] as bool? ?? true,
        pdfDarkInvert: json['pdfDarkInvert'] as bool? ?? false,
      );
}
