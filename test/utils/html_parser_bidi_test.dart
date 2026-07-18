// parseContentWithEmojis の双方向 (bidi) アイソレートのテスト。
//
// 表示名モード (enableInlineLinks=false) では、表示名を Unicode 双方向
// アイソレート (FSI … PDI) で囲む。これは Mastodon Web の `<bdi>` と同じく、
// 表示名に含まれる `U+202E RIGHT-TO-LEFT OVERRIDE` 等の効果を名前の枠内に
// 閉じ込め、後続の `@ハンドル` や数字へ漏れないようにするためのもの。
// 名前自身の制御文字は **除去しない** (意図された見た目を保つ) 点に注意。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/utils/html_parser.dart';

String _plainText(List<InlineSpan> spans) {
  final buf = StringBuffer();
  for (final s in spans) {
    if (s is TextSpan && s.text != null) buf.write(s.text);
  }
  return buf.toString();
}

void main() {
  // ソースに不可視文字を埋め込まないよう fromCharCode で生成する。
  final rlo = String.fromCharCode(0x202E); // RIGHT-TO-LEFT OVERRIDE
  final fsi = String.fromCharCode(0x2068); // FIRST STRONG ISOLATE
  final pdi = String.fromCharCode(0x2069); // POP DIRECTIONAL ISOLATE

  List<InlineSpan> parseName(String html) => parseContentWithEmojis(
        contentHtml: html,
        emojis: const [],
        baseStyle: const TextStyle(),
        linkColor: const Color(0xFF000000),
        emojiSize: 16,
        enableInlineLinks: false,
      );

  test('表示名モードは FSI … PDI で囲む', () {
    final text = _plainText(parseName('なゆも c＾ω＾っ'));
    expect(text.startsWith(fsi), isTrue, reason: 'FSI で始まること');
    expect(text.endsWith(pdi), isTrue, reason: 'PDI で終わること');
    // 中身は元のまま
    expect(text, '$fsiなゆも c＾ω＾っ$pdi');
  });

  test('RLO は除去せずそのまま保持する (見た目を変えない)', () {
    final text = _plainText(parseName('なゆも ${rlo}c＾ω＾っ'));
    expect(text.contains(rlo), isTrue, reason: 'RLO を消してはいけない');
    // FSI の直後に元の文字列、末尾に PDI。
    expect(text, '$fsiなゆも ${rlo}c＾ω＾っ$pdi');
  });

  test('本文モード (enableInlineLinks=true) はアイソレートしない', () {
    final spans = parseContentWithEmojis(
      contentHtml: 'abc',
      emojis: const [],
      baseStyle: const TextStyle(),
      linkColor: const Color(0xFF000000),
      emojiSize: 16,
      enableInlineLinks: true,
    );
    final text = _plainText(spans);
    expect(text.contains(fsi), isFalse);
    expect(text.contains(pdi), isFalse);
  });

  test('空の表示名はアイソレートで囲まない (空 span を増やさない)', () {
    final text = _plainText(parseName(''));
    expect(text.contains(fsi), isFalse);
    expect(text.contains(pdi), isFalse);
  });
}
