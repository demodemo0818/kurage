// lib/models/notification_group.dart

import 'account.dart';
import 'json_utils.dart';
import 'notification_item.dart';
import 'status.dart';

/// Mastodon 4.3+ の `/api/v2/notifications` が返す `NotificationGroup`、および
/// 単体通知 (v1 or グルーピング対象外タイプ) を「件数 1 のグループ」として
/// 同じ型で表現する内部モデル。
///
/// プロバイダ側で「サーバが返したグループ」と「SSE で来た単発通知」を同じ
/// `List<NotificationGroup>` として扱えるようにするため、両方を吸収する形に
/// した。`fromV2Json` は server 集約、`single` は v1 / SSE 単発をラップする。
///
/// `notificationsCount == 1` のときは UI 側で従来の単体通知と同じ見た目で
/// 描画する。`> 1` のときは「○○さん 他 N 人が…」のグループ表示にする。
class NotificationGroup {
  /// グループの安定 ID。
  /// - v2 の場合: `group_key` (server 由来)
  /// - v1 / SSE 単発の場合: その通知の id をそのまま使う
  final String id;

  /// `group_key` を別途持つ。client-side マージで「同じ group の incoming」
  /// 判定に使う。v1 単体ラップ時は notification id と同じ値が入る。
  final String groupKey;

  /// 通知タイプ。グループ内の全要素で共通 (server がそういう集約をする)。
  final NotificationType type;

  /// グループ内で最新の通知の発生時刻。ソートキー兼「グループ全体の時刻」。
  final DateTime latestAt;

  /// グループに含まれる個別通知の総数。`> 1` ならグルーピング表示。
  final int notificationsCount;

  /// グループのアクター候補 (sample_account_ids を Account にひも付けたもの)。
  /// UI で表示するのは最大 6 件 (公式 Android 準拠)。
  final List<Account> sampleAccounts;

  /// 対象 status。favourite / reblog / mention / poll / status / update /
  /// quote 等のときに non-null。follow / follow_request では null。
  final Status? status;

  /// このグループを保有する Kurage 側アカウント (= マルチアカウント識別)。
  /// notifications_provider 側で複数アカウントの通知を結合表示する都合上、
  /// 各グループがどのアカウント由来か追跡する必要がある。
  String? sourceAccountId;

  /// グループ内最新通知の id (markAsRead / SSE の dedup 用)。
  final String mostRecentNotificationId;

  /// collection 系通知が参照する Collection の id (寛容パース、未確定なら null)。
  /// 通知タップでコレクション詳細へ飛ぶために使う。詳細は
  /// [NotificationItem.collectionId] のコメント参照 (実機検証ゲート)。
  final String? collectionId;

  NotificationGroup({
    required this.id,
    required this.groupKey,
    required this.type,
    required this.latestAt,
    required this.notificationsCount,
    required this.sampleAccounts,
    required this.mostRecentNotificationId,
    this.status,
    this.sourceAccountId,
    this.collectionId,
  });

  /// グルーピング表示するかどうか。`notificationsCount > 1` でグループ。
  bool get isGroup => notificationsCount > 1;

  /// グループの代表アカウント (1 件目)。`sampleAccounts` が空のときは null。
  Account? get primaryAccount =>
      sampleAccounts.isEmpty ? null : sampleAccounts.first;

  /// 単発通知 (v1 fetch / SSE) を「件数 1 のグループ」にラップする。
  /// 既存 v1 経路の出力をそのままグループ表現に揃えるのに使う。
  factory NotificationGroup.single(NotificationItem item) {
    return NotificationGroup(
      id: item.id,
      groupKey: item.id,
      type: item.type,
      latestAt: item.createdAt,
      notificationsCount: 1,
      sampleAccounts: [item.account],
      mostRecentNotificationId: item.id,
      status: item.status,
      sourceAccountId: item.sourceAccountId,
      collectionId: item.collectionId,
    );
  }

