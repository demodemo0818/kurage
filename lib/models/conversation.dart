// lib/models/conversation.dart

import '../l10n/l10n.dart';
import 'account.dart';
import 'json_utils.dart';
import 'status.dart';

/// Mastodonの会話（DM）データモデル
class Conversation {
  final String id;
  final bool unread;
  final List<Account> accounts;
  final Status? lastStatus;
  
  // プロバイダー管理用のソースアカウントID
  String? sourceAccountId;

  Conversation({
    required this.id,
    required this.unread,
    required this.accounts,
    this.lastStatus,
    this.sourceAccountId,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    return Conversation(
      id: asIdString(json['id']),
      unread: json['unread'] as bool? ?? false,
      accounts: (json['accounts'] as List<dynamic>?)
          ?.map((account) => Account.fromJson(account as Map<String, dynamic>))
          .toList() ?? [],
      lastStatus: json['last_status'] != null 
          ? Status.fromJson(json['last_status'] as Map<String, dynamic>)
          : null,
    );
  }


  Conversation copyWith({
    String? id,
    bool? unread,
    List<Account>? accounts,
    Status? lastStatus,
    String? sourceAccountId,
  }) {
    return Conversation(
      id: id ?? this.id,
      unread: unread ?? this.unread,
      accounts: accounts ?? this.accounts,
      lastStatus: lastStatus ?? this.lastStatus,
      sourceAccountId: sourceAccountId ?? this.sourceAccountId,
    );
  }

  /// 最新メッセージの作成日時を取得
  DateTime? get lastMessageTime => lastStatus?.createdAt;

  /// 会話相手の表示名を取得（複数人の場合はカンマ区切り）
  String get participantNames {
    if (accounts.isEmpty) return l10n.conversationParticipantsUnknown;
    return accounts.map((account) => account.displayName.isNotEmpty 
        ? account.displayName 
        : account.username).join(', ');
  }

  /// 会話相手のアバターURL（最初の参加者）
  String get participantAvatarUrl {
    if (accounts.isEmpty) return '';
    return accounts.first.avatarUrl;
  }
}