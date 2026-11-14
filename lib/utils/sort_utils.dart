import 'package:flutter/material.dart';
import '../models/media_item.dart';
import 'natural_sort_utils.dart';

enum SortField {
  name('이름', Icons.sort_by_alpha_rounded),
  size('크기', Icons.data_usage_rounded),
  modifiedDate('변경날짜', Icons.schedule_rounded),
  type('유형', Icons.category_outlined);

  final String label;
  final IconData icon;

  const SortField(this.label, this.icon);

  bool get defaultAscending => this == name || this == type;
}

class SortUtils {
  static String getMediaTypeLabel(MediaItem item) {
    if (item.isFolder) return '폴더';
    final ext = item.name.contains('.') ? item.name.split('.').last.toUpperCase() : '';
    switch (item.bookType) {
      case MediaBookType.epub:
        return 'EPUB';
      case MediaBookType.txt:
        return ext.isNotEmpty ? 'TXT ($ext)' : 'TXT';
      case MediaBookType.pdf:
        return 'PDF';
      case MediaBookType.comicArchive:
        return ext.isNotEmpty ? 'COMIC ($ext)' : 'COMIC';
      case MediaBookType.image:
        return ext.isNotEmpty ? 'IMG ($ext)' : 'IMG';
      case MediaBookType.unknown:
        return ext.isNotEmpty ? 'FILE ($ext)' : (item.mimeType ?? 'FILE');
    }
  }

  static List<MediaItem> sortMediaItems(
    Iterable<MediaItem> items, {
    required SortField field,
    required bool ascending,
  }) {
    final list = List<MediaItem>.from(items);
    list.sort((a, b) => compareMediaItems(a, b, field: field, ascending: ascending));
    return list;
  }

  static int compareMediaItems(
    MediaItem a,
    MediaItem b, {
    required SortField field,
    required bool ascending,
  }) {
    // 1. 특수 액션 항목("__ACTION_ADD_STORAGE__")은 항상 최상단 고정
    if (a.id == '__ACTION_ADD_STORAGE__' && b.id != '__ACTION_ADD_STORAGE__') return -1;
    if (b.id == '__ACTION_ADD_STORAGE__' && a.id != '__ACTION_ADD_STORAGE__') return 1;

    // 2. 폴더를 항상 파일보다 앞에 배치
    if (a.isFolder != b.isFolder) {
      return a.isFolder ? -1 : 1;
    }

    int cmp = 0;
    switch (field) {
      case SortField.name:
        cmp = NaturalSortUtils.compare(a.name, b.name);
        return ascending ? cmp : -cmp;

      case SortField.size:
        if (a.size == null && b.size == null) {
          return NaturalSortUtils.compare(a.name, b.name);
        }
        if (a.size == null) return 1;
        if (b.size == null) return -1;
        cmp = a.size!.compareTo(b.size!);
        if (cmp != 0) return ascending ? cmp : -cmp;
        return NaturalSortUtils.compare(a.name, b.name);

      case SortField.modifiedDate:
        if (a.modifiedTime == null && b.modifiedTime == null) {
          return NaturalSortUtils.compare(a.name, b.name);
        }
        if (a.modifiedTime == null) return 1;
        if (b.modifiedTime == null) return -1;
        cmp = a.modifiedTime!.compareTo(b.modifiedTime!);
        if (cmp != 0) return ascending ? cmp : -cmp;
        return NaturalSortUtils.compare(a.name, b.name);

      case SortField.type:
        cmp = getMediaTypeLabel(a).toLowerCase().compareTo(getMediaTypeLabel(b).toLowerCase());
        if (cmp != 0) return ascending ? cmp : -cmp;
        return NaturalSortUtils.compare(a.name, b.name);
    }
  }
}
