// lib/services/stale_modifier_key_guard.dart

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// Windows で Shift / Ctrl が「押しっぱなし」扱いのまま残る Flutter 本体の
/// 不具合 (flutter/flutter#181907、未修正) の回避策。
///
/// 症状: `Scrollable` は Shift 押下中にマウスホイールの軸を反転するため、
/// 縦ホイールがどこで回しても横スクロール (Deck の横移動) になり、カラムが
/// 縦に動かなくなる。TextField のクリックが範囲選択になる、Tab のフォーカス
/// 移動が逆向きになる、も同じ原因。再起動するまで直らない (issue #7)。
///
/// 原因: IME 使用中などに Windows が Shift の extended フラグを誤って報告すると、
/// エンジンはスキャンコードを標準の物理キー (ShiftLeft / ShiftRight) に対応
/// 付けられず、Windows プレーンの非標準の物理キー (例: `0x1600000036`) として
/// KeyDown を送る。対になる KeyUp が同じ物理キーで届かないと、HardwareKeyboard
/// に Shift が残り続ける。エンジンはマウス移動 (WM_MOUSEMOVE の MK_SHIFT /
/// MK_CONTROL) のたびに修飾キーを OS の実状態へ同期しているが、同期対象は
/// **標準の物理キーだけ** なので、非標準の物理キーに残った押下状態は永久に
/// 解除されない。
///
/// 対処: マウス移動のポインタイベントが届いた時点では、エンジンが直前に標準の
/// 物理キーを OS の実状態へ同期済み (同期のキーイベントはポインタイベントより
/// 先に送られる)。そこで「標準の物理キーはどちらも離されている (= OS 上は押されて
/// いない) のに、非標準の物理キーが同じ修飾キーとして押下中」になっているものを
/// 取り残しとみなし、合成の KeyUpEvent で解除する。本当に押している間は
/// エンジンが標準の物理キーを押下状態に同期するので、誤って解除することはない。
class StaleModifierKeyGuard {
  StaleModifierKeyGuard._();

  static bool _installed = false;

  /// エンジンがマウス移動時に OS と同期する修飾キー (Shift / Ctrl)。
  static final List<_SyncedModifier> _syncedModifiers = [
    _SyncedModifier(
      {PhysicalKeyboardKey.shiftLeft, PhysicalKeyboardKey.shiftRight},
      {LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight},
    ),
    _SyncedModifier(
      {PhysicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlRight},
      {LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight},
    ),
  ];

  /// マウス移動の監視を始める。Windows 以外では何もしない (前提にしている
  /// 「マウス移動時の修飾キー同期」は Windows エンジンの実装)。
  static void install() {
    if (_installed ||
        kIsWeb ||
        defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }
    _installed = true;
    // グローバルルートは hit test の結果に関わらず全ポインタイベントで呼ばれる。
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerEvent);
  }

  static void _onPointerEvent(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    // エンジンが修飾キーを同期するのは WM_MOUSEMOVE (= hover / ボタン押下中の
    // move) だけ。ホイールやクリックでは同期されないので判定の前提が崩れる。
    if (event is! PointerHoverEvent && event is! PointerMoveEvent) return;
    releaseStaleModifiers(event.timeStamp);
  }

  /// 取り残された修飾キーを合成の KeyUpEvent で解除する。
  /// 解除したキーがあれば true。
  @visibleForTesting
  static bool releaseStaleModifiers(Duration timeStamp) {
    final keyboard = HardwareKeyboard.instance;
    final pressed = keyboard.physicalKeysPressed;
    var released = false;
    for (final modifier in _syncedModifiers) {
      // 標準の物理キーが押下中なら OS 上も押されている。本当に押している
      // 最中なので触らない。
      if (pressed.any(modifier.physical.contains)) continue;
      for (final physicalKey in pressed) {
        final logicalKey = keyboard.lookUpLayout(physicalKey);
        if (logicalKey == null || !modifier.logical.contains(logicalKey)) {
          continue;
        }
        debugPrint(
          'StaleModifierKeyGuard: 取り残された修飾キーを解除 $physicalKey → $logicalKey',
        );
        keyboard.handleKeyEvent(
          KeyUpEvent(
            physicalKey: physicalKey,
            logicalKey: logicalKey,
            timeStamp: timeStamp,
            synthesized: true,
          ),
        );
        released = true;
      }
    }
    return released;
  }
}

/// エンジンが同期する修飾キー 1 種の、標準の物理キーとそれが取りうる論理キー。
class _SyncedModifier {
  const _SyncedModifier(this.physical, this.logical);

  final Set<PhysicalKeyboardKey> physical;
  final Set<LogicalKeyboardKey> logical;
}