  /// 単発通知のリストをそのままグループ化せず 1:1 ラップして返す。
  /// v2 未対応サーバへのフォールバック経路で使う。
  static List<NotificationGroup> singlesFrom(
    List<NotificationItem> items,
  ) {
    return items.map(NotificationGroup.single).toList();
  }

  /// `/api/v2/notifications` のレスポンスからグループ群を組み立てる。
  /// レスポンスは `notification_groups[]` + `accounts[]` + `statuses[]` の
  /// 3 配列で参照が分離しているので、id → entity のマップを呼び出し側で
  /// 作って渡す前提。
  factory NotificationGroup.fromV2Json(
    Map<String, dynamic> g,
    Map<String, Account> accountsById,
    Map<String, Status> statusesById,
  ) {
    final rawType = g['type'] as String;
    final type = _parseType(rawType);

    final sampleIds = ((g['sample_account_ids'] as List<dynamic>?) ?? const [])
        .map(asIdStringOrNull)
        .whereType<String>()
        .toList();
    final accounts = <Account>[];
    for (final sid in sampleIds) {
      final acc = accountsById[sid];
      if (acc != null) accounts.add(acc);
    }

    Status? status;
    final statusId = asIdStringOrNull(g['status_id']);
    if (statusId != null) {
      status = statusesById[statusId];
    }

    final latestAtStr = g['latest_page_notification_at'] as String?;
    final latestAt = latestAtStr != null
        ? (DateTime.tryParse(latestAtStr) ?? DateTime.now())
        : DateTime.now();

    final groupKey = asIdStringOrNull(g['group_key']);
    final mostRecentId =
        asIdStringOrNull(g['most_recent_notification_id']) ?? '';

    return NotificationGroup(
      id: groupKey ?? mostRecentId,
      groupKey: groupKey ?? mostRecentId,
      type: type,
      latestAt: latestAt,
      notificationsCount: (g['notifications_count'] as int?) ?? accounts.length,
      sampleAccounts: accounts,
      mostRecentNotificationId: mostRecentId,
      status: status,
      collectionId: _parseCollectionId(g),
    );
  }

  /// グループ JSON から Collection id を寛容に取り出す (実機検証ゲート)。
  /// `collection_id` → 埋め込み `collection.id` の順で試す。
  static String? _parseCollectionId(Map<String, dynamic> g) {
    final direct = asIdStringOrNull(g['collection_id']);
    if (direct != null) return direct;
    final embedded = g['collection'];
    if (embedded is Map<String, dynamic>) {
      return asIdStringOrNull(embedded['id']);
    }
    return null;
  }

  /// `notification_item.dart` の `_parseType` と同じロジックを内部に持つ。
  /// (NotificationItem.fromJson は通知 1 件分の JSON を期待するので、
  ///  type 文字列だけ取り出す本関数を別途用意する)
  static NotificationType _parseType(String raw) {
    switch (raw) {
      case 'mention':
        return NotificationType.mention;
      case 'reply':
        return NotificationType.reply;
      case 'favourite':
        return NotificationType.favourite;
      case 'reblog':
        return NotificationType.reblog;
      case 'follow':
        return NotificationType.follow;
      case 'poll':
        return NotificationType.poll;
      case 'emoji_reaction':
        return NotificationType.reaction;
      case 'follow_request':
        return NotificationType.followRequest;
      case 'status':
        return NotificationType.status;
      case 'quote':
        return NotificationType.quote;
      case 'added_to_collection':
        return NotificationType.addedToCollection;
      case 'collection_update':
        return NotificationType.collectionUpdate;
      default:
        return NotificationType.unknown;
    }
  }

