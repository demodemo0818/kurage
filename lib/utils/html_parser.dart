// lib/utils/html_parser.dart
//
// Mastodon の status content HTML を `InlineSpan` のリストに変換する。
//
// 旧実装は `<a>` 抽出 → 残り全 HTML タグを正規表現で剥ぐ → 平文に対して
// URL/絵文字/ハッシュタグ/メンションの正規表現マッチ、という流れだった。
// MFM 由来の `<blockquote>`, `<strong>`, `<em>`, `<del>`, `<code>`, `<pre>`,
// `<u>`, `<ul>/<ol>/<li>` 等が捨てられ、Mastodon Web / 公式アプリで見える
// 装飾が当アプリでは出ていなかった。
//
// 本実装は `package:html` で DOM を構築し、ノードを再帰的に walk する:
// - インライン装飾タグ (b/strong, i/em, u, del/s, code) は currentStyle に
//   重ね合わせて子要素を再描画。
// - ブロック要素 (blockquote, pre, ul/ol/li) は WidgetSpan で囲んで枠線 /
//   背景 / インデントを付ける。
// - `<a>` は class や URL パターンから mention / hashtag / 通常 URL を
//   判別して、それぞれ正しいタップ動作を持つ TextSpan に。
// - text node 内では既存の URL/絵文字/ハッシュタグ/メンション正規表現が
//   そのまま走る (タグで囲われていない平文中の URL も拾う)。
//
// Mastodon の sanitizer (`Sanitize::Config::MASTODON_STRICT`) で許容
// される要素にほぼ揃えてある。本実装が認識しない要素は中身だけが
// 反映され装飾は無視される。

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parseFragment;
import 'package:url_launcher/url_launcher.dart';
import '../models/emoji.dart';
import '../widgets/network_image_x.dart';
import '../pages/hashtag_page.dart';
import '../providers/auth_provider.dart';
import '../services/app_navigator.dart';
import 'html_text_utils.dart';
import 'open_profile.dart';

// 純粋なテキスト処理 (plain text 抽出) は html_text_utils.dart に分離した。
// 既存呼び出し元が `html_parser.dart` から import している API は re-export
// して互換を保つ。
export 'html_text_utils.dart' show parseHtmlToPlainText;

// 正規表現はモジュールレベルで一度だけコンパイル
final _urlRegex = RegExp(r'https?://[^\s<>"{}|\\^`\[\]]+');
final _emojiRegex = RegExp(r':([A-Za-z0-9_]+):');
// Mastodon の `HASHTAG_NAME_RE` (`[[:word:]_·\-—]+`) と概ね揃える。
// Unicode の letter / number / underscore に加え、middle dot (·) /
// hyphen (-) / em dash (—) を許容。これがないと Latin diacritics 付き
// (`#München`) / Cyrillic (`#русский`) / Hangul (`#한국어`) / CJK
// 拡張漢字 / `#open-source` 等が plain text 中で hashtag として
// 検出されず素のテキストになってしまう。
final _hashtagRegex = RegExp(
  r'#([\p{L}\p{N}_][\p{L}\p{N}_·\-—]*)',
  unicode: true,
);
final _mentionRegex =
    RegExp(r'@([a-zA-Z0-9_]+)(?:@([a-zA-Z0-9.-]+))?');

// plain text 中の hashtag / mention は「直前の文字」で語中マッチを弾く
// (`C#が好き` の `#` や `aaa@example.com` の `@` をリンク化しないため)。
// Mastodon 本体の Twitter::TwitterText::Regex に揃える:
//   HASHTAG_RE は `(?:^|[^\/\)\w])#` — 直前が `/`, `)`, ASCII word ならタグ扱いしない
//   MENTION_RE は `(?<![=\/[:word:]])@` — 直前が `=`, `/`, Unicode word なら扱いしない
final _hashtagBoundaryBlock = RegExp(r'[A-Za-z0-9_/)]');
final _mentionBoundaryBlock = RegExp(r'[\p{L}\p{N}_/=]', unicode: true);

// マッチ直前の文字が block クラスに該当しなければ境界あり (リンク化してよい)。
// 直前がサロゲートペア (絵文字等) のときは low surrogate 単体はどちらの
// クラスにもマッチせず「境界あり」= 寛容側に倒れる。Mastodon と同じ挙動。
bool _hasLinkBoundary(String text, int start, RegExp block) =>
    start == 0 || !block.hasMatch(text[start - 1]);

