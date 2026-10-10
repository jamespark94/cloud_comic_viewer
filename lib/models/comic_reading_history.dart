import '../models/cloud_account.dart';

class ComicReadingHistory {
  final String id; // itemId or unique path
  final String accountId;
  final String accountName;
  final CloudType cloudType;
  final String title;
  final String? parentFolderId;
  final int lastPage; // 0-based index
  final int totalPages;
  final DateTime lastReadAt;
  final String? coverThumbnailUrl;

  ComicReadingHistory({
    required this.id,
    required this.accountId,
    required this.accountName,
    required this.cloudType,
    required this.title,
    this.parentFolderId,
    required this.lastPage,
    required this.totalPages,
    required this.lastReadAt,
    this.coverThumbnailUrl,
  });

  double get progress => totalPages > 0 ? (lastPage + 1) / totalPages : 0.0;
  int get progressPercent => (progress * 100).clamp(0, 100).round();

  Map<String, dynamic> toJson() => {
        'id': id,
        'accountId': accountId,
        'accountName': accountName,
        'cloudType': cloudType.name,
        'title': title,
        'parentFolderId': parentFolderId,
        'lastPage': lastPage,
        'totalPages': totalPages,
        'lastReadAt': lastReadAt.toIso8601String(),
        'coverThumbnailUrl': coverThumbnailUrl,
      };

  factory ComicReadingHistory.fromJson(Map<String, dynamic> json) => ComicReadingHistory(
        id: json['id'] as String,
        accountId: json['accountId'] as String,
        accountName: json['accountName'] as String,
        cloudType: CloudType.values.firstWhere(
          (e) => e.name == json['cloudType'],
          orElse: () => CloudType.local,
        ),
        title: json['title'] as String,
        parentFolderId: json['parentFolderId'] as String?,
        lastPage: json['lastPage'] as int? ?? 0,
        totalPages: json['totalPages'] as int? ?? 1,
        lastReadAt: DateTime.tryParse(json['lastReadAt'] as String? ?? '') ?? DateTime.now(),
        coverThumbnailUrl: json['coverThumbnailUrl'] as String?,
      );
}
