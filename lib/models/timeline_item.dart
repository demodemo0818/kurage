// lib/models/timeline_item.dart

import 'timeline_gap.dart';
import 'status.dart';

/// タイムライン上のアイテムの抽象クラス
abstract class TimelineItem {
  String get id;
  DateTime get createdAt;
  String get accountId;
}

/// 投稿アイテム
class PostItem extends TimelineItem {
  final Status status;
  
  @override
  final String accountId;

  PostItem({
    required this.status,
    required this.accountId,
  });

  @override
  String get id => status.id;

  @override
  DateTime get createdAt => status.createdAt;

  @override
  String toString() => 'PostItem{id: $id, accountId: $accountId}';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PostItem && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

/// ギャップアイテム
class GapItem extends TimelineItem {
  final TimelineGap gap;

  GapItem({required this.gap});

  @override
  String get id => gap.id;

  @override
  DateTime get createdAt => gap.newerDate ?? DateTime.now();

  /// マルチソースギャップでは「代表」ソースが無いため、`perSource` の最初の
  /// キーを返す (空なら ''))。`TimelineItem.accountId` を消費する側は
  /// 基本的に `is PostItem` でガードしてから使う想定なので、GapItem に
  /// 対する値は実質読まれない。
  @override
  String get accountId =>
      gap.perSource.isEmpty ? '' : gap.perSource.keys.first;

  @override
  String toString() => 'GapItem{gap: $gap}';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GapItem && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}