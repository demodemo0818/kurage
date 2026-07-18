// lib/l10n/l10n.dart
//
// アプリ全体の l10n アクセスポイント。
//
// - Widget 内: `context.l10n.foo` (拡張メソッド) が基本。
// - BuildContext が無い層 (services / 例外メッセージ / バックグラウンド通知):
//   トップレベル変数 `l10n` を使う。MyApp が locale 決定時に
//   `updateGlobalL10n` で同期するので、常に「現在の表示言語」を指す。
//   バックグラウンド isolate (FCM ハンドラ等) は widget tree が無いので
//   `updateGlobalL10nFromPrefs()` で保存済み設定から初期化すること。
//
// 新規文言は lib/l10n/app_ja.arb と app_en.arb の両方へ同時に追加する
// (CI が未翻訳キーを検出して fail する)。生成物 (lib/l10n/gen/) は
// git 管理外で、`flutter pub get` / `flutter gen-l10n` で再生成される。

import 'dart:convert';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gen/app_localizations.dart';

export 'gen/app_localizations.dart';

/// 現在の表示言語の [AppLocalizations]。BuildContext が無い場所からの参照用。
///
/// 既定は日本語 (テスト等で更新前に参照されても安全なように)。実行時は
/// MyApp.build が locale 決定のたびに [updateGlobalL10n] で差し替える。
AppLocalizations l10n = lookupAppLocalizations(const Locale('ja'));

/// グローバル [l10n] を指定 locale の実装に差し替える。
void updateGlobalL10n(Locale locale) {
  l10n = lookupAppLocalizations(locale);
}

/// 設定値 ('system' / 'ja' / 'en') を実際の [Locale] に解決する。
///
/// 'system' は端末ロケールに追従し、非対応言語は英語にフォールバックする
/// (海外ユーザー向けアプリとしての既定)。
Locale resolveAppLocale(String appLocale) {
  switch (appLocale) {
    case 'ja':
      return const Locale('ja');
    case 'en':
      return const Locale('en');
  }
  final system = PlatformDispatcher.instance.locale;
  for (final supported in AppLocalizations.supportedLocales) {
    if (supported.languageCode == system.languageCode) {
      return Locale(supported.languageCode);
    }
  }
  return const Locale('en');
}

/// バックグラウンド isolate (FCM ハンドラ等、widget tree の無い環境) 用:
/// SharedPreferences の保存済み設定からグローバル [l10n] を初期化する。
///
/// settingsProvider の非同期ロードを待てない場面で使うため、
/// `appearanceSettings` JSON を直接読む (AppLockService.shouldStartLocked と
/// 同じパターン)。
Future<void> updateGlobalL10nFromPrefs() async {
  var appLocale = 'system';
  try {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('appearanceSettings');
    if (jsonStr != null) {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      appLocale = map['appLocale'] as String? ?? 'system';
    }
  } catch (_) {
    // 破損 JSON 等は既定 (system) で続行
  }
  updateGlobalL10n(resolveAppLocale(appLocale));
}

/// `context.l10n.foo` と書けるようにする糖衣。
extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