// プラットフォーム横断的に「等幅」を要求する文字列。Flutter は
// 'monospace' を OS のデフォルト等幅フォントにマップする。
const String _monospaceFamily = 'monospace';

// Unicode 双方向 (bidi) アイソレート文字。Mastodon Web が表示名を `<bdi>`
// で囲むのと同じ役割で、表示名に含まれる RLO 等の制御文字の効果を名前の
// 枠内に閉じ込め、後続の `@ハンドル` や数字へ漏れて並びが壊れるのを防ぐ。
// ソース中に不可視の制御文字を直接埋め込まないよう fromCharCode で生成する。
final String _bidiIsolateStart = String.fromCharCode(0x2068); // FSI
final String _bidiIsolateEnd = String.fromCharCode(0x2069); // PDI

/// DOM walk 中に持ち回るレンダリング・コンテキスト。
/// `currentStyle` だけが内側で書き換わるので `withStyle` で派生させる。
class _Ctx {
  final List<Emoji> emojis;
  final TextStyle baseStyle;
  final Color linkColor;
  final double emojiSize;
  final BuildContext? context;
  final bool disableEmojiAnimation;
  final TextStyle currentStyle;

  /// プレーンテキスト中の `@user` / `#tag` / `https://...` を自動でリンクに
  /// するかどうか。本文 (status content) では true、表示名 (display name) や
  /// 同等のメタテキストでは false にする。Mastodon Web も表示名中の `@`
  /// 等はクリック対象にしていないので、それに揃える。
  final bool enableInlineLinks;

  const _Ctx({
    required this.emojis,
    required this.baseStyle,
    required this.linkColor,
    required this.emojiSize,
    required this.context,
    required this.disableEmojiAnimation,
    required this.currentStyle,
    required this.enableInlineLinks,
  });

  _Ctx withStyle(TextStyle s) => _Ctx(
        emojis: emojis,
        baseStyle: baseStyle,
        linkColor: linkColor,
        emojiSize: emojiSize,
        context: context,
        disableEmojiAnimation: disableEmojiAnimation,
        currentStyle: s,
        enableInlineLinks: enableInlineLinks,
      );
}

/// Mastodon の content HTML を構造解析して `InlineSpan` のリストにする。
///
/// 性能: パース結果は post_tile 側で `_cachedParseSpans` メモ化される。
/// 同じ HTML + style 引数なら再呼び出しでも 1 回しか走らない。
///
/// 異常系: 不正な HTML / 不正な percent encoding 等で walk 中に例外が
/// 起きても投稿表示を全部失わせないように、ここで catch して raw HTML を
/// 平文化したフォールバックを返す。`debugPrint` でログだけ残す。
List<InlineSpan> parseContentWithEmojis({
  required String contentHtml,
  required List<Emoji> emojis,
  required TextStyle baseStyle,
  required Color linkColor,
  required double emojiSize,
  BuildContext? context,
  bool disableEmojiAnimation = false,
  // 本文以外 (表示名 / 同等のメタテキスト) では false にして、プレーンテキスト
  // 中の `@user` / `#tag` / `https://...` を自動リンク化しないようにする。
  // 表示名に偶然 `@` が混ざっただけでメンション扱いされるのを防ぐ。
  bool enableInlineLinks = true,
}) {
  try {
    final fragment = parseFragment(contentHtml);
    final ctx = _Ctx(
      emojis: emojis,
      baseStyle: baseStyle,
      linkColor: linkColor,
      emojiSize: emojiSize,
      context: context,
      disableEmojiAnimation: disableEmojiAnimation,
      currentStyle: baseStyle,
      enableInlineLinks: enableInlineLinks,
    );
    final spans = _walkNodes(fragment.nodes, ctx);
    final result = _trimEdgeNewlines(spans);
    // 表示名 / メタテキスト (enableInlineLinks == false) は Unicode 双方向
    // アイソレート (FSI … PDI) で囲む。Mastodon Web が表示名を `<bdi>` で
    // 囲むのと同じ考え方で、名前に `U+202E RIGHT-TO-LEFT OVERRIDE` 等の
    // 双方向制御文字が含まれていても、その効果が名前の枠内で完結し、同じ
    // `RichText` 内に続く `@ハンドル` や数字へ漏れて並びを壊すのを防ぐ。
    // 名前自身の bidi 表示 (troll が意図した顔文字の左右反転など) は除去
    // せずそのまま保持する (Mastodon Web 等の他クライアントと同じ見た目)。
    if (!enableInlineLinks && result.isNotEmpty) {
      return [
        TextSpan(text: _bidiIsolateStart, style: baseStyle),
        ...result,
        TextSpan(text: _bidiIsolateEnd, style: baseStyle),
      ];
    }
    return result;
  } catch (e, st) {
    debugPrint('parseContentWithEmojis fallback: $e\n$st');
    // フォールバック: 平文化したテキストを 1 個の TextSpan として返す。
    // 装飾は失われるが少なくとも本文は読める。
    String fallback;
    try {
      fallback = parseHtmlToPlainText(contentHtml);
    } catch (_) {
      fallback = contentHtml;
    }
    return [TextSpan(text: fallback, style: baseStyle)];
  }
}

