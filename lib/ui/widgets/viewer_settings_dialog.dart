import 'package:flutter/material.dart';
import '../../models/viewer_settings.dart';
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

        return Padding(
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

              // 2. 읽는 방향 (페이지 모드일 때만 활성화)
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

              // 5. 기타 옵션 (화면 켜짐 유지)
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
        );
      },
    );
  }
}
