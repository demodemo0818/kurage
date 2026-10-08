// lib/providers/timeline_split_provider.dart

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// タイムライン分割表示 (上 = ライブ / 下 = 履歴ペイン) 中の
/// `ColumnTimelineView` の key 集合。
///
/// 分割状態の真実のソースは各 `ColumnTimelineViewState` (履歴ペインの
/// スナップショットを持つ) で、これはカラムヘッダー / モバイル AppBar の
/// 分割ボタンの表示 (ON/OFF) を切り替えるためのミラー。key は main_page の
/// `GlobalKey<ColumnTimelineViewState>` (identity 比較)。分割は永続化しない
/// (起動毎に解除状態から始まる)。
class TimelineSplitNotifier extends StateNotifier<Set<Key>> {
  TimelineSplitNotifier() : super(const {});

  void setSplit(Key key, bool split) {
    if (state.contains(key) == split) return;
    state = split ? {...state, key} : ({...state}..remove(key));
  }
}

final timelineSplitProvider =
    StateNotifierProvider<TimelineSplitNotifier, Set<Key>>(
      (ref) => TimelineSplitNotifier(),
    );