  /// SSE 受信時にこのグループへ「同じグループ判定で取り込めるか」を判定。
  /// マージは notifications_provider 側で実施する。
  ///
  /// 判定ルール (client-side マージ用、選択肢 B):
  /// - 同じ Kurage アカウント由来であること
  /// - 同じ type
  /// - favourite / reblog / poll: 同じ status_id
  /// - follow / followRequest / status (自分の投稿) / reaction: type だけで集約
  ///   かつ最新通知から 5 分以内
  /// - mention / reply / quote / unknown: 常に singleton (= false を返す)
  ///   (quote は各引用が別投稿なので集約しない)
  bool canMerge(NotificationGroup incoming) {
    if (sourceAccountId != incoming.sourceAccountId) return false;
    if (type != incoming.type) return false;

    switch (type) {
      case NotificationType.favourite:
      case NotificationType.reblog:
      case NotificationType.poll:
        return status != null && status!.id == incoming.status?.id;
      case NotificationType.reaction:
      case NotificationType.follow:
      case NotificationType.followRequest:
      case NotificationType.status:
        return incoming.latestAt.difference(latestAt).inMinutes.abs() <= 5;
      case NotificationType.mention:
      case NotificationType.reply:
      case NotificationType.quote:
      // collection 系はマージキーになる collection 参照が未確定なので singleton
      case NotificationType.addedToCollection:
      case NotificationType.collectionUpdate:
      case NotificationType.unknown:
        return false;
    }
  }

  /// 取り込んだ通知をマージしたあとの新しい NotificationGroup を返す。
  /// 既存アカウントが含まれていれば順序だけ先頭に移動 (重複追加しない)。
  /// `notificationsCount` は server-side では純粋な集約件数だが、
  /// client-side では「既存件数 + 1」で incremental 増加させる
  /// (overstate しないため重複ユーザーの場合は据え置き)。
  NotificationGroup mergedWith(NotificationGroup incoming) {
    final newAccount =
        incoming.sampleAccounts.isEmpty ? null : incoming.sampleAccounts.first;

    List<Account> updatedAccounts;
    bool isDuplicateActor = false;
    if (newAccount == null) {
      updatedAccounts = sampleAccounts;
    } else {
      // 同じアクターが既にいる場合は先頭に移動 (重複追加しない)
      final existingIdx =
          sampleAccounts.indexWhere((a) => a.id == newAccount.id);
      if (existingIdx >= 0) {
        isDuplicateActor = true;
        updatedAccounts = [
          newAccount,
          ...sampleAccounts.where((a) => a.id != newAccount.id),
        ];
      } else {
        // 先頭に追加し、最大 6 件まで保持 (公式 Android 準拠)
        updatedAccounts = [newAccount, ...sampleAccounts].take(6).toList();
      }
    }

    return NotificationGroup(
      id: id, // group key は維持
      groupKey: groupKey,
      type: type,
      latestAt: incoming.latestAt.isAfter(latestAt)
          ? incoming.latestAt
          : latestAt,
      notificationsCount:
          isDuplicateActor ? notificationsCount : notificationsCount + 1,
      sampleAccounts: updatedAccounts,
      mostRecentNotificationId: incoming.mostRecentNotificationId,
      status: status ?? incoming.status,
      sourceAccountId: sourceAccountId,
      collectionId: collectionId ?? incoming.collectionId,
    );
  }

  /// fetch で取れた最新グループを既存リストにマージ。
  /// 同じ groupKey が既存にある場合は server 側 (新しい方) で置換、
  /// 無いものは追加。最後に latestAt 降順でソート。
  static List<NotificationGroup> mergeFetched(
    List<NotificationGroup> fetched,
    List<NotificationGroup> current,
  ) {
    final byKey = <String, NotificationGroup>{};
    for (final g in current) {
      byKey[g.groupKey] = g;
    }
    for (final g in fetched) {
      byKey[g.groupKey] = g; // 新しい server 値で上書き
    }
    final merged = byKey.values.toList()
      ..sort((a, b) => b.latestAt.compareTo(a.latestAt));
    return merged;
  }
}
