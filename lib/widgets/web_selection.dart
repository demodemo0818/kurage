// lib/widgets/web_selection.dart

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

/// Web でだけ、[child] をアプリ全体の `SelectionArea` (main.dart の `home`)
/// の選択対象から外す。Web 以外はルートに `SelectionArea` が無いので素通し。
///
/// 投稿の一覧や、SSE で頻繁に中身が変わる領域は外しておく。`SelectionArea`
/// 配下に置いたままだと Flutter の選択機構の不具合を踏んで Web で例外が連鎖し、
/// 一度崩れるとリロードまで落ち続ける:
///  - `PostTile` は `wantKeepAlive` なので、ListView で画面外に出ても破棄されず
///    レイアウトもされないまま残る。そこへ新しい Text がマウントされる (返信先の
///    表示名の取得完了、通知のグループへの追加等) と、選択機構が画面順の
///    並べ替えでサイズを読みに行き `RenderBox was not laid out` で落ちる
///    (Sentry KURAGE-8D / 8F)。
///  - 選択操作の後に選択対象が増減すると、Scrollable の選択デリゲートが走査中の
///    リストを変更して ConcurrentModificationError になる (KURAGE-87)。
///  - `ScrollablePositionedList` とは非互換で、スクロールが止まる
///    (flutter/flutter#111572)。
///
/// 投稿本文の選択は、本文タップで開く詳細ポップアップ (Overlay 上の
/// `SelectionArea`) で行う。
///
/// 同じ位置で包む / 包まないを実行時に切り替えないこと。Scrollable や Text は
/// 選択レジストラの有無で子のツリー構造を変えるので、配下の State が作り直される。
Widget excludeFromWebSelection(Widget child) =>
    kIsWeb ? SelectionContainer.disabled(child: child) : child;
