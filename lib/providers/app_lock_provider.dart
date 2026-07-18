// lib/providers/app_lock_provider.dart

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_provider.dart';

/// アプリロックの実行時状態 (永続化されない、起動毎にリセット)。
///
/// `Settings` 側の `appLockEnabled` 等が「機能の有効/無効や設定値」を持つのに対し、
/// こちらは「いま現在ロックされているか」「いつバックグラウンドに行ったか」だけを
/// 保持する純粋な runtime state。
@immutable
class AppLockState {
  /// 今ロックされているか
  final bool locked;

  /// 直近で `paused` (バックグラウンド) に入った時刻。
  /// `resumed` 時の経過判定に使う。
  final DateTime? lastPausedAt;

  const AppLockState({required this.locked, this.lastPausedAt});

  AppLockState copyWith(
      {bool? locked, DateTime? lastPausedAt, bool clearPaused = false}) {
    return AppLockState(
      locked: locked ?? this.locked,
      lastPausedAt: clearPaused ? null : (lastPausedAt ?? this.lastPausedAt),
    );
  }
}

class AppLockNotifier extends StateNotifier<AppLockState> {
  final Ref ref;

  AppLockNotifier(this.ref) : super(const AppLockState(locked: false)) {
    // 起動時のロック判定は main() 側で AppLockService.shouldStartLocked()
    // を呼び、必要なら直後に lock() を呼ぶ仕組み。ここで listen しても
    // SettingsNotifier._load() の非同期完了と「ユーザーが今 ON にした」操作を
    // 区別できないため、ここでは初期化の責務を持たない。
    //
    // 機能 OFF にされた時の解除だけはここで監視する。
    ref.listen<Settings>(settingsProvider, (prev, next) {
      if (!next.appLockEnabled && state.locked) {
        state = state.copyWith(locked: false);
      }
    });
  }

  /// 認証成功時に呼ぶ
  void unlock() {
    state = state.copyWith(locked: false, clearPaused: true);
  }

  /// 強制ロック (テスト用 / "今すぐロック" メニュー等)
  void lock() {
    state = state.copyWith(locked: true);
  }

  /// `AppLifecycleState.paused` / `hidden` 時に呼ぶ
  void onAppPaused() {
    final settings = ref.read(settingsProvider);
    if (!settings.appLockEnabled) return;
    if (state.locked) return; // 既にロック済みなら lastPausedAt は変えない
    // hidden は「背景へ行くとき」だけでなく「復帰するとき」(paused → hidden →
    // inactive → resumed) にも通過する。復帰経路の hidden で上書きすると
    // onAppResumed の経過時間が常にほぼ 0 秒になり、タイムアウト指定時に
    // 一切ロックされなくなる。最初に記録した時刻を保持する (onAppResumed が
    // clearPaused で消すので次のサイクルはまた記録される)。
    if (state.lastPausedAt != null) return;
    state = state.copyWith(lastPausedAt: DateTime.now());
  }

  /// `AppLifecycleState.resumed` 時に呼ぶ。経過秒が timeout 以上なら再ロック。
  void onAppResumed() {
    final settings = ref.read(settingsProvider);
    if (!settings.appLockEnabled) return;
    if (state.locked) return;

    final pausedAt = state.lastPausedAt;
    if (pausedAt == null) return;

    final elapsed = DateTime.now().difference(pausedAt).inSeconds;
    // elapsed が負 = バックグラウンド中に端末時計が巻き戻された (手動変更や
    // NTP 同期)。タイムアウト判定をすり抜けてロック回避できてしまうので、
    // 安全側に倒して即ロックする。
    if (elapsed < 0 || elapsed >= settings.appLockTimeoutSeconds) {
      state = state.copyWith(locked: true);
    }
    // 復帰したので pause 時刻はクリア (次の paused でまた記録される)
    state = state.copyWith(clearPaused: true);
  }
}

final appLockProvider =
    StateNotifierProvider<AppLockNotifier, AppLockState>((ref) {
  return AppLockNotifier(ref);
});
