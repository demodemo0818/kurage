// lib/pages/settings_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../l10n/l10n.dart';
import '../widgets/settings_section.dart';
import 'column_settings_page.dart';
import 'appearance_page.dart';
import 'account_settings_page.dart';
import 'app_settings_page.dart';
import 'app_lock_settings_page.dart';
import 'scheduled_posts_page.dart';
import 'list_management_page.dart';
import 'filters_page.dart';
import 'blocked_muted_page.dart';
import 'credits_page.dart';

/// 設定メニュー画面 (Android「設定」アプリ風レイアウト)
class SettingsPage extends StatelessWidget {
  /// Deck (ワイド) のポップアップで開かれた時に渡される戻る (←) コールバック。
  /// null (ナロー/通常) のときは AppBar に戻る矢印を出さない。
  final VoidCallback? onDeckBack;

  const SettingsPage({super.key, this.onDeckBack});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: onDeckBack == null ? null : BackButton(onPressed: onDeckBack),
        title: Text(context.l10n.navSettings),
      ),
      body: SettingsListView(
        children: [
          SettingsSection(
            title: context.l10n.settingsAccountContentSection,
            children: [
              _navTile(
                context,
                icon: Icons.account_circle,
                color: Colors.blue,
                title: context.l10n.settingsAccountSettings,
                builder: (_) => const AccountSettingsPage(),
              ),
              _navTile(
                context,
                icon: Icons.view_column,
                color: Colors.teal,
                title: context.l10n.settingsColumnSettings,
                builder: (_) => const ColumnSettingsPage(),
              ),
              _navTile(
                context,
                icon: Icons.list,
                color: Colors.green,
                title: context.l10n.settingsListManagement,
                builder: (_) => const ListManagementPage(),
              ),
              _navTile(
                context,
                icon: Icons.filter_alt_outlined,
                color: Colors.deepOrange,
                title: context.l10n.filtersTitle,
                builder: (_) => const FiltersPage(),
              ),
              _navTile(
                context,
                icon: Icons.block,
                color: Colors.redAccent,
                title: context.l10n.settingsBlockedMuted,
                builder: (_) => const BlockedMutedPage(),
              ),
              _navTile(
                context,
                icon: Icons.schedule,
                color: Colors.orange,
                title: context.l10n.settingsScheduledPosts,
                builder: (_) => const ScheduledPostsPage(),
              ),
            ],
          ),
          SettingsSection(
            title: context.l10n.settingsAppSection,
            children: [
              _navTile(
                context,
                icon: Icons.palette,
                color: Colors.purple,
                title: context.l10n.settingsAppearance,
                builder: (_) => const AppearanceSettingsPage(),
              ),
              _navTile(
                context,
                icon: Icons.settings_applications,
                color: Colors.blueGrey,
                title: context.l10n.settingsAppSettings,
                builder: (_) => const AppSettingsPage(),
              ),
              _navTile(
                context,
                icon: Icons.lock_outline,
                color: Colors.red.shade400,
                title: context.l10n.appLockTitle,
                builder: (_) => const AppLockSettingsPage(),
              ),
            ],
          ),
          SettingsSection(
            title: context.l10n.settingsAppInfoSection,
            children: [
              const _VersionTile(),
              _navTile(
                context,
                icon: Icons.description_outlined,
                color: Colors.brown,
                title: context.l10n.creditsTitle,
                builder: (_) => const CreditsPage(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 別ページへのナビゲーション用 `ListTile`。Android 設定アプリと同じく
  /// 末尾に chevron (`>`) を出して「タップで遷移」を示す。
  Widget _navTile(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required WidgetBuilder builder,
  }) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: builder),
      ),
    );
  }
}

/// バージョン情報行。`package_info_plus` で取得した version + build を表示し、
/// タップでクリップボードにコピーする。テスターが不具合報告のときに
/// バージョンを添えやすくするためのもの。
class _VersionTile extends StatefulWidget {
  const _VersionTile();

  @override
  State<_VersionTile> createState() => _VersionTileState();
}

class _VersionTileState extends State<_VersionTile> {
  String _versionLabel = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _versionLabel = '${info.version}+${info.buildNumber}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _versionLabel = l10n.unknown);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loading = _versionLabel.isEmpty;
    return ListTile(
      leading: const Icon(Icons.info_outline, color: Colors.grey),
      title: Text(context.l10n.settingsVersion),
      subtitle: Text(
          loading ? context.l10n.settingsVersionLoading : 'Kurage $_versionLabel'),
      trailing: const Icon(Icons.content_copy, size: 20),
      onTap: loading
          ? null
          : () async {
              await Clipboard.setData(
                ClipboardData(text: 'Kurage $_versionLabel'),
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(context.l10n.versionCopied),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
    );
  }
}
