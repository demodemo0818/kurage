import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/auth_account.dart';
import '../pages/profile_page.dart';
import '../providers/deck_popup_provider.dart';
import '../providers/deck_profile_provider.dart';
import 'breakpoints.dart';

/// Deck (ワイド) のプロフィールポップアップの「中」であることを示すマーカー。
/// ポップアップ内で更にユーザーを開いたときに、新しいポップアップを開くのでは
/// なく nested Navigator に push (スタック) させるための判定に使う。
class DeckPopupScope extends InheritedWidget {
  const DeckPopupScope({super.key, required super.child});

  static bool isInside(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeckPopupScope>() != null;

  @override
  bool updateShouldNotify(DeckPopupScope oldWidget) => false;
}

/// プロフィールを開く統一エントリ。
///
/// - Deck のプロフィールポップアップの中から呼ばれた → そのポップアップの nested
///   Navigator に push (スタックされ、AppBar に自動の戻る矢印が出る)。
/// - ワイド幅 かつ ルート画面 (タイムライン等) から呼ばれた → プロフィールを
///   ポップアップ表示 ([deckProfileProvider])。
/// - それ以外 (ナロー / push 済みサブ画面) → 従来通りフルスクリーン push。
///
/// `ref` を取らず `ProviderScope.containerOf` で読むので、StatelessWidget
/// (アバター/ブースト元バー等) からも `context` だけで呼べる。
void openProfile(
  BuildContext context, {
  required AuthAccount user,
  String? targetAccountId,
  String? targetUsername,
  String? targetInstanceUrl,
}) {
  ProfilePage build(VoidCallback? onDeckBack) => ProfilePage(
        user: user,
        targetAccountId: targetAccountId,
        targetUsername: targetUsername,
        targetInstanceUrl: targetInstanceUrl,
        onDeckBack: onDeckBack,
      );

  // 既に Deck ポップアップの中 → nested Navigator に push (戻る矢印は自動)。
  if (DeckPopupScope.isInside(context)) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => build(null)),
    );
    return;
  }

  final atRoot = ModalRoute.of(context)?.isFirst ?? true;
  if (isWideLayout(context) && atRoot) {
    ProviderScope.containerOf(context, listen: false)
        .read(deckProfileProvider.notifier)
        .open(
          user: user,
          targetAccountId: targetAccountId,
          targetUsername: targetUsername,
          targetInstanceUrl: targetInstanceUrl,
        );
    return;
  }

  Navigator.push(context, MaterialPageRoute(builder: (_) => build(null)));
}

/// 任意のページを開く統一エントリ ([openProfile] の汎用版)。
///
/// - Deck のポップアップの中から呼ばれた → そのポップアップの nested Navigator に
///   push (スタックされ、AppBar に自動の戻る矢印が出る)。
/// - ワイド幅 かつ ルート画面 (タイムライン等) から呼ばれた → ホームに重ねる
///   ポップアップ表示 ([deckPopupProvider])。
/// - それ以外 (ナロー / push 済みサブ画面) → 従来通りフルスクリーン push。
///
/// [build] は「閉じるコールバック (onDeckBack)」を受け取ってページを返す。Deck
/// ポップアップの最初のページのときだけ非 null が渡る (AppBar の戻る ← に使う)。
/// nested push / フルスクリーン push のときは null (自動の戻る矢印に任せる)。
void openDeckPage(
  BuildContext context,
  Widget Function(VoidCallback? onDeckBack) build,
) {
  if (DeckPopupScope.isInside(context)) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => build(null)));
    return;
  }

  final atRoot = ModalRoute.of(context)?.isFirst ?? true;
  if (isWideLayout(context) && atRoot) {
    ProviderScope.containerOf(context, listen: false)
        .read(deckPopupProvider.notifier)
        .open((onDeckBack) => build(onDeckBack));
    return;
  }

  Navigator.push(context, MaterialPageRoute(builder: (_) => build(null)));
}
