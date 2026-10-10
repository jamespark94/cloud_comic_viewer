import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/cloud_account.dart';
import '../../models/comic_reading_history.dart';
import '../../models/folder_shortcut.dart';
import '../../models/media_item.dart';
import '../../services/account_manager.dart';
import '../../services/folder_shortcut_manager.dart';
import '../../services/reading_history_service.dart';
import 'add_account_dialog.dart';
import 'browser_screen.dart';
import 'comic_viewer_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.auto_stories, color: Colors.blueAccent),
            SizedBox(width: 10),
            Text('Cloud Comic Viewer', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, color: Colors.blueAccent),
            tooltip: '새 클라우드 계정 추가',
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => const AddAccountDialog(),
              );
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          final accountMgr = context.read<AccountManager>();
          final shortcutMgr = context.read<FolderShortcutManager>();
          await accountMgr.loadAccounts();
          await shortcutMgr.loadShortcuts();
          await ReadingHistoryService.instance.loadHistories();
        },
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            // 1. 최근 읽은 만화책 섹션
            _buildRecentReadingSection(context),

            const SizedBox(height: 20),

            // 2. 홈 바로가기 폴더 섹션
            _buildShortcutsSection(context),

            const SizedBox(height: 20),

            // 3. 연결된 클라우드 스토리지 섹션
            _buildStorageSection(context),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentReadingSection(BuildContext context) {
    return Consumer<ReadingHistoryService>(
      builder: (context, historyService, _) {
        final recentList = historyService.recentList;
        if (recentList.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.history, size: 20, color: Colors.blueAccent),
                      SizedBox(width: 8),
                      Text('최근 읽은 만화', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  TextButton(
                    onPressed: () => historyService.clearAll(),
                    child: const Text('기록 비우기', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemCount: recentList.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final history = recentList[index];
                  return _buildRecentCard(context, history);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRecentCard(BuildContext context, ComicReadingHistory history) {
    return InkWell(
      onTap: () {
        final accountMgr = context.read<AccountManager>();
        final account = accountMgr.getAccountById(history.accountId) ?? AccountManager.localAccount;
        final service = accountMgr.getService(account);

        final item = MediaItem(
          id: history.id,
          name: history.title,
          parentId: history.parentFolderId,
          isFolder: false,
        );

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ComicViewerScreen(
              item: item,
              service: service,
              initialPage: history.lastPage,
            ),
          ),
        );
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF1B202B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            // 표지 썸네일 (만화책 표지 종횡비)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 54,
                height: 76,
                color: Colors.black38,
                child: history.coverThumbnailUrl != null && File(history.coverThumbnailUrl!).existsSync()
                    ? Image.file(
                        File(history.coverThumbnailUrl!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Center(
                          child: Icon(Icons.auto_stories, color: Colors.blueAccent, size: 24),
                        ),
                      )
                    : const Center(
                        child: Icon(Icons.auto_stories, color: Colors.blueAccent, size: 24),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            // 만화 정보 및 진행률
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    history.accountName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                  ),
                  Text(
                    history.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, height: 1.25),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${history.lastPage + 1} / ${history.totalPages}p',
                            style: const TextStyle(color: Colors.blueAccent, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${history.progressPercent}%',
                            style: const TextStyle(color: Colors.white38, fontSize: 10),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: history.progress,
                          minHeight: 3,
                          backgroundColor: Colors.white12,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShortcutsSection(BuildContext context) {
    return Consumer<FolderShortcutManager>(
      builder: (context, shortcutMgr, _) {
        final shortcuts = shortcutMgr.shortcuts;
        if (shortcuts.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  Icon(Icons.bookmark, size: 20, color: Colors.amber),
                  SizedBox(width: 8),
                  Text('홈 바로가기 폴더', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: shortcuts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final sc = shortcuts[index];
                return _buildShortcutTile(context, sc, shortcutMgr);
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildShortcutTile(
    BuildContext context,
    FolderShortcut shortcut,
    FolderShortcutManager shortcutMgr,
  ) {
    return ListTile(
      tileColor: const Color(0xFF1B202B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Colors.white10),
      ),
      leading: const Icon(Icons.folder_special, color: Colors.amber, size: 32),
      title: Text(shortcut.folderName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
      subtitle: Text(
        '${shortcut.accountName} · ${shortcut.folderPath ?? ""}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white38, fontSize: 11),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 18, color: Colors.white38),
        onPressed: () => shortcutMgr.removeShortcut(shortcut.id),
      ),
      onTap: () {
        final accountMgr = context.read<AccountManager>();
        final account = accountMgr.getAccountById(shortcut.accountId) ?? AccountManager.localAccount;
        final service = accountMgr.getService(account);

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BrowserScreen(
              account: account,
              service: service,
              initialFolderId: shortcut.folderId,
              initialFolderName: shortcut.folderName,
            ),
          ),
        );
      },
    );
  }

  Widget _buildStorageSection(BuildContext context) {
    return Consumer<AccountManager>(
      builder: (context, accountMgr, _) {
        final accounts = accountMgr.accounts;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  Icon(Icons.cloud_queue, size: 20, color: Colors.blueAccent),
                  SizedBox(width: 8),
                  Text('저장소 목록', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  // 로컬 디바이스 / PC 저장소
                  _buildAccountCard(context, AccountManager.localAccount, accountMgr, isLocal: true),
                  const SizedBox(height: 10),

                  // 등록된 클라우드 계정 목록
                  ...accounts.map((acc) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _buildAccountCard(context, acc, accountMgr),
                    );
                  }),

                  // 계정 추가 버튼
                  InkWell(
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (_) => const AddAccountDialog(),
                      );
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.blueAccent.withAlpha(100), strokeAlign: BorderSide.strokeAlignCenter),
                        borderRadius: BorderRadius.circular(12),
                        color: Colors.blueAccent.withAlpha(20),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add, color: Colors.blueAccent, size: 20),
                          SizedBox(width: 8),
                          Text('새 클라우드 연결 (구글, 원드라이브, Box, Dropbox, WebDAV)',
                              style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAccountCard(
    BuildContext context,
    CloudAccount account,
    AccountManager accountMgr, {
    bool isLocal = false,
  }) {
    IconData icon;
    Color color;

    switch (account.type) {
      case CloudType.local:
        icon = Icons.computer;
        color = Colors.tealAccent;
        break;
      case CloudType.googleDrive:
        icon = Icons.add_to_drive;
        color = Colors.orangeAccent;
        break;
      case CloudType.oneDrive:
        icon = Icons.cloud;
        color = Colors.blue;
        break;
      case CloudType.box:
        icon = Icons.all_inbox;
        color = Colors.indigoAccent;
        break;
      case CloudType.dropbox:
        icon = Icons.folder_zip;
        color = Colors.lightBlueAccent;
        break;
      case CloudType.webDav:
        icon = Icons.dns;
        color = Colors.greenAccent;
        break;
    }

    return Card(
      elevation: 0,
      color: const Color(0xFF1B202B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Colors.white10),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withAlpha(30),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 24),
        ),
        title: Text(account.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        subtitle: Text(account.email, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        trailing: isLocal
            ? const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.white24)
            : PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20, color: Colors.white54),
                onSelected: (val) {
                  if (val == 'delete') {
                    _confirmDeleteAccount(context, account, accountMgr);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                        SizedBox(width: 8),
                        Text('연결 해제', style: TextStyle(color: Colors.redAccent)),
                      ],
                    ),
                  ),
                ],
              ),
        onTap: () {
          final service = accountMgr.getService(account);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BrowserScreen(account: account, service: service),
            ),
          );
        },
      ),
    );
  }

  void _confirmDeleteAccount(BuildContext context, CloudAccount account, AccountManager mgr) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('클라우드 연결 해제'),
        content: Text('\'${account.name}\' 계정 연결을 해제하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          ElevatedButton(
            onPressed: () {
              mgr.removeAccount(account.id);
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('해제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}