List<InlineSpan> _walkNodes(List<dom.Node> nodes, _Ctx ctx) {
  final spans = <InlineSpan>[];
  for (final node in nodes) {
    if (node is dom.Text) {
      spans.addAll(_processTextRun(node.text, ctx));
    } else if (node is dom.Element) {
      spans.addAll(_processElement(node, ctx));
    }
  }
  return spans;
}

List<InlineSpan> _processTextRun(String text, _Ctx ctx) {
  if (text.isEmpty) return const [];
  return _scanTextForInlineMatches(text, ctx);
}

List<InlineSpan> _processElement(dom.Element el, _Ctx ctx) {
  final name = el.localName?.toLowerCase();
  switch (name) {
    case 'p':
      // 段落: 子要素 + 末尾の空行 1 行 (= '\n\n')。
      // Mastodon の `TextFormatter` は本文中の空行 (`\n{2,}`) を `</p><p>` に
      // 変換するため、`<p>A</p><p>B</p>` は本来「A・空行・B」として描画される
      // べき。ここで `\n` 1 個だけ足すと段落間が詰まって表示されるので `\n\n`
      // にしている。末尾の余分な空行は `_trimEdgeNewlines` で除去される。
      final inner = _walkNodes(el.nodes, ctx);
      if (inner.isEmpty) return const [];
      return [...inner, TextSpan(text: '\n\n', style: ctx.currentStyle)];
    case 'br':
      return [TextSpan(text: '\n', style: ctx.currentStyle)];
    case 'a':
      return _processAnchor(el, ctx);
    case 'span':
      // Mastodon の URL 省略表記 `<span class="invisible">` は中身を捨てる
      final cls = (el.attributes['class'] ?? '').toLowerCase();
      if (cls.contains('invisible')) return const [];
      return _walkNodes(el.nodes, ctx);
    case 'strong':
    case 'b':
      return _walkNodes(
        el.nodes,
        ctx.withStyle(ctx.currentStyle.copyWith(fontWeight: FontWeight.bold)),
      );
    case 'em':
    case 'i':
      return _walkNodes(
        el.nodes,
        ctx.withStyle(ctx.currentStyle.copyWith(fontStyle: FontStyle.italic)),
      );
    case 'del':
    case 's':
    case 'strike':
      return _walkNodes(
        el.nodes,
        ctx.withStyle(_addDecoration(
            ctx.currentStyle, TextDecoration.lineThrough)),
      );
    case 'u':
      return _walkNodes(
        el.nodes,
        ctx.withStyle(_addDecoration(
            ctx.currentStyle, TextDecoration.underline)),
      );
    case 'code':
      // Inline code: 等幅 + 薄い背景。pre の入れ子としても動く。
      final bg =
          (ctx.currentStyle.color ?? const Color(0xFF888888))
              .withValues(alpha: 0.12);
      return _walkNodes(
        el.nodes,
        ctx.withStyle(ctx.currentStyle.copyWith(
          fontFamily: _monospaceFamily,
          backgroundColor: bg,
        )),
      );
    case 'pre':
      // ブロック等幅。中の <code> は currentStyle が等幅なのでそのまま通る。
      final inner = _walkNodes(
        el.nodes,
        ctx.withStyle(
            ctx.currentStyle.copyWith(fontFamily: _monospaceFamily)),
      );
      if (inner.isEmpty) return const [];
      return [_buildPreSpan(inner, ctx)];
    case 'blockquote':
      final inner = _walkNodes(el.nodes, ctx);
      if (inner.isEmpty) return const [];
      return [_buildBlockquoteSpan(inner, ctx)];
    case 'ul':
    case 'ol':
      return _processList(el, ctx, ordered: name == 'ol');
    case 'li':
      // 親の ul/ol が処理する想定。単独で来たときの fallback。
      return _walkNodes(el.nodes, ctx);
    default:
      return _walkNodes(el.nodes, ctx);
  }
}

