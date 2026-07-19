// lib/services/push_notification_style.dart
//
// プッシュ通知の「種別 → 見た目 (絵文字 / チャンネル / アクセント色)」の
// マッピング。FCM のバックグラウンド isolate からも使うため、Flutter widget
// に依存しない純粋 Dart で切り出してある (dart:ui の Color のみ使用)。
// 種別の分類と配色はアプリ内通知ページ (notifications_page.dart の
// _getNotificationIcon / _getNotificationColor) に揃える。

import 'dart:ui' show Color;

import '../l10n/l10n.dart';

/// アプリのテーマ紫 (既存の通知アクセント色)。
const Color _kThemePurple = Color(0xFF6750A4);

/// 通知チャンネルの定義。flutter_local_notifications の
/// AndroidNotificationChannel に変換して使う (このファイルはプラグイン非依存)。
class PushChannel {
  final String id;
  final String name;
  final String description;

  const PushChannel({
    required this.id,
    required this.name,
    required this.description,
  });
}

/// Android 設定に並ぶプッシュ通知チャンネル一覧。種別ごとに音・ミュートを
/// ユーザーが個別制御できるよう分割している。
/// `l10n` (現在の表示言語) を参照するため const にはできない。
List<PushChannel> get allPushChannels => [
      PushChannel(
        id: 'notif_mention',
        name: l10n.pushChannelMentionName,
        description: l10n.pushChannelMentionDesc,
      ),
      PushChannel(
        id: 'notif_boost',
        name: l10n.pushChannelBoostName,
        description: l10n.pushChannelBoostDesc,
      ),
      PushChannel(
        id: 'notif_favourite',
        name: l10n.pushChannelFavouriteName,
        description: l10n.pushChannelFavouriteDesc,
      ),
      PushChannel(
        id: 'notif_follow',
        name: l10n.pushChannelFollowName,
        description: l10n.pushChannelFollowDesc,
      ),
      PushChannel(
        id: 'notif_other',
        name: l10n.pushChannelOtherName,
        description: l10n.pushChannelOtherDesc,
      ),
    ];

/// 1 通知の見た目。[pushStyleForType] が種別文字列から決定する。
class PushNotificationStyle {
  /// 表示に使うチャンネル (allPushChannels のいずれか)。
  final PushChannel channel;

  /// タイトル先頭に付ける絵文字。null なら付けない。
  final String? emoji;

  /// 小アイコンのアクセント色。
  final Color color;

  const PushNotificationStyle({
    required this.channel,
    required this.emoji,
    required this.color,
  });
}

PushChannel _channelById(String id) =>
    allPushChannels.firstWhere((c) => c.id == id);

/// Mastodon push payload の `notification_type` 生値から通知の見た目を決める。
/// 未知の種別・null は「その他」チャンネル + 絵文字なしに落ちる (通知自体は
/// 必ず出す方針なので throw しない)。
PushNotificationStyle pushStyleForType(String? rawType) {
  switch (rawType) {
    case 'mention':
    case 'reply':
      return PushNotificationStyle(
        channel: _channelById('notif_mention'),
        emoji: '💬',
        color: const Color(0xFF2196F3), // blue
      );
    case 'quote':
      return PushNotificationStyle(
        channel: _channelById('notif_mention'),
        emoji: '🗨️',
        color: const Color(0xFF2196F3),
      );
    case 'reblog':
      return PushNotificationStyle(
        channel: _channelById('notif_boost'),
        emoji: '🔁',
        color: const Color(0xFF4CAF50), // green
      );
    case 'favourite':
      return PushNotificationStyle(
        channel: _channelById('notif_favourite'),
        emoji: '⭐',
        color: const Color(0xFFFFC107), // amber
      );
    case 'emoji_reaction':
      return PushNotificationStyle(
        channel: _channelById('notif_favourite'),
        emoji: '😀',
        color: const Color(0xFFFFC107),
      );
    case 'follow':
      return PushNotificationStyle(
        channel: _channelById('notif_follow'),
        emoji: '👤',
        color: _kThemePurple,
      );
    case 'follow_request':
      return PushNotificationStyle(
        channel: _channelById('notif_follow'),
        emoji: '🤝',
        color: _kThemePurple,
      );
    case 'poll':
      return PushNotificationStyle(
        channel: _channelById('notif_other'),
        emoji: '📊',
        color: _kThemePurple,
      );
    case 'status':
      return PushNotificationStyle(
        channel: _channelById('notif_other'),
        emoji: '📝',
        color: _kThemePurple,
      );
    case 'update':
      return PushNotificationStyle(
        channel: _channelById('notif_other'),
        emoji: '✏️',
        color: _kThemePurple,
      );
    default:
      return PushNotificationStyle(
        channel: _channelById('notif_other'),
        emoji: null,
        color: _kThemePurple,
      );
  }
}
