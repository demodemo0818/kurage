// lib/services/boss_disguise_web.dart
//
// Web 実装。document.title と favicon (<link rel="icon">) を退避→差替→復元する。
// dart:html は deprecated のため package:web + dart:js_interop を使う。
//
// favicon は商標画像をリポジトリに同梱せず、実行時に Google 自身が配信する
// favicon URL を指す (= 同梱ではなく外部参照)。取得失敗してもタブ title だけで
// 偽装は十分成立するので致命的ではない。
//
// 注意: favicon は `<link>` の href を書き換えるだけだとブラウザが再描画しない
// ことがある (特に元に戻すとき)。確実に反映させるため icon link 要素ごと
// 作り直す。

import 'dart:js_interop';

import 'package:web/web.dart' as web;

String? _savedTitle;
String? _savedFaviconHref;
bool _applied = false;

void applyDisguise() {
  if (_applied) return;
  _applied = true;

  _savedTitle = web.document.title;
  web.document.title = 'Google';

  _savedFaviconHref = _currentFaviconHref();
  _setFavicon('https://www.google.com/favicon.ico');
}

void restoreDisguise() {
  if (!_applied) return;
  _applied = false;

  if (_savedTitle != null) {
    web.document.title = _savedTitle!;
    _savedTitle = null;
  }
  // 退避していた favicon に戻す。元々 link が無かった場合は index.html の
  // 既定 (favicon.png、base href 相対) を指す。
  _setFavicon(_savedFaviconHref ?? 'favicon.png');
  _savedFaviconHref = null;
}

String? _currentFaviconHref() {
  final el = web.document.querySelector('link[rel~="icon"]');
  // js_interop の extension type には `is` が使えない (常に representation
  // type の判定になる) ため、isA<T>() でブラウザ側の instanceof 判定を行う。
  if (el != null && el.isA<web.HTMLLinkElement>()) {
    return (el as web.HTMLLinkElement).href;
  }
  return null;
}

/// favicon を確実に更新するため、既存の icon link を全て除去して
/// 新しい `<link rel="icon">` を作り直す。
void _setFavicon(String href) {
  final head = web.document.head;
  if (head == null) return;
  // 既存の rel="icon" / rel="shortcut icon" を全削除。NodeList は static
  // (live でない) だが、安全のため先に Dart List へコピーしてから remove する。
  final list = web.document.querySelectorAll('link[rel~="icon"]');
  final toRemove = <web.Element>[
    for (var i = 0; i < list.length; i++)
      if (list.item(i) != null && list.item(i)!.isA<web.Element>())
        list.item(i)! as web.Element,
  ];
  for (final e in toRemove) {
    e.remove();
  }
  head.appendChild(web.HTMLLinkElement()
    ..rel = 'icon'
    ..href = href);
}
