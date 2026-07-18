// lib/providers/auth_provider.dart

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/auth_account.dart';
import '../services/analytics_service.dart';
import '../services/auth_service.dart';
import '../services/push_notification_service.dart';

/// 認証アカウントリストを保持する状態。
///
/// 旧来は `current` (= プライマリアカウント) を持っていたが、各画面で都度
/// 使用アカウントを選ぶ UX に統一したため廃止。各画面はローカル state +
/// SharedPreferences で「最後に使ったアカウント」を覚える方式 (post_page /
/// search_page など)、または明示的な `accountId` パラメタで指定する方式
/// (post_tile / thread_page など)、もしくは `accounts.first` フォールバック。
class AuthState {
  final List<AuthAccount> accounts;
  AuthState({required this.accounts});
}

/// 認証管理用 Notifier
class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(AuthState(accounts: [])) {
    _loadFromPrefs();
  }

  // デフォルトカラーのリスト
  static const List<Color> _defaultColors = [
    Colors.blue,
    Colors.green,
    Colors.orange,
    Colors.purple,
    Colors.red,
    Colors.teal,
    Colors.pink,
    Colors.indigo,
    Colors.amber,
    Colors.cyan,
  ];

  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('accounts');
    if (jsonStr != null) {
      try {
        final list =
            (jsonDecode(jsonStr) as List).cast<Map<String, dynamic>>();
        final accs = list.map((m) => AuthAccount.fromJson(m)).toList();
        state = AuthState(accounts: accs);
      } catch (e) {
        // 破損 JSON (書き込み中のクラッシュ等) で起動不能にならないよう防御。
        // トークンを失わないよう生文字列を退避してから空状態で続行する
        // (後続の login → _saveToPrefs が 'accounts' を上書きするため)。
        debugPrint('accounts の読み込みに失敗: $e');
        await prefs.setString('accounts_corrupt_backup', jsonStr);
      }
    }
  }

  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final list = state.accounts.map((a) => a.toJson()).toList();
    await prefs.setString('accounts', jsonEncode(list));
  }

  /// OAuth で新規ログイン
  Future<void> login(String instanceUrl) async {
    var acct = await AuthService.login(instanceUrl: instanceUrl);

    // デフォルトカラーを割り当て（既存アカウント数に基づいてカラーを選択）
    final colorIndex = state.accounts.length % _defaultColors.length;
    acct = AuthAccount(
      id: acct.id,
      instanceUrl: acct.instanceUrl,
      accessToken: acct.accessToken,
      username: acct.username,
      displayName: acct.displayName,
      avatarUrl: acct.avatarUrl,
      accountColor: _defaultColors[colorIndex],
    );

    final result = upsertAccount(state.accounts, acct);
    state = AuthState(accounts: result.accounts);
    await _saveToPrefs();
    if (!result.replaced) {
      // 利用状況: アカウント追加成功 (件数のみ。instance URL 等は送らない)。
      AnalyticsService.instance.logEvent('account_added',
          parameters: {'account_count': result.accounts.length});
    }

    // 新規ログイン直後にこのアカウントの購読を登録する。従来は起動時の
    // 自動登録のみだったため、アプリを再起動するまでプッシュが届かなかった。
    // ログイン完了 UX をブロックしないよう fire-and-forget (失敗は内部でログ)。
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final registered = acct;
      unawaited(() async {
        try {
          if (!await PushNotificationService.readPushEnabledFromPrefs()) return;
          final ok = await PushNotificationService()
              .registerPushNotification(registered);
          debugPrint('[Push] post-login register ${registered.username}: $ok');
        } catch (e) {
          debugPrint('[Push] post-login register failed: $e');
        }
      }());
    }
  }

  /// [accounts] に [acct] を upsert した新リストを返す。同一サーバ
  /// (`instanceUrl`) の同一 ID なら再ログイン = トークン/プロフィール更新
  /// として追加でなく置換し、`accountColor` は旧値を維持する。
  ///
  /// 重複登録を許すと `updateSelectedAccounts` が同一アカウントに通知 SSE を
  /// 2 本張り、通知が二重表示になる。ID は verify_credentials のサーバ
  /// ローカル ID なので、別インスタンスの偶然一致を誤置換しないよう
  /// `instanceUrl` との複合で判定する。
  @visibleForTesting
  static ({List<AuthAccount> accounts, bool replaced}) upsertAccount(
    List<AuthAccount> accounts,
    AuthAccount acct,
  ) {
    final existingIndex = accounts
        .indexWhere((a) => a.id == acct.id && a.instanceUrl == acct.instanceUrl);
    if (existingIndex < 0) {
      return (accounts: [...accounts, acct], replaced: false);
    }
    final old = accounts[existingIndex];
    final updated = [...accounts];
    updated[existingIndex] = AuthAccount(
      id: acct.id,
      instanceUrl: acct.instanceUrl,
      accessToken: acct.accessToken,
      username: acct.username,
      displayName: acct.displayName,
      avatarUrl: acct.avatarUrl,
      accountColor: old.accountColor ?? acct.accountColor,
    );
    return (accounts: updated, replaced: true);
  }

  /// バックアップからのアカウント一括インポート。既存アカウントを丸ごと
  /// 置き換える (フルバックアップ復元)。アクセストークンを
  /// 含むので、復元後はそのままサーバ API が叩ける。
  Future<void> importAccounts(List<AuthAccount> accounts) async {
    state = AuthState(accounts: accounts);
    await _saveToPrefs();
  }

  /// ログアウト（アカウント削除）
  Future<void> logout(String accountId) async {
    // 削除するアカウントのプッシュ購読をサーバ側から解除しておく。
    // これをやらないと、ログアウト後もリレー経由で通知が飛び続ける
    // (端末を手放した後も通知が届く / 別端末に再ログインすると二重配信)。
    for (final acct in state.accounts.where((a) => a.id == accountId)) {
      await PushNotificationService().unregisterPushNotification(acct);
    }
    final updated = state.accounts.where((a) => a.id != accountId).toList();
    state = AuthState(accounts: updated);
    await _saveToPrefs();
  }

  /// アカウントの色を更新
  Future<void> updateAccountColor(String accountId, Color? color) async {
    final updated = state.accounts.map((a) {
      if (a.id == accountId) {
        return AuthAccount(
          id: a.id,
          instanceUrl: a.instanceUrl,
          accessToken: a.accessToken,
          username: a.username,
          displayName: a.displayName,
          avatarUrl: a.avatarUrl,
          accountColor: color,
        );
      }
      return a;
    }).toList();

    state = AuthState(accounts: updated);
    await _saveToPrefs();
  }

  /// アカウント情報を更新（プロフィール編集時に使用）
  Future<void> updateAccountInfo(String accountId,
      {String? displayName, String? avatarUrl}) async {
    final updated = state.accounts.map((a) {
      if (a.id == accountId) {
        return AuthAccount(
          id: a.id,
          instanceUrl: a.instanceUrl,
          accessToken: a.accessToken,
          username: a.username,
          displayName: displayName ?? a.displayName,
          avatarUrl: avatarUrl ?? a.avatarUrl,
          accountColor: a.accountColor,
        );
      }
      return a;
    }).toList();

    state = AuthState(accounts: updated);
    await _saveToPrefs();
  }
}

/// グローバルプロバイダ
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});
