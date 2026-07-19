// lib/pages/app_lock_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/app_lock_provider.dart';
import '../providers/settings_provider.dart';
import '../services/app_lock_service.dart';

/// 6 桁固定の PIN 入力画面。生体認証が有効な端末では起動時に自動でプロンプト。
class AppLockScreen extends ConsumerStatefulWidget {
  const AppLockScreen({super.key});

  @override
  ConsumerState<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends ConsumerState<AppLockScreen> {
  static const int _pinLength = 6;

  String _entered = '';
  String? _error;
  bool _verifying = false;
  bool _biometricAttempted = false;

  @override
  void initState() {
    super.initState();
    // 初回 build 後に生体認証プロンプトを自動表示
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoBiometric();
    });
    // 物理キーボード (PC / Web / 一部 Android) からの PIN 入力を受け付ける。
    // Focus に依存しない HardwareKeyboard.addHandler を使うことで、画面上の
    // ボタンがフォーカスを奪っても確実に拾える。
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  bool _onHardwareKey(KeyEvent event) {
    // KeyDown と KeyRepeat 両方拾う (Backspace の長押し連続削除を許可)。
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.backspace) {
      _onBackspace();
      return true;
    }
    final ch = event.character;
    if (ch != null && ch.length == 1 && ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39) {
      _onDigit(ch);
      return true;
    }
    return false;
  }

  Future<void> _maybeAutoBiometric() async {
    if (_biometricAttempted) return;
    _biometricAttempted = true;
    final settings = ref.read(settingsProvider);
    if (!settings.appLockBiometric) return;
    final canUse = await AppLockService.instance.canUseBiometrics();
    if (!canUse) return;
    final ok = await AppLockService.instance.authenticateWithBiometrics();
    if (!mounted) return;
    if (ok) {
      ref.read(appLockProvider.notifier).unlock();
    }
  }

  void _onDigit(String digit) {
    if (_verifying) return;
    if (_entered.length >= _pinLength) return;
    setState(() {
      _entered += digit;
      _error = null;
    });
    if (_entered.length == _pinLength) {
      _verify();
    }
  }

  void _onBackspace() {
    if (_verifying) return;
    if (_entered.isEmpty) return;
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
    });
  }

  Future<void> _verify() async {
    setState(() => _verifying = true);
    final ok = await AppLockService.instance.verifyPin(_entered);
    if (!mounted) return;
    if (ok) {
      HapticFeedback.lightImpact();
      ref.read(appLockProvider.notifier).unlock();
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _error = context.l10n.appLockWrongPin;
        _entered = '';
        _verifying = false;
      });
    }
  }

  Future<void> _retryBiometric() async {
    final canUse = await AppLockService.instance.canUseBiometrics();
    if (!canUse) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.appLockBiometricsUnavailable)),
      );
      return;
    }
    final ok = await AppLockService.instance.authenticateWithBiometrics();
    if (!mounted) return;
    if (ok) {
      ref.read(appLockProvider.notifier).unlock();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);

    return PopScope(
      canPop: false, // ロック中は戻る無効
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline,
                      size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(context.l10n.appLockEnterPin,
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 24),
                  _buildDots(theme),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 20,
                    child: _error != null
                        ? Text(_error!,
                            style: TextStyle(
                                color: theme.colorScheme.error, fontSize: 13))
                        : null,
                  ),
                  const SizedBox(height: 16),
                  _buildKeypad(theme, settings),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDots(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(_pinLength, (i) {
        final filled = i < _entered.length;
        return Container(
          width: 16,
          height: 16,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: filled ? theme.colorScheme.primary : Colors.transparent,
            border: Border.all(color: theme.colorScheme.primary, width: 1.5),
          ),
        );
      }),
    );
  }

  Widget _buildKeypad(ThemeData theme, Settings settings) {
    final showBiometric = settings.appLockBiometric;
    return Column(
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: row.map((d) => _digitButton(d)).toList(),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 左下: 生体認証 (有効時のみ)
            SizedBox(
              width: 80,
              height: 80,
              child: showBiometric
                  ? IconButton(
                      iconSize: 28,
                      icon: const Icon(Icons.fingerprint),
                      onPressed: _retryBiometric,
                    )
                  : null,
            ),
            _digitButton('0'),
            // 右下: バックスペース
            SizedBox(
              width: 80,
              height: 80,
              child: IconButton(
                iconSize: 28,
                icon: const Icon(Icons.backspace_outlined),
                onPressed: _entered.isEmpty ? null : _onBackspace,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _digitButton(String digit) {
    return SizedBox(
      width: 80,
      height: 80,
      child: TextButton(
        onPressed: () => _onDigit(digit),
        style: TextButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        child: Text(digit, style: const TextStyle(fontSize: 28)),
      ),
    );
  }
}
