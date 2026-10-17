// lib/widgets/ime_composition_tab_guard.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Web で IME 変換中に押した Tab を、フレームワークのフォーカス移動に
/// 回さないためのガード。
///
/// 症状: Mac の日本語入力で変換中に Tab (予測候補の表示) → Enter (候補の確定)
/// と打つと、入力途中なのに投稿されてしまう。
///
/// 原因: ブラウザは変換中の Tab でも keydown (isComposing = true) を送る。
/// Flutter Web エンジンは旧 RawKeyboard 経路ではこれを捨てているが、KeyEvent
/// 経路ではそのままフレームワークに渡すため、`WidgetsApp` 既定の Tab →
/// `NextFocusIntent` でフォーカスが TextField から次の widget (投稿画面では
/// 投稿ボタン) に移る。続く確定の Enter は IME が消費するものの、フレームワーク
/// 側では今度はボタンにフォーカスがあるので Enter → `ActivateIntent` が発火し、
/// ボタンが押されたことになる。
///
/// 対処: フォーカス中の TextField が変換中 (composing が空でない) の Tab は
/// `skipRemainingHandlers` で祖先の Shortcuts に届く前に止める。未処理扱いなので
/// エンジンは preventDefault せず、ブラウザ / IME には従来どおり Tab が届く。
/// `WidgetsApp` の Shortcuts より内側 (`MaterialApp.builder`) に置く必要がある。
class ImeCompositionTabGuard extends StatelessWidget {
  const ImeCompositionTabGuard({
    super.key,
    required this.child,
    this.enabled = kIsWeb,
  });

  final Widget child;

  /// ネイティブ (デスクトップ / モバイル) は変換中のキーを IME が先に消費する
  /// ので不要。テストから有効化できるよう引数にしてある。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKeyEvent,
      child: child,
    );
  }

  static KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    final editable =
        focusedContext?.findAncestorStateOfType<EditableTextState>();
    final composing = editable?.textEditingValue.composing;
    if (composing == null || !composing.isValid || composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.skipRemainingHandlers;
  }
}
