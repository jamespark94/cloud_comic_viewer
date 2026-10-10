import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'services/account_manager.dart';
import 'services/folder_shortcut_manager.dart';
import 'services/reading_history_service.dart';
import 'services/viewer_settings_service.dart';
import 'ui/screens/home_screen.dart';
import 'utils/platform_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
  }

  // 1. 플랫폼 감지 초기화
  await PlatformUtils.initialize();

  // 2. 만화책 독서 기록 및 뷰어 환경설정 불러오기
  await ReadingHistoryService.instance.loadHistories();
  await ViewerSettingsService.instance.loadSettings();

  runApp(const CloudComicViewerApp());
}

class CloudComicViewerApp extends StatelessWidget {
  const CloudComicViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AccountManager()..loadAccounts(),
        ),
        ChangeNotifierProvider(
          create: (_) => FolderShortcutManager()..loadShortcuts(),
        ),
        ChangeNotifierProvider.value(
          value: ReadingHistoryService.instance,
        ),
        ChangeNotifierProvider.value(
          value: ViewerSettingsService.instance,
        ),
      ],
      child: MaterialApp(
        title: 'Cloud Comic Viewer',
        debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
          surface: const Color(0xFF14171F),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D0F14),
        cardColor: const Color(0xFF1B202B),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF14171F),
          elevation: 0,
          centerTitle: false,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: Colors.black.withAlpha(180),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: Colors.white.withAlpha(50), width: 0.8),
          ),
          contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      ),
        home: const HomeScreen(),
      ),
    );
  }
}
