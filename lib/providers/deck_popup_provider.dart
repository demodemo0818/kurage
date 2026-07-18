import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Deck (ワイド) で「任意のページをポップアップ表示する」リクエスト。
///
/// プロフィール ([deckProfileProvider]) と同じ仕組みの汎用版。タイムラインや
/// 投稿から開くハッシュタグ / スレッド / 編集履歴 / リアクション一覧 / 通報
/// などを、フルスクリーン push ではなくホームに重ねるポップアップ (中身は
/// nested Navigator) で表示するために使う。
///
/// [builder] は「ポップアップ全体を閉じるコールバック (onDeckBack)」を受け取り、
/// ポップアップの最初のページを返す。ページ側はこれを AppBar の戻る (←) に
/// 使う (最初のページは nested Navigator で pop できないため)。ポップアップ内で
/// 更に push されたページは nested Navigator の自動の戻る矢印で 1 つ戻る。
///
/// [seq] は開くたびに +1。nested Navigator の key に使い、別ページを開き直した
/// ときに作り直す。
class DeckPopupRequest {
  final int seq;
  final Widget Function(VoidCallback onDeckBack) builder;

  const DeckPopupRequest({required this.seq, required this.builder});
}

class DeckPopupNotifier extends StateNotifier<DeckPopupRequest?> {
  DeckPopupNotifier() : super(null);

  int _seq = 0;

  void open(Widget Function(VoidCallback onDeckBack) builder) {
    state = DeckPopupRequest(seq: ++_seq, builder: builder);
  }

  void close() {
    if (state != null) state = null;
  }
}

final deckPopupProvider =
    StateNotifierProvider<DeckPopupNotifier, DeckPopupRequest?>(
  (ref) => DeckPopupNotifier(),
);
