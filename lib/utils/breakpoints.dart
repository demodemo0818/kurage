// lib/utils/breakpoints.dart

import 'package:flutter/widgets.dart';

/// レスポンシブ判定の境界幅。
///
/// この幅以上ではデスクトップ / タブレット用の UI (左サイドレール +
/// カラム毎ヘッダー + 横スクロール TweetDeck 風レイアウト) を使う。
/// 未満では従来のモバイル UI (BottomNav + AppBar + TabBar 切替) を使う。
///
/// 単一箇所で定義することで、TabBar の表示判定・AppBar の表示判定・
/// NavigationRail への切替などの分岐をすべて同じ閾値で揃える。
const double kWideLayoutBreakpoint = 600;

/// 現在の MediaQuery 幅がワイドレイアウト相当か。
bool isWideLayout(BuildContext context) =>
    MediaQuery.of(context).size.width > kWideLayoutBreakpoint;

/// 1 カラムの固定幅 (ワイドレイアウト時)。TweetDeck / Mastodon 上級者モード
/// に揃えた典型値。カラム数が増えて画面幅を超えたら親側で横スクロール。
const double kColumnWidth = 340;

/// 全カラムが画面幅に収まる時に等分 fill する際の、1 カラムあたりの最大幅。
/// 1 カラムだけを巨大モニタいっぱいに引き伸ばすと却って読みづらいので、
/// この幅で頭打ちにして残りは左右の余白 (中央寄せ) にする。
/// 固定幅モードの幅スライダーの上限にも流用する。
const double kColumnMaxWidth = 600;

/// 固定幅モードでユーザーが指定できる 1 カラムの最小幅 (幅スライダーの下限)。
const double kColumnMinWidth = 260;

/// TweetDeck 風の投稿ペイン (ワイドレイアウトでタイムライン横に出す投稿欄) の幅。
const double kComposePaneWidth = 360;

/// Deck (ワイド) で、ホームに重ねて出す各ページ (通知/DM/プロフィール/設定/検索)
/// ポップアップの最大幅。大画面でページが横に広がりすぎるのを防ぐ。
const double kDeckPopupMaxWidth = 520;
