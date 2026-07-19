// lib/pages/app_settings_page.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import '../l10n/l10n.dart';
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
        title: Text(context.l10n.appSettingsTitle),
      ),
      body: SettingsListView(
        children: [
          // ========== リアクション確認 ==========
          SettingsSection(
            title: context.l10n.appSettingsSectionConfirmations,
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.repeat, color: Colors.green),
                title: Text(context.l10n.appSettingsConfirmReblogTitle),
                subtitle: Text(context.l10n.appSettingsConfirmReblogSubtitle),
                value: settings.confirmReblog,
                onChanged: (value) =>
                    settingsNotifier.setConfirmReblog(value),
              ),
              SwitchListTile(
                secondary:
                    const Icon(Icons.repeat_on_outlined, color: Colors.green),
                title: Text(context.l10n.appSettingsConfirmUnreblogTitle),
                subtitle: Text(context.l10n.appSettingsConfirmUnreblogSubtitle),
                value: settings.confirmUnreblog,
                onChanged: (value) =>
                    settingsNotifier.setConfirmUnreblog(value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.star, color: Colors.amber),
                title: Text(context.l10n.appSettingsConfirmFavouriteTitle),
                subtitle:
                    Text(context.l10n.appSettingsConfirmFavouriteSubtitle),
                value: settings.confirmFavourite,
                onChanged: (value) =>
                    settingsNotifier.setConfirmFavourite(value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.star_border, color: Colors.amber),
                title: Text(context.l10n.appSettingsConfirmUnfavouriteTitle),
                subtitle:
                    Text(context.l10n.appSettingsConfirmUnfavouriteSubtitle),
                value: settings.confirmUnfavourite,
                onChanged: (value) =>
                    settingsNotifier.setConfirmUnfavourite(value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.bookmark, color: Colors.indigo),
                title: Text(context.l10n.appSettingsConfirmBookmarkTitle),
                subtitle: Text(context.l10n.appSettingsConfirmBookmarkSubtitle),
                value: settings.confirmBookmark,
                onChanged: (value) =>
                    settingsNotifier.setConfirmBookmark(value),
              ),
              SwitchListTile(
                secondary:
                    const Icon(Icons.bookmark_border, color: Colors.indigo),
                title: Text(context.l10n.appSettingsConfirmUnbookmarkTitle),
                subtitle:
                    Text(context.l10n.appSettingsConfirmUnbookmarkSubtitle),
                value: settings.confirmUnbookmark,
                onChanged: (value) =>
                    settingsNotifier.setConfirmUnbookmark(value),
              ),
            ],
          ),

          // ========== その他 ==========
          SettingsSection(
            title: context.l10n.appSettingsSectionOther,
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.exit_to_app, color: Colors.red),
                title: Text(context.l10n.appSettingsConfirmAppExitTitle),
                subtitle: Text(context.l10n.appSettingsConfirmAppExitSubtitle),
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
                  title: Text(context.l10n.appSettingsKeepScreenOnTitle),
                  subtitle:
                      Text(context.l10n.appSettingsKeepScreenOnSubtitle),
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
              title: context.l10n.appSettingsSectionImageSave,
              children: [
                ListTile(
                  leading:
                      const Icon(Icons.folder_outlined, color: Colors.amber),
                  title: Text(context.l10n.appSettingsImageSaveDirTitle),
                  subtitle: Text(
                    settings.confirmImageSaveLocation
                        ? context.l10n.appSettingsImageSaveDirIgnored
                        : ((settings.imageSaveDirectory?.isNotEmpty ?? false)
                            ? settings.imageSaveDirectory!
                            : context.l10n.appSettingsImageSaveDirDefault),
                  ),
                  trailing: (settings.imageSaveDirectory?.isNotEmpty ?? false)
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          tooltip:
                              context.l10n.appSettingsImageSaveDirResetTooltip,
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
                  title: Text(context.l10n.appSettingsConfirmImageSaveTitle),
                  subtitle:
                      Text(context.l10n.appSettingsConfirmImageSaveSubtitle),
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
            title: context.l10n.appSettingsSectionSound,
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active,
                    color: Colors.orange),
                title: Text(context.l10n.appSettingsSoundNotificationTitle),
                subtitle:
                    Text(context.l10n.appSettingsSoundNotificationSubtitle),
                value: settings.soundOnNotification,
                onChanged: (value) =>
                    settingsNotifier.setSoundOnNotification(value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.send, color: Colors.blue),
                title: Text(context.l10n.appSettingsSoundPostTitle),
                subtitle: Text(context.l10n.appSettingsSoundPostSubtitle),
                value: settings.soundOnPost,
                onChanged: (value) => settingsNotifier.setSoundOnPost(value),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.refresh, color: Colors.teal),
                title: Text(context.l10n.appSettingsSoundRefreshTitle),
                subtitle: Text(context.l10n.appSettingsSoundRefreshSubtitle),
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
              title: context.l10n.appSettingsSectionBossKey,
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.search, color: Colors.blue),
                  title: Text(context.l10n.appSettingsBossKeyTitle),
                  subtitle: Text(context.l10n.appSettingsBossKeySubtitle),
                  value: settings.bossKeyEnabled,
                  onChanged: (value) =>
                      settingsNotifier.setBossKeyEnabled(value),
                ),
              ],
            ),

          // ========== バックアップ ==========
          SettingsSection(
            title: context.l10n.appSettingsSectionBackup,
            children: [
              ListTile(
                leading: const Icon(Icons.upload_file, color: Colors.blue),
                title: Text(context.l10n.appSettingsExportTitle),
                subtitle: Text(context.l10n.appSettingsExportSubtitle),
                trailing: const Icon(Icons.chevron_right),
                onTap: _exportBackup,
              ),
              ListTile(
                leading: const Icon(Icons.download, color: Colors.green),
                title: Text(context.l10n.appSettingsImportTitle),
                subtitle: Text(context.l10n.appSettingsImportSubtitle),
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
              title: context.l10n.appSettingsSectionNotifications,
              children: [
                SwitchListTile(
                  secondary: const Icon(
                      Icons.notifications_active_outlined,
                      color: Colors.teal),
                  title: Text(context.l10n.appSettingsPushTitle),
                  subtitle: Text(context.l10n.appSettingsPushSubtitle),
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
                  title: Text(context.l10n.appSettingsPushDiagTitle),
                  subtitle: Text(context.l10n.appSettingsPushDiagSubtitle),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _runPushDiagnostics,
                ),
              ],
            ),

          SettingsSection(
            title: context.l10n.appSettingsSectionPrivacy,
            children: [
              SwitchListTile(
                secondary:
                    const Icon(Icons.bug_report_outlined, color: Colors.teal),
                title: Text(context.l10n.appSettingsCrashReportTitle),
                subtitle: Text(context.l10n.appSettingsCrashReportSubtitle),
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
                title: Text(context.l10n.appSettingsAnalyticsTitle),
                subtitle: Text(context.l10n.appSettingsAnalyticsSubtitle),
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
      builder: (ctx) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(context.l10n.appSettingsPushChecking)),
          ],
        ),
      ),
    );

    List<String> lines;
    try {
      lines = await PushNotificationService().runDiagnostics();
    } catch (e) {
      lines = [l10n.appSettingsPushDiagFailed('$e')];
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // インジケータを閉じる

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.appSettingsPushStatusTitle),
        content: SingleChildScrollView(
          child: Text(lines.join('\n\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.l10n.close),
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
        title: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.orange),
            const SizedBox(width: 8),
            Expanded(child: Text(ctx.l10n.appSettingsExportWarnTitle)),
          ],
        ),
        content: Text(ctx.l10n.appSettingsExportWarnBody(accountCount)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.appSettingsContinue),
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
          SnackBar(content: Text(context.l10n.appSettingsExportDone)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, context.l10n.appSettingsExportFailed('$e'));
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
      showErrorSnackBar(context, context.l10n.appSettingsFileOpenFailed('$e'));
      return;
    }
    if (raw == null) return; // キャンセル

    BackupContent content;
    try {
      content = parseBackupJson(raw);
    } on FormatException catch (e) {
      if (!mounted) return;
      showErrorSnackBar(
          context, context.l10n.appSettingsImportParseFailed(e.message));
      return;
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(
          context, context.l10n.appSettingsImportParseFailed('$e'));
      return;
    }

    if (!mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.appSettingsImportConfirmTitle),
        content: Text(
          ctx.l10n.appSettingsImportConfirmBody(
            content.accountCount,
            content.columnCount,
            content.hasSettings
                ? ctx.l10n.appSettingsImportHasSettingsYes
                : ctx.l10n.appSettingsImportHasSettingsNo,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.appSettingsImportAction),
          ),
        ],
      ),
    );
    if (proceed != true) return;

    try {
      await applyBackup(ref, content);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.appSettingsImportDone),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, context.l10n.appSettingsImportFailed('$e'));
    }
  }
}
