import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Deck (ワイド) で「カラム設定をポップアップ表示する」かどうかのフラグ。
///
/// ホームのカラムヘッダー (⋮ メニュー → カラムを編集) から `open()` され、
/// `main.dart` の `_buildDeckBody` がこれを watch してホーム上にポップアップを
/// 重ねる。`false` になるとポップアップ widget ごとツリーから外れるので、再度
/// 開いたときは nested Navigator が作り直されて初期状態に戻る。
class DeckColumnSettingsNotifier extends StateNotifier<bool> {
  DeckColumnSettingsNotifier() : super(false);

  void open() {
    if (!state) state = true;
  }

  void close() {
    if (state) state = false;
  }
}

final deckColumnSettingsProvider =
    StateNotifierProvider<DeckColumnSettingsNotifier, bool>(
  (ref) => DeckColumnSettingsNotifier(),
);
