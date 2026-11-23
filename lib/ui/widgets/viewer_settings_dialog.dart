import 'package:flutter/material.dart';
import '../../models/viewer_settings.dart';
import '../../services/ai_translation/comic_translation_service.dart';
import '../../services/viewer_settings_service.dart';

class ViewerSettingsDialog extends StatelessWidget {
  final ViewerSettingsService settingsService;

  const ViewerSettingsDialog({
    super.key,
    required this.settingsService,
  });

  static Future<void> show(BuildContext context, ViewerSettingsService service) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E212B),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ViewerSettingsDialog(settingsService: service),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settingsService,
      builder: (context, _) {
        final settings = settingsService.settings;

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              left: 20,
              right: 20,
              top: 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '뷰어 설정',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(color: Colors.white12),

              // 1. 보기 모드 (페이지 / 웹툰)
              const SizedBox(height: 8),
              const Text('보기 방식', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SegmentedButton<ViewerMode>(
                segments: const [
                  ButtonSegment(
                    value: ViewerMode.singlePage,
                    label: Text('페이지 모드'),
                    icon: Icon(Icons.auto_stories),
                  ),
                  ButtonSegment(
                    value: ViewerMode.webtoon,
                    label: Text('웹툰 모드 (세로)'),
                    icon: Icon(Icons.view_day),
                  ),
                ],
                selected: {settings.viewerMode},
                onSelectionChanged: (selected) {
                  settingsService.setViewerMode(selected.first);
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),

              // 2. 화면 분할 / 합침 모드 (페이지 모드일 때 활성화)
              if (settings.viewerMode == ViewerMode.singlePage) ...[
                const SizedBox(height: 16),
                const Text('화면 분할 / 합쳐보기', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SegmentedButton<PageDisplayMode>(
                  segments: const [
                    ButtonSegment(
                      value: PageDisplayMode.auto,
                      label: Text('자동'),
                      icon: Icon(Icons.auto_awesome, size: 16),
                    ),
                    ButtonSegment(
                      value: PageDisplayMode.split,
                      label: Text('나눠보기'),
                      icon: Icon(Icons.vertical_split, size: 16),
                    ),
                    ButtonSegment(
                      value: PageDisplayMode.spread,
                      label: Text('합쳐보기'),
                      icon: Icon(Icons.menu_book, size: 16),
                    ),
                    ButtonSegment(
                      value: PageDisplayMode.single,
                      label: Text('1페이지'),
                      icon: Icon(Icons.crop_portrait, size: 16),
                    ),
                  ],
                  selected: {settings.displayMode},
                  onSelectionChanged: (selected) {
                    settingsService.setDisplayMode(selected.first);
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],

              // 3. 읽는 방향 (페이지 모드일 때만 활성화)
              if (settings.viewerMode == ViewerMode.singlePage) ...[
                const SizedBox(height: 16),
                const Text('페이지 넘김 방향', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SegmentedButton<ReadingDirection>(
                  segments: const [
                    ButtonSegment(
                      value: ReadingDirection.leftToRight,
                      label: Text('왼쪽 ➔ 오른쪽 (일반)'),
                      icon: Icon(Icons.arrow_forward),
                    ),
                    ButtonSegment(
                      value: ReadingDirection.rightToLeft,
                      label: Text('오른쪽 ➔ 왼쪽 (일본식)'),
                      icon: Icon(Icons.arrow_back),
                    ),
                  ],
                  selected: {settings.readingDirection},
                  onSelectionChanged: (selected) {
                    settingsService.setReadingDirection(selected.first);
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),

                const SizedBox(height: 16),
                const Text('페이지 이동 터치 방식', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SegmentedButton<PageNavigationMode>(
                  segments: const [
                    ButtonSegment(
                      value: PageNavigationMode.leftRightTap,
                      label: Text('좌우 탭'),
                      icon: Icon(Icons.touch_app, size: 16),
                    ),
                    ButtonSegment(
                      value: PageNavigationMode.topBottomTap,
                      label: Text('상하 탭'),
                      icon: Icon(Icons.swap_vert, size: 16),
                    ),
                    ButtonSegment(
                      value: PageNavigationMode.swipeOnly,
                      label: Text('스크롤만'),
                      icon: Icon(Icons.swipe, size: 16),
                    ),
                  ],
                  selected: {settings.pageNavigationMode},
                  onSelectionChanged: (selected) {
                    settingsService.setPageNavigationMode(selected.first);
                  },
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],

              // 3. 이미지 화면 맞춤
              const SizedBox(height: 16),
              const Text('화면 맞춤', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SegmentedButton<FitMode>(
                segments: const [
                  ButtonSegment(
                    value: FitMode.contain,
                    label: Text('화면 맞춤'),
                    icon: Icon(Icons.fit_screen),
                  ),
                  ButtonSegment(
                    value: FitMode.fitWidth,
                    label: Text('가로 폭 맞춤'),
                    icon: Icon(Icons.swap_horiz),
                  ),
                  ButtonSegment(
                    value: FitMode.fitHeight,
                    label: Text('세로 높이 맞춤'),
                    icon: Icon(Icons.swap_vert),
                  ),
                ],
                selected: {settings.fitMode},
                onSelectionChanged: (selected) {
                  settingsService.setFitMode(selected.first);
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('화면보다 작은 이미지 확대 맞춤', style: TextStyle(color: Colors.white, fontSize: 13)),
                subtitle: const Text(
                  '원본 크기가 화면보다 작을 때 비율을 유지하며 화면에 맞춥니다',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                value: settings.fitSmallImages,
                activeThumbColor: Colors.blueAccent,
                onChanged: (_) => settingsService.toggleFitSmallImages(),
              ),

              // 4. 배경 테마
              const SizedBox(height: 16),
              const Text('배경 테마', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Row(
                children: ViewerTheme.values.map((theme) {
                  final isSelected = settings.theme == theme;
                  return Padding(
                    padding: const EdgeInsets.only(right: 12.0),
                    child: GestureDetector(
                      onTap: () => settingsService.setTheme(theme),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: theme.color,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected ? Colors.blueAccent : Colors.white24,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Text(
                          theme.label,
                          style: TextStyle(
                            color: theme == ViewerTheme.white || theme == ViewerTheme.sepia
                                ? Colors.black87
                                : Colors.white,
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),

              // 5. AI 실시간 말풍선 번역
              const SizedBox(height: 16),
              _AiComicTranslationSection(settingsService: settingsService),

              // 6. 기타 옵션 (화면 켜짐 유지)
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('뷰어 실행 중 화면 켜짐 유지', style: TextStyle(color: Colors.white, fontSize: 14)),
                value: settings.keepScreenOn,
                activeThumbColor: Colors.blueAccent,
                onChanged: (_) => settingsService.toggleKeepScreenOn(),
              ),
              const SizedBox(height: 8),
            ],
          ),
          ),
        );
      },
    );
  }
}

class _AiComicTranslationSection extends StatefulWidget {
  final ViewerSettingsService settingsService;

  const _AiComicTranslationSection({required this.settingsService});

  @override
  State<_AiComicTranslationSection> createState() =>
      _AiComicTranslationSectionState();
}

class _AiComicTranslationSectionState extends State<_AiComicTranslationSection> {
  final TextEditingController _apiKeyController = TextEditingController();
  bool _obscureApiKey = true;
  bool _isSavingApiKey = false;
  String? _inlineFeedback;
  bool _inlineFeedbackIsWarning = false;

  @override
  void initState() {
    super.initState();
    ComicTranslationService.instance.loadGeminiApiKey();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  void _setFeedback(String message, {bool isWarning = false}) {
    if (!mounted) return;
    setState(() {
      _inlineFeedback = message;
      _inlineFeedbackIsWarning = isWarning;
    });
  }

  Future<void> _saveApiKey() async {
    final input = _apiKeyController.text.trim();
    if (input.isEmpty) {
      _setFeedback('Gemini API Key를 입력해 주세요.', isWarning: true);
      return;
    }
    setState(() => _isSavingApiKey = true);
    try {
      await ComicTranslationService.instance.saveGeminiApiKey(input);
      _apiKeyController.clear();
      _setFeedback('Gemini API Key가 로컬 보안 저장소에 안전하게 저장되었습니다.');
    } catch (e) {
      _setFeedback('API Key 저장 실패: $e', isWarning: true);
    } finally {
      if (mounted) setState(() => _isSavingApiKey = false);
    }
  }

  Future<void> _deleteApiKey() async {
    setState(() => _isSavingApiKey = true);
    try {
      await ComicTranslationService.instance.deleteGeminiApiKey();
      _apiKeyController.clear();
      _setFeedback('저장된 Gemini API Key를 삭제했습니다.');
    } finally {
      if (mounted) setState(() => _isSavingApiKey = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final translationService = ComicTranslationService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.settingsService, translationService]),
      builder: (context, _) {
        final settings = widget.settingsService.settings;
        final isEnabled = settings.translationMode != ComicTranslationMode.off;
        final isCloud =
            settings.translationEngineType == ComicTranslationEngineType.cloudVision;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.auto_awesome, color: Colors.cyanAccent, size: 16),
                SizedBox(width: 6),
                Text(
                  'AI 실시간 말풍선 번역',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<ComicTranslationMode>(
              segments: const [
                ButtonSegment(
                  value: ComicTranslationMode.off,
                  label: Text('끄기'),
                  icon: Icon(Icons.block, size: 16),
                ),
                ButtonSegment(
                  value: ComicTranslationMode.manual,
                  label: Text('수동 번역'),
                  icon: Icon(Icons.touch_app_outlined, size: 16),
                ),
                ButtonSegment(
                  value: ComicTranslationMode.auto,
                  label: Text('자동 번역'),
                  icon: Icon(Icons.translate, size: 16),
                ),
              ],
              selected: {settings.translationMode},
              onSelectionChanged: (selected) async {
                final nextMode = selected.first;
                if (nextMode != ComicTranslationMode.off && isCloud) {
                  await translationService.loadGeminiApiKey();
                  if (!translationService.hasGeminiApiKey) {
                    _setFeedback(
                      '클라우드 고품질 모드를 사용하려면 아래에 Gemini API Key를 먼저 저장해 주세요.',
                      isWarning: true,
                    );
                  }
                }
                await widget.settingsService.setTranslationMode(nextMode);
              },
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
            ),
            if (isEnabled) ...[
              const SizedBox(height: 8),
              Text(
                settings.translationMode == ComicTranslationMode.manual
                    ? '툴바의 [페이지 번역] 버튼 탭 또는 화면 길게 누르기 시 현재 페이지만 번역합니다.'
                    : (isCloud
                        ? '페이지에 1.2초 이상 머무르면 자동 번역하고, 이미 번역된 페이지는 캐시에서 즉시 불러옵니다.'
                        : '페이지를 넘길 때마다 현재 페이지를 자동 번역하고 다음 1~2페이지를 미리 번역합니다.'),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              const SizedBox(height: 12),
              const Text(
                '번역 엔진 선택',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final engineType in ComicTranslationEngineType.values)
                    ChoiceChip(
                      label: Text(
                        engineType.label,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: settings.translationEngineType == engineType
                              ? Colors.black
                              : Colors.white70,
                          fontWeight:
                              settings.translationEngineType == engineType
                                  ? FontWeight.w700
                                  : FontWeight.normal,
                        ),
                      ),
                      selected: settings.translationEngineType == engineType,
                      selectedColor: Colors.cyanAccent,
                      backgroundColor: const Color(0xFF252C3B),
                      side: BorderSide(
                        color: settings.translationEngineType == engineType
                            ? Colors.cyanAccent
                            : Colors.white12,
                      ),
                      visualDensity: VisualDensity.compact,
                      onSelected: (selected) async {
                        if (!selected ||
                            settings.translationEngineType == engineType) {
                          return;
                        }
                        if (engineType ==
                            ComicTranslationEngineType.cloudVision) {
                          await translationService.loadGeminiApiKey();
                        }
                        await widget.settingsService
                            .setTranslationEngineType(engineType);
                      },
                    ),
                ],
              ),
              if (!isCloud &&
                  !translationService
                      .isEngineSupportedFor(ComicTranslationEngineType.onDevice)) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border:
                        Border.all(color: Colors.amber.withValues(alpha: 0.45)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline,
                          size: 16, color: Colors.amber),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          translationService.unsupportedReasonFor(
                                  ComicTranslationEngineType.onDevice) ??
                              '현재 환경에서는 로컬 무료 모드가 지원되지 않습니다.',
                          style: const TextStyle(
                              color: Colors.amberAccent, fontSize: 11),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.cyanAccent,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () async {
                          await translationService.loadGeminiApiKey();
                          await widget.settingsService.setTranslationEngineType(
                            ComicTranslationEngineType.cloudVision,
                          );
                        },
                        child: const Text(
                          '클라우드 전환',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (isCloud) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.vpn_key,
                              size: 15, color: Colors.cyanAccent),
                          const SizedBox(width: 6),
                          const Text(
                            'Gemini API Key (로컬 보안 저장)',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: (translationService.hasGeminiApiKey
                                      ? Colors.greenAccent
                                      : Colors.orangeAccent)
                                  .withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              translationService.hasGeminiApiKey
                                  ? '저장됨 (${translationService.maskedGeminiApiKey ?? ''})'
                                  : '미입력',
                              style: TextStyle(
                                fontSize: 10,
                                color: translationService.hasGeminiApiKey
                                    ? Colors.greenAccent
                                    : Colors.orangeAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _apiKeyController,
                              obscureText: _obscureApiKey,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: translationService.hasGeminiApiKey
                                    ? '새 Gemini API Key 입력 시 덮어쓰기'
                                    : 'AIza... 형태의 Gemini API Key 입력',
                                hintStyle: const TextStyle(
                                    color: Colors.white38, fontSize: 11),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                                filled: true,
                                fillColor: const Color(0xFF141821),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide:
                                      const BorderSide(color: Colors.white12),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  borderSide:
                                      const BorderSide(color: Colors.white12),
                                ),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _obscureApiKey
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                    size: 16,
                                    color: Colors.white54,
                                  ),
                                  onPressed: () {
                                    setState(() =>
                                        _obscureApiKey = !_obscureApiKey);
                                  },
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          ElevatedButton(
                            onPressed: _isSavingApiKey ? null : _saveApiKey,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.cyanAccent,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              minimumSize: Size.zero,
                            ),
                            child: const Text(
                              '저장',
                              style: TextStyle(
                                  fontSize: 11.5, fontWeight: FontWeight.bold),
                            ),
                          ),
                          if (translationService.hasGeminiApiKey) ...[
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: '저장된 API Key 삭제',
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: Colors.redAccent,
                              ),
                              onPressed:
                                  _isSavingApiKey ? null : _deleteApiKey,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              if (_inlineFeedback != null) ...[
                const SizedBox(height: 6),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: (_inlineFeedbackIsWarning
                            ? Colors.orangeAccent
                            : Colors.cyanAccent)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (_inlineFeedbackIsWarning
                              ? Colors.orangeAccent
                              : Colors.cyanAccent)
                          .withValues(alpha: 0.45),
                    ),
                  ),
                  child: Text(
                    _inlineFeedback!,
                    style: TextStyle(
                      color: _inlineFeedbackIsWarning
                          ? Colors.orangeAccent
                          : Colors.cyanAccent,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                '원본 만화 언어',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              SegmentedButton<ComicSourceLanguage>(
                segments: ComicSourceLanguage.values
                    .map(
                      (lang) => ButtonSegment(
                        value: lang,
                        label: Text(lang.label),
                      ),
                    )
                    .toList(),
                selected: {settings.translationSourceLang},
                onSelectionChanged: (selected) {
                  widget.settingsService
                      .setTranslationSourceLang(selected.first);
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
