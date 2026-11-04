import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/viewer_settings.dart';
import '../../services/viewer_settings_service.dart';

class EbookSettingsSheet extends StatelessWidget {
  final bool isPdf;

  const EbookSettingsSheet({
    super.key,
    this.isPdf = false,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<ViewerSettingsService>(
      builder: (context, service, _) {
        final s = service.settings;

        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1A1F2B),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.fromLTRB(
            20,
            14,
            20,
            24 + MediaQuery.of(context).padding.bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.tune, color: Colors.blueAccent, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          isPdf ? 'PDF 뷰어 설정' : '이북 조판 및 뷰어 설정',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 20),

                // 1. 배경 컬러 테마
                const Text(
                  '배경 테마',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: ViewerTheme.values.map((theme) {
                    final selected = s.theme == theme;
                    return InkWell(
                      onTap: () => service.setTheme(theme),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: theme.color,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected ? Colors.blueAccent : Colors.white24,
                            width: selected ? 2.5 : 1.0,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (selected) ...[
                              Icon(Icons.check_circle, size: 15, color: theme.textColor),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              theme.label,
                              style: TextStyle(
                                color: theme.textColor,
                                fontSize: 12,
                                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),

                if (!isPdf) ...[
                  // 2. 페이지 넘김 방식 (좌우 페이지 vs 상하 웹소설 스크롤)
                  const Text(
                    '읽기 방식',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: EbookPageMode.values.map((mode) {
                      final selected = s.ebookPageMode == mode;
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              backgroundColor: selected ? Colors.blueAccent.withAlpha(40) : Colors.white.withAlpha(10),
                              side: BorderSide(
                                color: selected ? Colors.blueAccent : Colors.white12,
                                width: selected ? 1.5 : 1.0,
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 11),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: Icon(
                              mode.icon,
                              size: 18,
                              color: selected ? Colors.blueAccent : Colors.white70,
                            ),
                            label: Text(
                              mode.label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                                color: selected ? Colors.white : Colors.white70,
                              ),
                            ),
                            onPressed: () => service.setEbookPageMode(mode),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),

                  // 3. 글꼴 패밀리 선택
                  const Text(
                    '글꼴 모양',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _buildFontChip(context, service, s, 'default', '고딕 (기본)'),
                      const SizedBox(width: 8),
                      _buildFontChip(context, service, s, 'serif', '명조 (바탕체)'),
                      const SizedBox(width: 8),
                      _buildFontChip(context, service, s, 'monospace', '고정폭 (코딩체)'),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // 4. 글자 크기 슬라이더
                  _buildSliderRow(
                    label: '글자 크기',
                    valueText: '${s.ebookFontSize.toStringAsFixed(0)} pt',
                    value: s.ebookFontSize,
                    min: 12.0,
                    max: 36.0,
                    divisions: 24,
                    onChanged: (v) => service.setEbookFontSize(v),
                  ),

                  // 5. 줄간격 슬라이더
                  _buildSliderRow(
                    label: '줄간격',
                    valueText: s.ebookLineHeight.toStringAsFixed(2),
                    value: s.ebookLineHeight,
                    min: 1.2,
                    max: 2.4,
                    divisions: 24,
                    onChanged: (v) => service.setEbookLineHeight(v),
                  ),

                  // 6. 문단 간격 슬라이더
                  _buildSliderRow(
                    label: '문단 간격',
                    valueText: '${s.ebookParagraphSpacing.toStringAsFixed(0)} px',
                    value: s.ebookParagraphSpacing,
                    min: 0.0,
                    max: 32.0,
                    divisions: 16,
                    onChanged: (v) => service.setEbookParagraphSpacing(v),
                  ),

                  // 7. 좌우 여백 슬라이더
                  _buildSliderRow(
                    label: '좌우 여백',
                    valueText: '${s.ebookHorizontalMargin.toStringAsFixed(0)} px',
                    value: s.ebookHorizontalMargin,
                    min: 8.0,
                    max: 56.0,
                    divisions: 12,
                    onChanged: (v) => service.setEbookMargins(horizontal: v),
                  ),

                  const Divider(color: Colors.white12, height: 20),

                  // 8. 조판 토글 옵션
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('문단 양쪽 정렬 (Justify)', style: TextStyle(fontSize: 13)),
                    value: s.ebookJustifyText,
                    activeTrackColor: Colors.blueAccent,
                    onChanged: (_) => service.toggleEbookJustifyText(),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('문단 첫 줄 들여쓰기 (1칸)', style: TextStyle(fontSize: 13)),
                    value: s.ebookFirstLineIndent,
                    activeTrackColor: Colors.blueAccent,
                    onChanged: (_) => service.toggleEbookFirstLineIndent(),
                  ),
                ] else ...[
                  // PDF 전용 설정
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('PDF 야간 다크 모드 (색상 반전)', style: TextStyle(fontSize: 13)),
                    subtitle: const Text('흰색 배경 문서를 어두운 배경으로 반전합니다.', style: TextStyle(fontSize: 11, color: Colors.white54)),
                    value: s.pdfDarkInvert,
                    activeTrackColor: Colors.blueAccent,
                    onChanged: (_) => service.togglePdfDarkInvert(),
                  ),
                ],

                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('볼륨 버튼으로 페이지 넘김', style: TextStyle(fontSize: 13)),
                  value: s.useVolumeKeysForPageTurn,
                  activeTrackColor: Colors.blueAccent,
                  onChanged: (_) => service.toggleVolumeKeysForPageTurn(),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('독서 중 화면 항상 켜기', style: TextStyle(fontSize: 13)),
                  value: s.keepScreenOn,
                  activeTrackColor: Colors.blueAccent,
                  onChanged: (_) => service.toggleKeepScreenOn(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFontChip(
    BuildContext context,
    ViewerSettingsService service,
    ViewerSettings s,
    String familyKey,
    String label,
  ) {
    final selected = s.ebookFontFamily == familyKey;
    return Expanded(
      child: InkWell(
        onTap: () => service.setEbookFontFamily(familyKey),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.blueAccent.withAlpha(45) : Colors.white.withAlpha(12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? Colors.blueAccent : Colors.white12,
              width: selected ? 1.5 : 1.0,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontFamily: familyKey == 'default' ? null : familyKey,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? Colors.white : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSliderRow({
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12.5, color: Colors.white70),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: const SliderThemeData(
                trackHeight: 3,
                thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
              ),
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                activeColor: Colors.blueAccent,
                inactiveColor: Colors.white12,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              valueText,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blueAccent),
            ),
          ),
        ],
      ),
    );
  }
}