TextStyle _addDecoration(TextStyle style, TextDecoration deco) {
  final existing = style.decoration;
  if (existing == null || existing == TextDecoration.none) {
    return style.copyWith(decoration: deco);
  }
  return style.copyWith(
      decoration: TextDecoration.combine([existing, deco]));
}

// ============================================================
// <a> ハンドリング
// ============================================================

List<InlineSpan> _processAnchor(dom.Element el, _Ctx ctx) {
  final href = el.attributes['href'] ?? '';
  final classes = (el.attributes['class'] ?? '')
      .split(RegExp(r'\s+'))
      .map((s) => s.toLowerCase())
      .toSet();
  final visibleText = _visibleText(el);

  // ハッシュタグ判定 (class または URL から)
  final isHashtag = classes.contains('hashtag') ||
      _isHashtagUrl(href) ||
      // class="mention hashtag" の併記もある
      (classes.contains('mention') && classes.contains('hashtag'));
  if (isHashtag) {
    final tag = extractValidHashtagFromUrl(href) ??
        visibleText.replaceFirst(RegExp(r'^#'), '');
    return [_buildHashtagSpan(tag, visibleText, ctx)];
  }
  // メンション
  if (classes.contains('mention')) {
    return [_buildMentionSpan(visibleText, href, ctx)];
  }
  // 通常 URL
  if (href.isEmpty) {
    // a タグだが href なし → 中身を text として扱う
    return _scanTextForInlineMatches(visibleText, ctx);
  }
  return [_buildUrlSpan(href, visibleText, ctx)];
}

/// `<a>` 子孫から「目に見えるテキスト」だけ抽出。`<span class="invisible">`
/// は除外。Mastodon の URL 短縮表示 (`<span class="invisible">https://</span>`
/// + 本体 + `<span class="ellipsis">…</span>` の 3 段組) で中央の本体だけ
/// 残すのに使う。
String _visibleText(dom.Element el) {
  final buf = StringBuffer();
  for (final node in el.nodes) {
    if (node is dom.Text) {
      buf.write(node.text);
    } else if (node is dom.Element) {
      final cls = (node.attributes['class'] ?? '').toLowerCase();
      if (cls.contains('invisible')) continue;
      buf.write(_visibleText(node));
    }
  }
  return buf.toString();
}

bool _isHashtagUrl(String url) {
  return RegExp(r'/(tags|tag)/[^/?#\s]+', caseSensitive: false).hasMatch(url);
}

// ============================================================
// テキストノード内の URL/絵文字/ハッシュタグ/メンション マッチ
// ============================================================

List<InlineSpan> _scanTextForInlineMatches(String text, _Ctx ctx) {
  // emoji だけは常に拾う (絵文字を表示名で出したいケースが普通にあるので)。
  // URL / hashtag / mention は `enableInlineLinks` が true のときだけ
  // プレーンテキスト中で検出する。`<a>` タグで明示されているリンクは
  // `_processAnchor` 経由なのでこのフラグの影響を受けない。
  final all = <_Match>[
    for (final m in _emojiRegex.allMatches(text)) _Match(m, _MatchType.emoji),
    if (ctx.enableInlineLinks) ...[
      for (final m in _urlRegex.allMatches(text)) _Match(m, _MatchType.url),
      for (final m in _hashtagRegex.allMatches(text))
        if (_hasLinkBoundary(text, m.start, _hashtagBoundaryBlock))
          _Match(m, _MatchType.hashtag),
      for (final m in _mentionRegex.allMatches(text))
        if (_hasLinkBoundary(text, m.start, _mentionBoundaryBlock))
          _Match(m, _MatchType.mention),
    ],
  ]..sort((a, b) => a.match.start.compareTo(b.match.start));

  final spans = <InlineSpan>[];
  int cursor = 0;
  for (final entry in all) {
    final match = entry.match;
    if (match.start < cursor) continue; // 既に処理済み範囲とオーバーラップ
    if (match.start > cursor) {
      spans.add(TextSpan(
        text: text.substring(cursor, match.start),
        style: ctx.currentStyle,
      ));
    }
    switch (entry.type) {
      case _MatchType.emoji:
        spans.add(_createEmojiSpan(match, ctx));
        break;
      case _MatchType.url:
        spans.add(_createUrlSpan(match, ctx));
        break;
      case _MatchType.hashtag:
        spans.add(_createHashtagSpan(match, ctx));
        break;
      case _MatchType.mention:
        spans.add(_createMentionSpan(match, ctx));
        break;
    }
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(
      text: text.substring(cursor),
      style: ctx.currentStyle,
    ));
  }
  return spans;
}

