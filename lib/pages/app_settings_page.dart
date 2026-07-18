// lib/pages/app_settings_page.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import '../services/analytics_service.dart';
import '../services/backup_file.dart';
import '../services/backup_service.dart';
import '../services/image_save_io.dart';
import '../services/push_notification_service.dart';
import '../services/sentry_config.dart';
import '../services/wake_lock_service.dart';
import '../utils/platform.dart';
import '../utils/snackbar_helpers.dart';
import '../widgets/settings_section.dart';

/// アプリ設定ページ (Android「設定」アプリ風レイアウト)
class AppSettingsPage extends ConsumerStatefulWidget {
  const AppSettingsPage({super.key});

  @override
  ConsumerState<AppSettingsPage> createState() => _AppSettingsPageState();
}

class _AppSettingsPageState extends ConsumerState<AppSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final settingsNotifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('アプリ設定'),
      ),
      body: SettingsListView(
        children: [
          // ========== リアクション確認 ==========
          SettingsSection(
            title: 'リアクション確認',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.repeat, color: Colors.green),
                title: const Text('ブースト時の確認ダイアログ'),
                subtitle: const Text('ブースト追加時に確認ダイアログを表示'),
                value: settings.confirmReblog,
                onChanged: (value) =>
                    settingsNotifier.setConfirmReblog(value),
              ),
              SwitchListTile(
                secondary:
                    const Icon(Icons.repeat_on_outlined, color: Colors.green),
                title: const Text('ブースト解除時の確認ダイアログ'),
                subtitle: const Text('ブースト解除時に確認ダイアログを表示'),
                value: settings.confirmUnreblog,
                onChanged: (value) =>
                    settingsNotifier.setConfirmUnreblog(value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.star, color: Colors.amber),
                title: const Text('お気に入り時の確認ダイアログ'),
                subtitle: const Text('お気に入り追加時に確認ダイアログを表示'),
                value: settings.confirmFavourite,
                onChanged: (value) =>
                    settingsNotifier.setConfirmFavourite(value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.star_border, color: Colors.amber),
                title: const Text('お気に入り解除時の確認ダイアログ'),
                subtitle: const Text('お気に入り解除時に確認ダイアログを表示'),
                value: settings.confirmUnfavourite,
                onChanged: (value) =>
                    settingsNotifier.setConfirmUnfavourite(value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.bookmark, color: Colors.indigo),
                title: const Text('ブックマーク時の確認ダイアログ'),
                subtitle: const Text('ブックマーク追加時に確認ダイアログを表示'),
                value: settings.confirmBookmark,
                onChanged: (value) =>
                    settingsNotifier.setConfirmBookmark(value),
              ),
              SwitchListTile(
                secondary:
                    const Icon(Icons.bookmark_border, color: Colors.indigo),
                title: const Text('ブックマーク解除時の確認ダイアログ'),
                subtitle: const Text('ブックマーク解除時に確認ダイアログを表示'),
                value: settings.confirmUnbookmark,
                onChanged: (value) =>
                    settingsNotifier.setConfirmUnbookmark(value),
              ),
            ],
          ),

          // ========== その他 ==========
          SettingsSection(
            title: 'その他',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.exit_to_app, color: Colors.red),
                title: const Text('アプリ終了時の確認ダイアログ'),
                subtitle: const Text(
                    '戻るボタンでアプリを終了する際に確認ダイアログを表示します'),
                value: settings.confirmAppExit,
                onChanged: (value) {
                  settingsNotifier.setConfirmAppExit(value);
                },
              ),
              // Web では Screen Wake Lock API の対応がブラウザ次第で
              // 安定しない (Safari は未対応、Chrome は HTTPS 必須) + そもそも
              // ブラウザタブで「スリープ無効」のユースケースが薄いため、
              // 設定 UI 自体を出さない。kIsWeb での collection-if 分岐。
              if (!kIsWeb)
                SwitchListTile(
                  secondary:
                      const Icon(Icons.bedtime_off, color: Colors.purple),
                  title: const Text('スリープ無効化'),
                  subtitle:
                      const Text('アプリ使用中の画面の自動消灯を防ぎます'),
                  value: settings.keepScreenOn,
                  onChanged: (value) async {
                    await settingsNotifier.setKeepScreenOn(value);
                    // 設定変更時にWake Lockも即座に更新
                    await WakeLockService.updateFromSettings(value);
                  },
                ),
            ],
          ),

          // ========== 画像の保存先 (デスクトップのみ) ==========
          // モバイルは Android = ピクチャ / iOS = サンドボックスに固定保存する
          // ため、保存先を選べるデスクトップ (Windows/macOS/Linux) でのみ出す。
          if (isDesktop())
            SettingsSection(
              title: '画像の保存先',
              children: [
                ListTile(
                  leading:
                      const Icon(Icons.folder_outlined, color: Colors.amber),
                  title: const Text('保存先フォルダ'),
                  subtitle: Text(
                    settings.confirmImageSaveLocation
                        ? '「保存先を毎回確認する」が ON のとき無視されます'
                        : ((settings.imageSaveDirectory?.isNotEmpty ?? false)
                            ? settings.imageSaveDirectory!
                            : 'ダウンロード（既定）'),
                  ),
                  trailing: (settings.imageSaveDirectory?.isNotEmpty ?? false)
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: '既定（ダウンロード）に戻す',
                          onPressed: () =>
                              settingsNotifier.setImageSaveDirectory(null),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: () async {
                    final dir = await pickSaveDirectory();
                    if (dir != null) {
                      await settingsNotifier.setImageSaveDirectory(dir);
                    }
                  },
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.save_as, color: Colors.amber),
                  title: const Text('保存先を毎回確認する'),
                  subtitle: const Text(
                      '画像を保存するたびに保存先を選ぶダイアログを表示します'),
                  value: settings.confirmImageSaveLocation,
                  onChanged: (value) =>
                      settingsNotifier.setConfirmImageSaveLocation(value),
                ),
              ],
            ),

          // ========== サウンド (効果音) ==========
          // アプリ表示中 (フォアグラウンド) のみ。音源は assets/sounds/ に
          // 同梱済み (notification.mp3 / post.mp3 / refresh.mp3)。
          SettingsSection(
            title: 'サウンド（効果音）',
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active,
                    color: Colors.orange),
                title: const Text('通知受信時に音を鳴らす'),
                subtitle: const Text(
                    'アプリ表示中に通知が届いたとき効果音を鳴らします'),
                value: settings.soundOnNotification,
                onChanged: (value) =>
                    settingsNotifier.setSoundOnNotification(value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.send, color: Colors.blue),
                title: const Text('投稿完了時に音を鳴らす'),
                subtitle: const Text(
                    '投稿が完了したとき効果音を鳴らします'),
                value: settings.soundOnPost,
                onChanged: (value) => settingsNotifier.setSoundOnPost(value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.refresh, color: Colors.teal),
                title: const Text('引っ張って更新時に音を鳴らす'),
                subtitle: const Text(
                    'タイムラインを引っ張って更新したとき効果音を鳴らします'),
                value: settings.soundOnRefresh,
                onChanged: (value) => settingsNotifier.setSoundOnRefresh(value),
              ),
            ],
          ),

          // ========== ボスキー (偽装モード) ==========
          // Web / デスクトップ限定。物理キーボードの F9 でアプリ全体を
          // 某検索サイト風の見た目に切り替える隠し機能。
          if (isWebOrDesktop())
            SettingsSection(
              title: 'ボスキー（偽装モード）',
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.search, color: Colors.blue),
                  title: const Text('ボスキーを有効にする'),
                  subtitle: const Text(
                      'F9 でアプリ全体を某検索サイト風の見た目に切り替えます'
                      '（もう一度 F9 で戻る。macOS では Fn+F9 の場合あり）'),
                  value: settings.bossKeyEnabled,
                  onChanged: (value) =>
                      settingsNotifier.setBossKeyEnabled(value),
                ),
              ],
            ),

          // ========== バックアップ ==========
          SettingsSection(
            title: 'バックアップ',
            children: [
              ListTile(
                leading: const Icon(Icons.upload_file, color: Colors.blue),
                title: const Text('設定をエクスポート'),
                subtitle: const Text(
                    '設定・カラム・アカウントを .json に書き出します (アクセストークンを含む)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _exportBackup,
              ),
              ListTile(
                leading: const Icon(Icons.download, color: Colors.green),
                title: const Text('設定をインポート'),
                subtitle: const Text(
                    'バックアップ .json から復元します (現在のデータを上書き)'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _importBackup,
              ),
            ],
          ),

          // ========== プライバシー・サポート ==========
          // プッシュ通知は Android (FCM) のみ対応。Web/デスクトップ/iOS では
          // 設定項目自体を出さない (機能が無効なので)。
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            SettingsSection(
              title: '通知',
              children: [
                SwitchListTile(
                  secondary: const Icon(
                      Icons.notifications_active_outlined,
                      color: Colors.teal),
                  title: const Text('プッシュ通知'),
                  subtitle: const Text(
                      'メンション・ブースト・お気に入りなどの通知を受け取ります。オフにするとサーバへの購読を解除します'),
                  value: settings.pushNotificationsEnabled,
                  onChanged: (value) async {
                    await settingsNotifier
                        .setPushNotificationsEnabled(value);
                    final push = PushNotificationService();
                    if (value) {
                      await push.registerAllSavedAccounts();
                    } else {
                      await push.unregisterAllSavedAccounts();
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.troubleshoot_outlined,
                      color: Colors.teal),
                  title: const Text('プッシュ通知の状態を確認'),
                  subtitle: const Text(
                      '通知権限・接続状態を確認し、全アカウントの購読を再登録します。通知が届かないときにお試しください'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _runPushDiagnostics,
                ),
              ],
            ),

          SettingsSection(
            title: 'プライバシー・サポート',
            children: [
              SwitchListTile(
                secondary:
                    const Icon(Icons.bug_report_outlined, color: Colors.teal),
                title: const Text('クラッシュレポートを送信'),
                subtitle: const Text(
                    'アプリが異常終了したときにスタックトレースを開発者に送信します (個人を特定できる情報は含みません)'),
                value: settings.crashReportingEnabled,
                onChanged: (value) async {
                  await settingsNotifier.setCrashReportingEnabled(value);
                  // モバイルは Crashlytics、Web/デスクトップは Sentry を live で
                  // 反映する (Sentry は beforeSend がこのフラグを見て送信/破棄)。
                  sentryReportingEnabled = value;
                  if (!kIsWeb) {
                    try {
                      await FirebaseCrashlytics.instance
                          .setCrashlyticsCollectionEnabled(value);
                    } catch (e) {
                      debugPrint('Crashlytics 設定変更エラー: $e');
                    }
                  }
                },
              ),
              SwitchListTile(
                secondary:
                    const Icon(Icons.insights_outlined, color: Colors.teal),
                title: const Text('利用状況の解析を送信'),
                subtitle: const Text(
                    'どの機能がどれくらい使われているかの匿名の集計情報を送信します (個人やアカウント・投稿内容を特定できる情報は含みません)'),
                value: settings.analyticsEnabled,
                onChanged: (value) async {
                  await settingsNotifier.setAnalyticsEnabled(value);
                  await AnalyticsService.instance.setEnabled(value);
                },
              ),
            ],
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// エクスポート用のファイル名 (例: kurage-backup-20260603-110428.json)。
  String _backupFileName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'kurage-backup-${n.year}${two(n.month)}${two(n.day)}'
        '-${two(n.hour)}${two(n.minute)}${two(n.second)}.json';
  }

  /// プッシュ通知の状態確認 + 全アカウント購読再登録 (自己修復手段を兼ねる)。
  /// 通知が届かない報告の切り分け用: 権限 / FCM トークン / リレー到達性 /
  /// アカウント別の登録結果をダイアログに表示する。
  Future<void> _runPushDiagnostics() async {
    // 実行中インジケータ (診断は数秒かかる)
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(child: Text('確認中…')),
          ],
        ),
      ),
    );

    List<String> lines;
    try {
      lines = await PushNotificationService().runDiagnostics();
    } catch (e) {
      lines = ['診断に失敗しました: $e'];
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // インジケータを閉じる

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('プッシュ通知の状態'),
        content: SingleChildScrollView(
          child: Text(lines.join('\n\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  /// 設定・カラム・アカウントを .json に書き出す。
  /// トークンを含むので、先に取り扱い注意の警告ダイアログを出す。
  Future<void> _exportBackup() async {
    final accountCount = ref.read(authProvider).accounts.length;

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange),
            SizedBox(width: 8),
            Expanded(child: Text('エクスポートの注意')),
          ],
        ),
        content: Text(
          'このバックアップには全アカウント ($accountCount 件) のアクセストークン '
          '(ログイン情報) が含まれます。\n\n'
          'ファイルが第三者の手に渡るとアカウントを乗っ取られる恐れがあります。'
          '保存先・共有先に十分注意してください。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('続行'),
          ),
        ],
      ),
    );
    if (proceed != true) return;

    try {
      final json = buildBackupJson(ref, exportedAt: DateTime.now());
      final saved = await saveBackupFile(_backupFileName(), json);
      if (!mounted) return;
      if (saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('バックアップを書き出しました')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'エクスポートに失敗しました: $e');
    }
  }

  /// バックアップ .json を読み込んで復元する。現在のデータを上書きする旨を
  /// 確認してから適用する。
  Future<void> _importBackup() async {
    String? raw;
    try {
      raw = await pickBackupFile();
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'ファイルを開けませんでした: $e');
      return;
    }
    if (raw == null) return; // キャンセル

    BackupContent content;
    try {
      content = parseBackupJson(raw);
    } on FormatException catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'インポートできませんでした: ${e.message}');
      return;
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'インポートできませんでした: $e');
      return;
    }

    if (!mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('バックアップを復元'),
        content: Text(
          'このファイルには以下が含まれます:\n'
          '・アカウント ${content.accountCount} 件\n'
          '・カラム ${content.columnCount} 件\n'
          '・設定 ${content.hasSettings ? "あり" : "なし"}\n\n'
          'インポートすると現在のアカウント・カラム・設定は上書きされます。'
          '続行しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('インポート'),
          ),
        ],
      ),
    );
    if (proceed != true) return;

    try {
      await applyBackup(ref, content);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('インポートしました (一部はアプリ再起動後に反映されます)'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, 'インポートに失敗しました: $e');
    }
  }
}
