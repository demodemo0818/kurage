// lib/services/app_navigator.dart

import 'package:flutter/widgets.dart';

/// アプリ全体で共有するルート Navigator のキー。
///
/// `html_parser` が生成するハッシュタグ / メンションのタップ遷移は、
/// `_PostTileState._spanCache` (static, status ID キーで全タイル共有) に
/// キャッシュされた span から発火する。span の onTap クロージャが「最初に
/// その status をパースしたタイル」の `BuildContext` を捕捉してしまうと、
/// スクロールでそのタイルが unmount された後にキャッシュが別タイルへ再利用
/// された時、defunct な context で `Navigator.push` することになり黙って失敗
/// する (URL は `launchUrl` で context 不要なので動くが、ページ遷移系の
/// ハッシュタグ / メンションだけ「タップしても何も起きない」状態になる)。
///
/// この問題を避けるため、遷移はタイルの context ではなく常に生きている
/// ルート Navigator をこのキー経由で引いて行う。MaterialApp は単一 Navigator
/// なので、従来 `Navigator.push(tileContext, ...)` が解決していた相手と同一。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