InlineSpan _createEmojiSpan(RegExpMatch match, _Ctx ctx) {
  final code = match.group(1)!;
  final emoji = ctx.emojis.firstWhere(
    (e) => e.shortcode == code,
    orElse: () => Emoji(shortcode: code, url: ''),
  );
  if (emoji.url.isEmpty) {
    return TextSpan(text: match.group(0)!, style: ctx.currentStyle);
  }
  final imageUrl =
      ctx.disableEmojiAnimation ? emoji.nonAnimatedUrl : emoji.animatedUrl;

  // 表示は emojiSize px (約 14〜24px) なのに、Misskey や一部の連合経由で来る
  // 元画像は 200〜500px のことが普通にある。`memCacheHeight` を指定しないと
  // 元サイズで GPU テクスチャを焼くため、本文に絵文字 20 個並ぶだけで数十 MB
  // のテクスチャを消費する。
  // 本表示サイズ × DPR を渡すことで「画面 1px = 1 テクセル」相当に縮小デコード。
  //
  // 高さは emojiSize で固定するが、**幅は指定しない**。Misskey/Fedibird の
  // 横長カスタム絵文字 (名前バナー型など) を `width: emojiSize` で正方形に
  // 押し潰さず、元画像のアスペクト比そのままに描画する。`memCacheWidth` も
  // 指定しないので、decode サイズは高さ基準で算出され幅は自動スケール
  // (= 4:1 の画像なら decode buffer も 4:1)。極端に横長な絵文字でも 1 行に
  // 収まりきらないだけで、押し潰しは起きない。
  final dpr = ctx.context != null
      ? MediaQuery.maybeDevicePixelRatioOf(ctx.context!) ?? 1.0
      : 1.0;
  final cacheHeight = (ctx.emojiSize * dpr).round();

  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    // マウスオーバー (モバイルは長押し) でショートコードを表示。
    // waitDuration が無いと本文上をマウスが横切るだけで次々ポップするため
    // 少し待たせる。
    child: Tooltip(
      message: ':$code:',
      waitDuration: const Duration(milliseconds: 300),
      child: KurageNetworkImage(
        imageUrl: imageUrl,
        height: ctx.emojiSize,
        memCacheHeight: cacheHeight,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        // 画像 load 完了までは正方形プレースホルダ。load 後にアスペクト比に
        // 応じて幅が変わるため、横長絵文字では 1 回 reflow が発生する (本文
        // 中で text が右にずれる)。Mastodon Web も同様の挙動。
        placeholder: (_, _) =>
            SizedBox(width: ctx.emojiSize, height: ctx.emojiSize),
        errorWidget: (_, _, _) =>
            Text(':$code:', style: ctx.currentStyle),
      ),
    ),
  );
}

InlineSpan _createUrlSpan(RegExpMatch match, _Ctx ctx) {
  final url = match.group(0)!;
  // ハッシュタグ URL なら hashtag スパンへ振替
  if (ctx.context != null) {
    final hashtag = extractValidHashtagFromUrl(url);
    if (hashtag != null) {
      return _buildHashtagSpan(hashtag, '#$hashtag', ctx);
    }
  }
  return _buildUrlSpan(url, shortenUrl(url), ctx);
}

InlineSpan _createHashtagSpan(RegExpMatch match, _Ctx ctx) {
  final fullMatch = match.group(0)!; // #foo
  final tag = match.group(1)!;
  return _buildHashtagSpan(tag, fullMatch, ctx);
}

