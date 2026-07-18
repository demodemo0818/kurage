// lib/utils/app_fonts.dart
//
// ユーザー選択フォント (google_fonts 実行時取得) の厳選レジストリ。
//
// 型付きメソッド (GoogleFonts.notoSansJp() 等) を各エントリの closure 内で
// 固定参照することで、未使用書体が tree-shake され配布サイズ増を最小化する
// (動的 GoogleFonts.getFont(name) だと目録全体が残り +~1MB)。フォント本体は
// バンドルせず、初回使用時に Google CDN から取得 → 端末キャッシュに保存
// (2 回目以降はキャッシュ = オフライン可)。
//
// kAppFonts の並びは設定ピッカーの表示順にそのまま反映される。永続化は
// `AppFont.key` (google_fonts のファミリ名) を Settings.fontFamily に保存。
// 並び替えても保存済みの選択値には影響しない。

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// 選択可能な 1 書体。
class AppFont {
  /// 永続化キー兼 google_fonts のファミリ名 (Settings.fontFamily に保存)。
  final String key;

  /// 設定画面の表示ラベル。
  final String label;

  /// この書体が日本語 (CJK) 字形を内包するか。true なら選択時に Noto Sans JP
  /// フォールバックを足さなくても漢字が JP 字形で出る (= 余計な DL を避けられる)。
  /// 厳選リストは現状すべて日本語書体なので true。Latin 専用書体を足す時は
  /// false にして、CJK だけ Noto Sans JP フォールバックに任せる。
  final bool coversJapanese;

  final String? Function() _ensure;

  const AppFont({
    required this.key,
    required this.label,
    required this.coversJapanese,
    required String? Function() ensure,
  }) : _ensure = ensure;

  /// google_fonts の実行時取得をトリガし、解決済みの fontFamily を返す。
  /// 通常 (w400) と太字 (w700) の両方を登録して CJK 太字も同書体で出るように
  /// する (単一ウェイト書体は w400 のみ)。fontFamily は weight に依らず同じ。
  String? ensureLoadedFamily() => _ensure();
}

/// 厳選フォント一覧 (端末デフォルト = null は含まない。UI 側で別途先頭に出す)。
final List<AppFont> kAppFonts = [
  AppFont(
    key: 'Noto Sans JP',
    label: 'Noto Sans JP（ゴシック）',
    coversJapanese: true,
    ensure: () {
      final f = GoogleFonts.notoSansJp().fontFamily;
      GoogleFonts.notoSansJp(fontWeight: FontWeight.w700);
      return f;
    },
  ),
  AppFont(
    key: 'Noto Serif JP',
    label: 'Noto Serif JP（明朝）',
    coversJapanese: true,
    ensure: () {
      final f = GoogleFonts.notoSerifJp().fontFamily;
      GoogleFonts.notoSerifJp(fontWeight: FontWeight.w700);
      return f;
    },
  ),
  AppFont(
    key: 'M PLUS Rounded 1c',
    label: 'M PLUS Rounded 1c（丸ゴシック）',
    coversJapanese: true,
    ensure: () {
      final f = GoogleFonts.mPlusRounded1c().fontFamily;
      GoogleFonts.mPlusRounded1c(fontWeight: FontWeight.w700);
      return f;
    },
  ),
  AppFont(
    key: 'Zen Kaku Gothic New',
    label: 'Zen Kaku Gothic New（ゴシック）',
    coversJapanese: true,
    ensure: () {
      final f = GoogleFonts.zenKakuGothicNew().fontFamily;
      GoogleFonts.zenKakuGothicNew(fontWeight: FontWeight.w700);
      return f;
    },
  ),
  AppFont(
    key: 'Zen Maru Gothic',
    label: 'Zen Maru Gothic（丸ゴシック）',
    coversJapanese: true,
    ensure: () {
      final f = GoogleFonts.zenMaruGothic().fontFamily;
      GoogleFonts.zenMaruGothic(fontWeight: FontWeight.w700);
      return f;
    },
  ),
  AppFont(
    key: 'BIZ UDPGothic',
    label: 'BIZ UDPGothic（UD ゴシック）',
    coversJapanese: true,
    ensure: () {
      final f = GoogleFonts.bizUDPGothic().fontFamily;
      GoogleFonts.bizUDPGothic(fontWeight: FontWeight.w700);
      return f;
    },
  ),
  AppFont(
    key: 'Kosugi Maru',
    label: 'Kosugi Maru（丸ゴシック）',
    coversJapanese: true,
    ensure: () {
      // Kosugi Maru は w400 単一ウェイト。太字は engine の faux bold に任せる。
      return GoogleFonts.kosugiMaru().fontFamily;
    },
  ),
];

/// 保存済みキーから AppFont を引く。未知のキー (将来削除された書体等) は null。
AppFont? appFontByKey(String? key) {
  if (key == null) return null;
  for (final f in kAppFonts) {
    if (f.key == key) return f;
  }
  return null;
}
