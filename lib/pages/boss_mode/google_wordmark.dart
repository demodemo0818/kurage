// lib/pages/boss_mode/google_wordmark.dart

import 'package:flutter/material.dart';

/// 「Google」ワードマークを 4 色 (青赤黄青緑赤) の TextSpan で近似する。
///
/// 公式ロゴ画像はリポジトリに同梱しない (商標回避 + 解像度非依存)。Product Sans
/// 風に見えるよう素直な sans フォントへフォールバックさせる。
class GoogleWordmark extends StatelessWidget {
  const GoogleWordmark({super.key, this.fontSize = 88});

  final double fontSize;

  static const Color _blue = Color(0xFF4285F4);
  static const Color _red = Color(0xFFEA4335);
  static const Color _yellow = Color(0xFFFBBC05);
  static const Color _green = Color(0xFF34A853);

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      letterSpacing: -1.0,
      // Product Sans 風。アプリ側の選択フォント (明朝等) が透けないよう明示。
      fontFamily: 'Arial',
      fontFamilyFallback: const ['Helvetica', 'Roboto', 'sans-serif'],
      height: 1.0,
    );
    TextSpan c(String s, Color color) =>
        TextSpan(text: s, style: base.copyWith(color: color));

    return Text.rich(
      TextSpan(children: [
        c('G', _blue),
        c('o', _red),
        c('o', _yellow),
        c('g', _blue),
        c('l', _green),
        c('e', _red),
      ]),
      textAlign: TextAlign.center,
    );
  }
}