InlineSpan _createMentionSpan(RegExpMatch match, _Ctx ctx) {
  final fullMatch = match.group(0)!;
  return _buildMentionSpan(fullMatch, '', ctx);
}

// ============================================================
// 共通の InlineSpan ビルダー (DOM 由来 / 正規表現由来 どちらからも使う)
// ============================================================

/// インタラクティブなトークン (URL / ハッシュタグ / メンション) のスパンを作る。
///
/// **Web では WidgetSpan (実ウィジェット) を使う**: Flutter web (CanvasKit) では
/// Text.rich のネストした TextSpan に付けた `TapGestureRecognizer.onTap` が
/// 発火しない (flutter/flutter#34931 系)。しかも recognizer はジェスチャ
/// アリーナを取ってしまうため、本文タップ用の外側 GestureDetector
/// (post_tile の Web 詳細ポップアップ) まで巻き込んで「ハッシュタグをタップ
/// しても何も起きない (ポップアップすら開かない)」状態になる。実ウィジェット
/// (GestureDetector) なら確実にヒットテストされるので、web のみ WidgetSpan で
/// 包む。モバイル / デスクトップネイティブでは従来通り TextSpan + recognizer
/// (テキストの行送り・折り返し・選択が自然) のままにする。
///
/// [onTap] には「タップ時点で生きている BuildContext」を渡す:
/// - Web: `Builder` で現在マウントされている要素の context を取得して渡す。
///   これにより Deck ポップアップ内のネスト遷移 (DeckPopupScope の判定) が
///   正しく効き、かつ static な span キャッシュ越しに stale な context を掴む
///   問題も起きない (遷移先の判定をパース時ではなくタップ時の位置で行う)。
/// - 非 Web: recognizer は context を持たないので、常に生きているルート
///   Navigator の context ([app_navigator.dart]) を渡す。ナローでは結局
///   フルスクリーン遷移になるので実害なし。
InlineSpan _tappableSpan({
  required String text,
  required TextStyle style,
  required void Function(BuildContext context) onTap,
}) {
  if (!kIsWeb) {
    return TextSpan(
      text: text,
      style: style,
      // Web/デスクトップでホバー時にクリック可能カーソル (手) を出す。
      mouseCursor: SystemMouseCursors.click,
      recognizer: TapGestureRecognizer()
        ..onTap = () {
          final ctx = appNavigatorKey.currentContext;
          if (ctx != null) onTap(ctx);
        },
    );
  }
  return WidgetSpan(
    alignment: PlaceholderAlignment.baseline,
    baseline: TextBaseline.alphabetic,
    child: Builder(
      builder: (context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap(context),
          child: Text(
            text,
            style: style,
            // 周囲の本文 (CollapsibleText) と同じく非スケーリング。
            textScaler: TextScaler.noScaling,
          ),
        ),
      ),
    ),
  );
}

InlineSpan _buildUrlSpan(String url, String displayText, _Ctx ctx) {
  return _tappableSpan(
    text: displayText.isEmpty ? shortenUrl(url) : displayText,
    style: ctx.currentStyle.copyWith(color: ctx.linkColor),
    onTap: (_) async {
      try {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } catch (e) {
        debugPrint('Could not launch $url: $e');
      }
    },
  );
}

InlineSpan _buildHashtagSpan(String tag, String displayText, _Ctx ctx) {
  return _tappableSpan(
    text: displayText.isEmpty ? '#$tag' : displayText,
    style: ctx.currentStyle.copyWith(
      color: ctx.linkColor,
      fontWeight: FontWeight.w600,
    ),
    onTap: (context) => _navigateToHashtag(context, tag),
  );
}

InlineSpan _buildMentionSpan(String displayText, String href, _Ctx ctx) {
  // displayText 例: "@user" or "@user@instance"
  final m = _mentionRegex.firstMatch(displayText);
  String? username = m?.group(1);
  String? instance = m?.group(2);
  // href から domain を補完できる場合 (`https://example.com/@user`)
  if (instance == null && href.isNotEmpty) {
    final uri = Uri.tryParse(href);
    if (uri != null && uri.host.isNotEmpty) {
      instance = uri.host;
    }
  }
  return _tappableSpan(
    text: displayText,
    style: ctx.currentStyle.copyWith(
      color: ctx.linkColor,
      fontWeight: FontWeight.w600,
    ),
    onTap: (context) {
      if (username != null) _navigateToProfile(context, username, instance);
    },
  );
}

