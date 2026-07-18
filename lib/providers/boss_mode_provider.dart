// lib/providers/boss_mode_provider.dart

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_provider.dart';
import '../utils/platform.dart';

/// ボスキー (偽装モード) のトリガキー。
///
/// タイプ中でも反応させたいので文字キーは避ける (検索/投稿欄に文字が混入する)。
/// 機能キー F9 を既定にする。後から設定化しやすいよう定数で定義。
/// ※ macOS は F1〜F12 が既定でメディアキー扱いの場合があり、その時はユーザーが
///   Fn+F9 を押す必要がある (OS がメディアキーに変換すると Flutter にキーが
///   届かないため回避不能)。
const LogicalKeyboardKey bossKeyTrigger = LogicalKeyboardKey.f9;

/// 偽装モードが今 ON か (永続化しない・起動毎に false)。
///
/// `Settings.bossKeyEnabled` が「機能の有効/無効」を持つのに対し、こちらは
/// 「いま Google 偽装を表示しているか」だけを持つ純粋な runtime state。
/// 設計は [appLockProvider] と同型。
class BossModeNotifier extends StateNotifier<bool> {
  final Ref ref;

  BossModeNotifier(this.ref) : super(false) {
    // 機能が OFF にされたら偽装も解除する。
    ref.listen<Settings>(settingsProvider, (prev, next) {
      if (!next.bossKeyEnabled && state) {
        state = false;
      }
    });
  }

  /// 表示↔解除のトグル。対象プラットフォーム & 機能 ON のときだけ反応。
  void toggle() {
    if (!isWebOrDesktop()) return;
    if (!ref.read(settingsProvider).bossKeyEnabled) return;
    state = !state;
  }

  void activate() {
    if (!isWebOrDesktop()) return;
    if (!ref.read(settingsProvider).bossKeyEnabled) return;
    state = true;
  }

  /// 解除はガード不要 (常に通常表示へ戻せるように)。
  void deactivate() {
    if (state) state = false;
  }
}

final bossModeProvider =
    StateNotifierProvider<BossModeNotifier, bool>((ref) {
  return BossModeNotifier(ref);
});
