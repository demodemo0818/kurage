import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/status.dart';
import '../pages/post_page.dart';
import '../providers/compose_pane_provider.dart';
import 'breakpoints.dart';

/// 投稿コンポーズを開く統一エントリ。
///
/// ワイド幅 (デスクトップ) かつ「ルート画面 (タイムライン) の中」から呼ばれた
/// ときだけ TweetDeck 風の横ペイン ([composePaneProvider]) に出す。ナロー幅や、
/// スレッド/プロフィール等の push されたサブ画面から呼ばれたときは従来通り
/// フルスクリーン [PostPage] を push する。
///
/// サブ画面でペインに振らないのは、横ペインは RootPage の階層に居るため、
/// 上に被さった push 済みページの裏に隠れて見えなくなるため。`ModalRoute.isFirst`
/// で「最初のルート (= RootPage) の中か」を判定する。
///
/// 新規 / 返信 / 引用 / ハッシュタグ初期テキスト / 編集 を 1 つの入口で扱う。
///
/// 編集 (`editStatusId`) は本文 `initialText` に `getStatusSource` で取得した
/// 元テキストを渡して呼ぶ (CW / 公開範囲 / 投票 / メディアは PostPage が
/// `editTargetStatus` から復元する)。編集結果の表示中リストへの反映は PostPage
/// 側で `publishLocalStatusEdited` するので、呼び出し元は戻り値を受け取らなくて
/// よい。削除して下書き (redraft) のような他の復元モードは引き続き対象外。
void openCompose(
  BuildContext context,
  WidgetRef ref, {
  String? replyToStatusId,
  String? replyToUsername,
  String? replyToVisibility,
  String? initialText,
  String? initialVisibility,
  Status? quotedStatus,
  List<String>? initialAccountIds,
  String? editStatusId,
  Status? editTargetStatus,
  String? editAccountId,
}) {
  final atRoot = ModalRoute.of(context)?.isFirst ?? true;
  if (isWideLayout(context) && atRoot) {
    final notifier = ref.read(composePaneProvider.notifier);
    if (editStatusId != null) {
      notifier.openEdit(
        statusId: editStatusId,
        target: editTargetStatus!,
        accountId: editAccountId!,
        initialText: initialText ?? '',
        initialVisibility: initialVisibility,
      );
    } else if (replyToStatusId != null) {
      notifier.openReply(
        statusId: replyToStatusId,
        username: replyToUsername,
        visibility: replyToVisibility,
        accountIds: initialAccountIds,
      );
    } else if (quotedStatus != null) {
      notifier.openQuote(
        quotedStatus: quotedStatus,
        visibility: initialVisibility,
        accountIds: initialAccountIds,
      );
    } else if (initialText != null) {
      notifier.openWithText(initialText, accountIds: initialAccountIds);
    } else {
      notifier.openNew(accountIds: initialAccountIds);
    }
    return;
  }

  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => PostPage(
        replyToStatusId: replyToStatusId,
        replyToUsername: replyToUsername,
        replyToVisibility: replyToVisibility,
        initialText: initialText,
        initialVisibility: initialVisibility,
        quotedStatus: quotedStatus,
        initialAccountIds: initialAccountIds,
        editStatusId: editStatusId,
        editTargetStatus: editTargetStatus,
        editAccountId: editAccountId,
      ),
    ),
  );
}
