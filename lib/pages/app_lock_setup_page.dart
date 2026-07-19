// lib/pages/app_lock_setup_page.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../services/app_lock_service.dart';

/// PIN を 2 回入力させて登録する画面。完了時 true で pop。
class AppLockSetupPage extends StatefulWidget {
  const AppLockSetupPage({super.key});

  @override
  State<AppLockSetupPage> createState() => _AppLockSetupPageState();
}

enum _Phase { firstEntry, confirmEntry }

class _AppLockSetupPageState extends State<AppLockSetupPage> {
  static const int _pinLength = 6;

  _Phase _phase = _Phase.firstEntry;
  String _firstPin = '';
  String _entered = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    // 物理キーボード対応 (詳細は AppLockScreen の同等実装を参照)。
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    super.dispose();
  }

  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
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

  void _onDigit(String d) {
    if (_entered.length >= _pinLength) return;
    setState(() {
      _entered += d;
      _error = null;
    });
    if (_entered.length == _pinLength) {
      _onComplete();
    }
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _onComplete() async {
    if (_phase == _Phase.firstEntry) {
      setState(() {
        _firstPin = _entered;
        _entered = '';
        _phase = _Phase.confirmEntry;
      });
      return;
    }
    // confirm
    if (_entered != _firstPin) {
      HapticFeedback.heavyImpact();
      setState(() {
        _error = context.l10n.appLockPinMismatch;
        _entered = '';
        _firstPin = '';
        _phase = _Phase.firstEntry;
      });
      return;
    }
    await AppLockService.instance.setPin(_firstPin);
    HapticFeedback.lightImpact();
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _phase == _Phase.firstEntry
        ? context.l10n.appLockEnterNewPin
        : context.l10n.appLockConfirmPin;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.appLockPinSetupTitle)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline,
                    size: 56, color: theme.colorScheme.primary),
                const SizedBox(height: 16),
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(context.l10n.appLockPinSixDigits,
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
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
                _buildKeypad(),
              ],
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

  Widget _buildKeypad() {
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
            const SizedBox(width: 80, height: 80),
            _digitButton('0'),
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
