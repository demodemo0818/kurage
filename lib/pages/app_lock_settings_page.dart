// lib/pages/app_lock_settings_page.dart

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
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
        title: Text(ctx.l10n.appLockDisableTitle),
        content: Text(ctx.l10n.appLockDisableMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.appLockDisableAction),
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
        title: Text(context.l10n.appLockTimeoutTitle),
        children: [
          for (final entry in _timeoutOptions(context.l10n).entries)
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

  static Map<int, String> _timeoutOptions(AppLocalizations l10n) => {
        0: l10n.appLockImmediately,
        30: l10n.durationSeconds(30),
        60: l10n.durationMinutes(1),
        300: l10n.durationMinutes(5),
        900: l10n.durationMinutes(15),
        1800: l10n.durationMinutes(30),
      };

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.appLockTitle)),
      body: SettingsListView(
        children: [
          SettingsSection(
            children: [
              SwitchListTile(
                secondary:
                    Icon(Icons.lock_outline, color: Colors.red.shade400),
                title: Text(context.l10n.appLockEnableTitle),
                subtitle: Text(context.l10n.appLockEnableSubtitle),
                value: settings.appLockEnabled,
                onChanged: _onToggleEnabled,
              ),
            ],
          ),
          if (settings.appLockEnabled)
            SettingsSection(
              title: context.l10n.appLockSettingsSection,
              children: [
                ListTile(
                  leading: const Icon(Icons.pin, color: Colors.indigo),
                  title: Text(context.l10n.appLockChangePin),
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
                  title: Text(context.l10n.appLockUseBiometrics),
                  subtitle: Text(
                    _biometricSupported == false
                        ? (kIsWeb
                            ? context.l10n.appLockBiometricsWebUnavailable
                            : context.l10n.appLockBiometricsDeviceUnavailable)
                        : context.l10n.appLockBiometricsSubtitle,
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
                  title: Text(context.l10n.appLockTimeoutTitle),
                  subtitle: Text(_timeoutOptions(context.l10n)[
                          settings.appLockTimeoutSeconds] ??
                      context.l10n.durationMinutes(1)),
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
