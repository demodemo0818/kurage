// lib/models/auth_account.dart

import 'package:flutter/material.dart';

class AuthAccount {
  final String id;
  final String instanceUrl;
  final String accessToken;
  final String username;
  final String displayName;
  final String avatarUrl;
  final Color? accountColor;

  AuthAccount({
    required this.id,
    required this.instanceUrl,
    required this.accessToken,
    required this.username,
    required this.displayName,
    required this.avatarUrl,
    this.accountColor,
  });

  /// `instanceUrl` からスキーム (`https://`) を除いたホスト部分。
  /// 表示用ハンドル (`@user@example.com`) のドメイン部に使う。
  /// Uri パースに失敗したときはスキームだけ剥がしてフォールバックする。
  String get host {
    final parsed = Uri.tryParse(instanceUrl)?.host;
    if (parsed != null && parsed.isNotEmpty) return parsed;
    return instanceUrl.replaceFirst(RegExp(r'^https?://'), '');
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'instanceUrl': instanceUrl,
        'accessToken': accessToken,
        'username': username,
        'displayName': displayName,
        'avatarUrl': avatarUrl,
        'accountColor': accountColor?.toARGB32(),
      };

  factory AuthAccount.fromJson(Map<String, dynamic> m) => AuthAccount(
        id: m['id'] as String,
        instanceUrl: m['instanceUrl'] as String,
        accessToken: m['accessToken'] as String,
        username: m['username'] as String,
        displayName: m['displayName'] as String,
        avatarUrl: m['avatarUrl'] as String,
        accountColor: m['accountColor'] != null ? Color(m['accountColor'] as int) : null,
      );
}
