// lib/pages/app_lock_settings_page.dart

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_provider.dart';
import '../services/app_lock_service.dart';
import '../widgets/settings_section.dart';
import 'app_lock_setup_page.dart';

class AppLockSettingsPage extends ConsumerStatefulWidget {
  const AppLockSettingsPage({super.key});

  @override
  ConsumerState<AppLockSettingsPage> createState() =>
      _AppLockSettingsPageState();
}

class _AppLockSettingsPageState extends ConsumerState<AppLockSettingsPage> {
  bool? _biometricSupported;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    final ok = await AppLockService.instance.canUseBiometrics();
    if (mounted) setState(() => _biometricSupported = ok);
  }

  Future<void> _onToggleEnabled(bool v) async {
    final notifier = ref.read(settingsProvider.notifier);
    if (v) {
      // 有効化 → PIN 未設定なら設定画面に飛ばす
      final hasPin = await AppLockService.instance.hasPin();
      if (!hasPin) {
        if (!mounted) return;
        final ok = await Navigator.push<bool>(
          context,
          MaterialPageRoute(builder: (_) => const AppLockSetupPage()),
        );
        if (ok != true) return; // PIN 設定キャンセル時は有効化しない
      }
      await notifier.setAppLockEnabled(true);
    } else {
      // 無効化 → 確認後 PIN も削除
      final confirmed = await _confirmDisable();
      if (confirmed != true) return;
      await notifier.setAppLockEnabled(false);
      await AppLockService.instance.clearPin();
    }
  }

  Future<bool?> _confirmDisable() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('アプリロックを無効化'),
        content: const Text('PIN も削除されます。よろしいですか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('無効化'),
          ),
        ],
      ),
    );
  }

  Future<void> _changePin() async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AppLockSetupPage()),
    );
  }

  Future<void> _showTimeoutPicker() async {
    final settings = ref.read(settingsProvider);
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('自動ロックまでの時間'),
        children: [
          for (final entry in _timeoutOptions.entries)
            RadioListTile<int>(
              title: Text(entry.value),
              value: entry.key,
              // ignore: deprecated_member_use
              groupValue: settings.appLockTimeoutSeconds,
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.pop(context, v),
            ),
        ],
      ),
    );
    if (selected != null && selected != settings.appLockTimeoutSeconds) {
      await ref
          .read(settingsProvider.notifier)
          .setAppLockTimeoutSeconds(selected);
    }
  }

  static const Map<int, String> _timeoutOptions = {
    0: '即時',
    30: '30 秒',
    60: '1 分',
    300: '5 分',
    900: '15 分',
    1800: '30 分',
  };

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('アプリロック')),
      body: SettingsListView(
        children: [
          SettingsSection(
            children: [
              SwitchListTile(
                secondary:
                    Icon(Icons.lock_outline, color: Colors.red.shade400),
                title: const Text('アプリロックを有効にする'),
                subtitle: const Text(
                    '起動時とバックグラウンド復帰時に PIN / 生体認証を要求します'),
                value: settings.appLockEnabled,
                onChanged: _onToggleEnabled,
              ),
            ],
          ),
          if (settings.appLockEnabled)
            SettingsSection(
              title: 'ロック設定',
              children: [
                ListTile(
                  leading: const Icon(Icons.pin, color: Colors.indigo),
                  title: const Text('PIN を変更'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _changePin,
                ),
                SwitchListTile(
                  secondary: Icon(
                    Icons.fingerprint,
                    color: _biometricSupported == false
                        ? Colors.grey
                        : Colors.teal,
                  ),
                  title: const Text('生体認証を使う'),
                  subtitle: Text(
                    _biometricSupported == false
                        ? (kIsWeb
                            ? 'Web 版では生体認証は使えません (PIN のみ)'
                            : 'この端末では生体認証が利用できません')
                        : '指紋 / 顔認証で解除できるようにします',
                  ),
                  value: settings.appLockBiometric &&
                      _biometricSupported != false,
                  onChanged: _biometricSupported == false
                      ? null
                      : notifier.setAppLockBiometric,
                ),
                ListTile(
                  leading:
                      const Icon(Icons.schedule, color: Colors.orange),
                  title: const Text('自動ロックまでの時間'),
                  subtitle: Text(
                      _timeoutOptions[settings.appLockTimeoutSeconds] ??
                          '1 分'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showTimeoutPicker,
                ),
              ],
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
