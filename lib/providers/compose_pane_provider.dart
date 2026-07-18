import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/status.dart';

/// 横ペイン投稿 (TweetDeck 風) の「いま何を書くか」を表す不変リクエスト。
///
/// 各 null フィールドは [PostPage] のデフォルトに従う (= 新規投稿)。`seq` は
/// 内容が変わるたびに +1 され、ペインに埋め込む `PostPage` の `ValueKey` に
/// 使う。返信/引用に切り替えたときは seq が変わって PostPage が作り直され、
/// 新しい初期パラメタ (initState で読まれる) が反映される。
class ComposeRequest {
  final int seq;
  final String? replyToStatusId;
  final String? replyToUsername;
  final String? replyToVisibility;
  final String? initialText;
  final String? initialVisibility;
  final Status? quotedStatus;
  final List<String>? initialAccountIds;

  /// 編集モード。non-null なら [editTargetStatus] / [editAccountId] も必須。
  /// CW / 公開範囲 / 投票 / メディアは PostPage が editTargetStatus から復元する。
  final String? editStatusId;
  final Status? editTargetStatus;
  final String? editAccountId;

  /// true なら PostPage が退避下書き (`post_temp_draft`) を復元せず、既存の
  /// 退避下書きも削除して完全にまっさらで開く。「(返信等を) 破棄して新規投稿」
  /// の確認ダイアログから使う。
  final bool freshStart;

  const ComposeRequest({
    required this.seq,
    this.replyToStatusId,
    this.replyToUsername,
    this.replyToVisibility,
    this.initialText,
    this.initialVisibility,
    this.quotedStatus,
    this.initialAccountIds,
    this.editStatusId,
    this.editTargetStatus,
    this.editAccountId,
    this.freshStart = false,
  });

  /// 新規投稿以外の作成中コンテキスト (返信 / 引用 / 編集) か。ホスト側が
  /// 「新規投稿ボタンで黙って破棄してよいか」の判定に使う。
  bool get isReplyOrQuoteOrEdit =>
      replyToStatusId != null || quotedStatus != null || editStatusId != null;
}

/// 横ペインの表示状態 (開いているか) と現在のリクエスト。
class ComposePaneState {
  /// ユーザー操作で開いているか。実際の表示可否は「ピン固定 OR open」で
  /// 決まる (ピンは settings 側 `composePaneFixed`)。
  final bool open;
  final ComposeRequest request;

  const ComposePaneState({required this.open, required this.request});

  ComposePaneState copyWith({bool? open, ComposeRequest? request}) =>
      ComposePaneState(
        open: open ?? this.open,
        request: request ?? this.request,
      );
}

/// 横ペイン投稿の状態を駆動する Notifier。
///
/// 起点 (rail の投稿 FAB / `n` キー / タイムラインの返信・引用) はワイド幅の
/// ときにこの Notifier を叩いてペインを開く。ナロー幅では従来通り
/// `PostPage` をフルスクリーン push する (振り分けは `openCompose` ヘルパー)。
class ComposePaneNotifier extends StateNotifier<ComposePaneState> {
  ComposePaneNotifier()
      : super(const ComposePaneState(
          open: false,
          request: ComposeRequest(seq: 0),
        ));

  int _seq = 0;
  int get _nextSeq => ++_seq;

  /// 新規投稿でペインを開く。[freshStart] は「(返信等を) 破棄して新規投稿」用:
  /// PostPage が退避下書きを復元せず、既存の退避下書きも削除する。
  void openNew({List<String>? accountIds, bool freshStart = false}) {
    state = ComposePaneState(
      open: true,
      request: ComposeRequest(
        seq: _nextSeq,
        initialAccountIds: accountIds,
        freshStart: freshStart,
      ),
    );
  }

  /// 投稿 FAB / `n` キーのトグル。開いていれば閉じ、閉じていれば新規投稿で開く。
  /// 閉じても下書きは `post_temp` に退避されるので内容は失われない。
  void toggleNew({List<String>? accountIds}) {
    if (state.open) {
      close();
    } else {
      openNew(accountIds: accountIds);
    }
  }

  /// 返信でペインを開く (内容を差し替え)。
  void openReply({
    required String statusId,
    String? username,
    String? visibility,
    List<String>? accountIds,
  }) {
    state = ComposePaneState(
      open: true,
      request: ComposeRequest(
        seq: _nextSeq,
        replyToStatusId: statusId,
        replyToUsername: username,
        replyToVisibility: visibility,
        initialAccountIds: accountIds,
      ),
    );
  }

  /// 引用でペインを開く (内容を差し替え)。
  void openQuote({
    required Status quotedStatus,
    String? visibility,
    List<String>? accountIds,
  }) {
    state = ComposePaneState(
      open: true,
      request: ComposeRequest(
        seq: _nextSeq,
        quotedStatus: quotedStatus,
        initialVisibility: visibility,
        initialAccountIds: accountIds,
      ),
    );
  }

  /// 編集でペインを開く (内容を差し替え)。本文 [initialText] は呼び出し側が
  /// `getStatusSource` で取得した元テキストを渡す。CW / 公開範囲 / 投票 /
  /// メディアは PostPage が [target] から復元する。
  void openEdit({
    required String statusId,
    required Status target,
    required String accountId,
    required String initialText,
    String? initialVisibility,
  }) {
    state = ComposePaneState(
      open: true,
      request: ComposeRequest(
        seq: _nextSeq,
        editStatusId: statusId,
        editTargetStatus: target,
        editAccountId: accountId,
        initialText: initialText,
        initialVisibility: initialVisibility,
      ),
    );
  }

  /// 初期テキスト付きでペインを開く (ハッシュタグ投稿など)。
  void openWithText(String text, {List<String>? accountIds}) {
    state = ComposePaneState(
      open: true,
      request: ComposeRequest(
        seq: _nextSeq,
        initialText: text,
        initialAccountIds: accountIds,
      ),
    );
  }

  /// ペインを閉じる (リクエストは保持)。ピン固定中はホスト側で表示が維持される。
  void close() {
    if (state.open) state = state.copyWith(open: false);
  }
}

final composePaneProvider =
    StateNotifierProvider<ComposePaneNotifier, ComposePaneState>(
  (ref) => ComposePaneNotifier(),
);
