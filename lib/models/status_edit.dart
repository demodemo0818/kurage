// lib/models/status_edit.dart

import 'account.dart';
import 'emoji.dart';
import 'json_utils.dart';
import 'media_attachment.dart';
import 'poll.dart';

/// Mastodon `GET /api/v1/statuses/:id/history` のレスポンス要素。
///
/// 投稿の各バージョン (初版 + 各編集) のスナップショット。Status のサブセット
/// で、id / visibility / favourited 等の「投稿全体に紐づく」プロパティは
/// 持たず、編集ごとに変わりうるフィールドだけが入る。
///
/// 配列は **古い順** (= 配列先頭が初版、末尾が最新) でサーバから返ってくる。
class StatusEdit {
  /// このバージョンが作られた日時 (= 初版なら投稿時刻、編集なら編集時刻)
  final DateTime createdAt;

  /// HTML 含む本文
  final String content;

  /// CW テキスト (空のことあり)
  final String spoilerText;

  /// NSFW フラグ
  final bool sensitive;

  /// 編集者アカウント。通常は投稿主と同じ。
  final Account account;

  /// このバージョン時点のメディア添付
  final List<MediaAttachment> mediaAttachments;

  /// 投票が付いていれば
  final Poll? poll;

  /// このバージョンで参照されていたカスタム絵文字
  final List<Emoji> emojis;

  StatusEdit({
    required this.createdAt,
    required this.content,
    required this.spoilerText,
    required this.sensitive,
    required this.account,
    required this.mediaAttachments,
    this.poll,
    required this.emojis,
  });

  factory StatusEdit.fromJson(Map<String, dynamic> json) {
    return StatusEdit(
      createdAt: parseDateTimeOr(json['created_at']),
      content: (json['content'] as String?) ?? '',
      spoilerText: (json['spoiler_text'] as String?) ?? '',
      sensitive: (json['sensitive'] as bool?) ?? false,
      account: Account.fromJson(json['account'] as Map<String, dynamic>),
      mediaAttachments: (json['media_attachments'] as List<dynamic>?)
              ?.map((m) => MediaAttachment.fromJson(m as Map<String, dynamic>))
              .toList() ??
          <MediaAttachment>[],
      poll: json['poll'] != null
          ? Poll.fromJson(json['poll'] as Map<String, dynamic>)
          : null,
      emojis: (json['emojis'] as List<dynamic>?)
              ?.map((e) => Emoji.fromJson(e as Map<String, dynamic>))
              .toList() ??
          <Emoji>[],
    );
  }
}
