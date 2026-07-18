// lib/pages/credits_page.dart

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/snackbar_helpers.dart';
import '../widgets/settings_section.dart';

/// ライセンス・クレジット画面。
///
/// - サードパーティ素材のクレジット表記 (効果音: OtoLogic / CC BY 4.0)。
///   OtoLogic は CC BY 4.0 のため作品にクレジット表記が必須。
/// - Flutter 標準の OSS ライセンス一覧 (`showLicensePage`) への導線。
///   使用ライブラリのライセンスと、main.dart で登録した OtoLogic の
///   ライセンスもここに含まれる。
class CreditsPage extends StatelessWidget {
  const CreditsPage({super.key});

  Future<void> _open(BuildContext context, String url) async {
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && context.mounted) {
        showErrorSnackBar(context, 'リンクを開けませんでした');
      }
    } catch (e) {
      if (context.mounted) {
        showErrorSnackBar(context, 'リンクを開けませんでした: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ライセンス・クレジット')),
      body: SettingsListView(
        children: [
          SettingsSection(
            title: '素材クレジット',
            children: [
              ListTile(
                leading: const Icon(Icons.music_note, color: Colors.orange),
                title: const Text('効果音: OtoLogic'),
                subtitle: const Text(
                  '通知・投稿・引っ張って更新の効果音は OtoLogic の素材を'
                  '使用しています。\nCC BY 4.0 / https://otologic.jp',
                ),
                isThreeLine: true,
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _open(context, 'https://otologic.jp'),
              ),
              ListTile(
                leading: const Icon(Icons.copyright, color: Colors.grey),
                title: const Text('CC BY 4.0 ライセンス全文'),
                subtitle: const Text(
                  'https://creativecommons.org/licenses/by/4.0/',
                ),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _open(
                  context,
                  'https://creativecommons.org/licenses/by/4.0/',
                ),
              ),
            ],
          ),
          SettingsSection(
            title: 'オープンソース',
            children: [
              ListTile(
                leading: const Icon(Icons.code, color: Colors.blue),
                title: const Text('オープンソースライセンス'),
                subtitle: const Text(
                  '本アプリが使用しているライブラリ等のライセンス一覧',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final info = await PackageInfo.fromPlatform();
                  if (!context.mounted) return;
                  showLicensePage(
                    context: context,
                    applicationName: 'Kurage',
                    applicationVersion:
                        '${info.version}+${info.buildNumber}',
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
