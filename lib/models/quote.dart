// lib/models/quote.dart

import '../l10n/l10n.dart';
import 'status.dart';

/// 引用 (Mastodon 4.4+ 公式仕様)
///
/// Status の `quote` フィールドに含まれるオブジェクト。
/// state が `accepted` の場合のみ [quotedStatus] が実体を持つ。
class Quote {
  final QuoteState state;
  final Status? quotedStatus;
  final String? quotedStatusId;
  final String? quotedStatusAccountId;

  Quote({
    required this.state,
    this.quotedStatus,
    this.quotedStatusId,
    this.quotedStatusAccountId,
  });

  factory Quote.fromJson(Map<String, dynamic> json) {
    return Quote(
      state: QuoteState.fromString(json['state'] as String?),
      quotedStatus: json['quoted_status'] != null
          ? Status.fromJson(json['quoted_status'] as Map<String, dynamic>)
          : null,
      quotedStatusId: json['quoted_status_id'] as String?,
      quotedStatusAccountId: json['quoted_status_account_id'] as String?,
    );
  }
}

/// 引用の承認状態
enum QuoteState {
  /// 承認待ち (引用元アカウントが承認制で、まだ承認していない)
  pending,

  /// 承認済み — 実体が表示可能
  accepted,

  /// 拒否された
  rejected,

  /// 一度承認されたが取り消された
  revoked,

  /// 引用元投稿が削除された
  deleted,

  /// 閲覧権限がない
  unauthorized,

  /// 未知の state
  unknown;

  static QuoteState fromString(String? raw) {
    return switch (raw) {
      'pending' => pending,
      'accepted' => accepted,
      'rejected' => rejected,
      'revoked' => revoked,
      'deleted' => deleted,
      'unauthorized' => unauthorized,
      _ => unknown,
    };
  }

  /// ユーザー向け表示文言 (accepted の時は呼ばれない想定)
  String get displayLabel {
    return switch (this) {
      pending => l10n.quoteStatePending,
      rejected => l10n.quoteStateRejected,
      revoked => l10n.quoteStateRevoked,
      deleted => l10n.quoteStateDeleted,
      unauthorized => l10n.quoteStateUnauthorized,
      accepted => '', // 実体表示するので不要
      unknown => l10n.quoteStateUnknown,
    };
  }
}
