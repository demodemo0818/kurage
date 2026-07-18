// lib/pages/boss_mode/boss_mode_gate.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/boss_mode_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/boss_disguise.dart';
import '../../utils/platform.dart';
import 'google_shell.dart';

/// アプリ最上位 (MaterialApp.builder = Navigator の上) に被せるゲート。
///
/// ボスキー (F9) でトグルされる偽装モードの ON/OFF を見て、ON のときは Google
/// 偽装シェルを全面に出し、裏の本体 (Navigator = 全ルート + 開いている
/// ダイアログ) は Offstage で生存させたまま隠す。これにより偽装解除時に
/// 裏のスクロール位置・SSE・State が一切壊れない ([LockGate] と同じ思想)。
///
/// Web / デスクトップ専用。モバイルでは child を素通しし、ホットキーも登録しない。
class BossModeGate extends ConsumerStatefulWidget {
  final Widget child;
  const BossModeGate({super.key, required this.child});

  @override
  ConsumerState<BossModeGate> createState() => _BossModeGateState();
}

class _BossModeGateState extends ConsumerState<BossModeGate> {
  bool _handlerAdded = false;

  @override
  void initState() {
    super.initState();
    // 対象プラットフォームのみグローバルホットキーを拾う。Focus 非依存に
    // するため HardwareKeyboard を使う (テキスト入力中でも F9 が効く)。
    if (isWebOrDesktop()) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _handlerAdded = true;
    }
  }

  @override
  void dispose() {
    if (_handlerAdded) {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    // 画面破棄時に偽装が残らないよう復元 (Web のタブ title/favicon)。
    restoreDisguise();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != bossKeyTrigger) return false;
    // 機能 OFF のときはキーを消費しない (ブラウザ/OS 既定動作に委ねる)。
    if (!ref.read(settingsProvider).bossKeyEnabled) return false;
    ref.read(bossModeProvider.notifier).toggle();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (!isWebOrDesktop()) return widget.child;

    final showBoss = ref.watch(bossModeProvider);

    // title/favicon の差し替えは副作用なので build 中の直呼びを避け listen で。
    ref.listen<bool>(bossModeProvider, (prev, next) {
      if (next) {
        applyDisguise();
      } else {
        restoreDisguise();
      }
    });

    return Stack(
      children: [
        Offstage(
          offstage: showBoss,
          // 裏の Focus (RootPage の autofocus 等) が偽装シェルの入力欄から
          // フォーカスを奪わないよう除外する。
          child: ExcludeFocus(
            excluding: showBoss,
            child: TickerMode(enabled: !showBoss, child: widget.child),
          ),
        ),
        // GoogleShell は MaterialApp.builder 上 (= Navigator より上) に出るため、
        // Overlay / Navigator 祖先が無い。TextField の選択レイヤーや Tooltip に
        // 加え、公開範囲の PopupMenuButton (内部で Navigator.push を使う) や
        // 将来のダイアログ/ボトムシートも動くよう、専用の Navigator を 1 枚
        // 噛ませる (Navigator は Overlay も内包する)。
        //
        // 偽装は F9 で瞬時に出し入れしたいので、初期ルートはトランジション
        // 無し (Duration.zero) にする。単一ルート + GoogleShell 側の
        // PopScope(canPop:false) なので戻るで誤って抜けることはない。
        if (showBoss)
          Positioned.fill(
            // この Navigator を素で置くと、MaterialApp が用意した HeroController を
            // 本体の root Navigator と共有してしまい "A HeroController can not be
            // shared by multiple Navigators" の assert が出て root Navigator が
            // `_debugLocked` の壊れた状態に陥る。すると偽装解除後に showDialog /
            // showMenu (カラムの ⋮ メニュー / 投稿ペインのアカウント選択 /
            // 画像ビューア) が push できず黙って壊れる (F5 リロードでしか直らない)。
            // GoogleShell は Hero 遷移を使わないので HeroControllerScope.none で
            // 「HeroController を持たない」専用スコープを与え、共有を断ち切る。
            child: HeroControllerScope.none(
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                  pageBuilder: (_, _, _) => const GoogleShell(),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
