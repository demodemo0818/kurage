import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_account.dart';

/// Deck (ワイド) で「他人/自分のプロフィールをポップアップ表示する」リクエスト。
///
/// `seq` は開くたびに +1。ポップアップ内の nested Navigator の key に使い、別の
/// プロフィールを (ポップアップ外から) 開き直したときに作り直す。ポップアップの
/// 中でさらにユーザーを開いた場合は nested Navigator に push されるので、この
/// provider は触らない (= ポップアップ単位の「最初に開いたユーザー」を表す)。
class DeckProfileRequest {
  final int seq;
  final AuthAccount user; // 閲覧に使うアカウント (API 呼び出し主)
  final String? targetAccountId;
  final String? targetUsername;
  final String? targetInstanceUrl;

  const DeckProfileRequest({
    required this.seq,
    required this.user,
    this.targetAccountId,
    this.targetUsername,
    this.targetInstanceUrl,
  });
}

class DeckProfileNotifier extends StateNotifier<DeckProfileRequest?> {
  DeckProfileNotifier() : super(null);

  int _seq = 0;

  void open({
    required AuthAccount user,
    String? targetAccountId,
    String? targetUsername,
    String? targetInstanceUrl,
  }) {
    state = DeckProfileRequest(
      seq: ++_seq,
      user: user,
      targetAccountId: targetAccountId,
      targetUsername: targetUsername,
      targetInstanceUrl: targetInstanceUrl,
    );
  }

  void close() {
    if (state != null) state = null;
  }
}

final deckProfileProvider =
    StateNotifierProvider<DeckProfileNotifier, DeckProfileRequest?>(
  (ref) => DeckProfileNotifier(),
);
