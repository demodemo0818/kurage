// lib/providers/tab_state_provider.dart

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// タブの状態を保持するプロバイダー
class TabStateNotifier extends StateNotifier<int> {
  TabStateNotifier() : super(0);

  /// タブインデックスを設定
  void setTabIndex(int index) {
    state = index;
  }

  /// 現在のタブインデックスを取得
  int get currentIndex => state;
}

final tabStateProvider = StateNotifierProvider<TabStateNotifier, int>(
  (ref) => TabStateNotifier(),
);