// ============================================================
// ブロック要素 (blockquote, pre) を WidgetSpan で囲む
// ============================================================

InlineSpan _buildBlockquoteSpan(List<InlineSpan> innerSpans, _Ctx ctx) {
  final barColor =
      (ctx.baseStyle.color ?? const Color(0xFF888888)).withValues(alpha: 0.45);
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(width: 3, color: barColor)),
      ),
      child: Text.rich(
        TextSpan(
          children: _trimEdgeNewlines(List.of(innerSpans)),
          style: ctx.baseStyle,
        ),
      ),
    ),
  );
}

InlineSpan _buildPreSpan(List<InlineSpan> innerSpans, _Ctx ctx) {
  final bg =
      (ctx.baseStyle.color ?? const Color(0xFF888888)).withValues(alpha: 0.08);
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text.rich(
        TextSpan(
          children: _trimEdgeNewlines(List.of(innerSpans)),
          style: ctx.baseStyle.copyWith(fontFamily: _monospaceFamily),
        ),
      ),
    ),
  );
}

// ============================================================
// リスト (<ul>/<ol>/<li>)
// ============================================================

List<InlineSpan> _processList(dom.Element list, _Ctx ctx,
    {required bool ordered}) {
  final out = <InlineSpan>[];
  int idx = 1;
  for (final node in list.nodes) {
    if (node is! dom.Element) continue;
    if (node.localName?.toLowerCase() != 'li') continue;
    final marker = ordered ? '$idx. ' : '• ';
    out.add(TextSpan(text: marker, style: ctx.currentStyle));
    final inner = _walkNodes(node.nodes, ctx);
    out.addAll(_trimEdgeNewlines(inner));
    out.add(TextSpan(text: '\n', style: ctx.currentStyle));
    idx++;
  }
  return out;
}

// ============================================================
// 末尾の改行を整理 (連続する <p> や <br> で出る余分な \n を畳む)
// ============================================================

List<InlineSpan> _trimEdgeNewlines(List<InlineSpan> spans) {
  while (spans.isNotEmpty) {
    final last = spans.last;
    if (last is TextSpan &&
        (last.text == null ||
            last.text!.isEmpty ||
            RegExp(r'^\n+$').hasMatch(last.text!))) {
      spans.removeLast();
    } else {
      break;
    }
  }
  return spans;
}

// ============================================================
// Helpers (URL から hashtag 抽出 / URL 短縮 / 遷移 / regex match)
// ============================================================

enum _MatchType { emoji, url, hashtag, mention }

class _Match {
  final RegExpMatch match;
  final _MatchType type;
  _Match(this.match, this.type);
}

void _navigateToHashtag(BuildContext context, String hashtag) {
  // ワイドはホームに重ねる Deck ポップアップ、ナローはフルスクリーン push。
  // ポップアップ内なら nested Navigator に push される ([openDeckPage] 参照)。
  openDeckPage(
    context,
    (onDeckBack) => HashtagPage(hashtag: hashtag, onDeckBack: onDeckBack),
  );
}

/// プロフィールページに遷移 (メンション用)。`current` 概念を廃止したので
/// 操作主体は `accounts.first` をフォールバックとして使う。理想的には
/// 「この status を表示しているアカウント」を渡したいが、`html_parser` は
/// status 文脈を持たないので静的に解決できない。リモートメンションは
/// instance 指定で targetInstanceUrl が決まるためフォールバックで実害なし。
void _navigateToProfile(
    BuildContext context, String username, String? instance) {
  final container = ProviderScope.containerOf(context);
  final auth = container.read(authProvider);
  if (auth.accounts.isEmpty) {
    debugPrint('No accounts available');
    return;
  }
  final operatingUser = auth.accounts.first;
  String? userInstanceUrl;
  if (instance != null) {
    userInstanceUrl = 'https://$instance';
  } else {
    userInstanceUrl = operatingUser.instanceUrl;
  }
  openProfile(
    context,
    user: operatingUser,
    targetAccountId: null,
    targetUsername: username,
    targetInstanceUrl: userInstanceUrl,
  );
}
