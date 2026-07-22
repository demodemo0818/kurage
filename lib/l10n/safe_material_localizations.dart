// lib/l10n/safe_material_localizations.dart
//
// 日付ピッカー入力パースの例外を安全化した MaterialLocalizations。
//
// flutter_localizations の GlobalMaterialLocalizations.parseCompactDate は
// FormatException しか catch していないため、日付入力欄の「日」部分が巨大に
// なる入力 (例: "2026/7/21" の後ろに数字を 7 桁追記 → 日 = 210000000 で
// DateTime の表現範囲 (epoch から 1 億日) を超える) で、intl 内部の DateTime
// 生成が投げる ArgumentError が素通りする。日付ピッカーは一度 OK を押して
// バリデーションに失敗すると autovalidate になり、以降は毎キーストロークの
// build 中に parse が走るため、この例外が build に漏れて入力欄が ErrorWidget
// に置き換わる (release ではグレーの矩形、debug では赤いエラー表示)。
// upstream: https://github.com/flutter/flutter/issues/126397 (Flutter 3.41
// 時点で flutter_localizations 側は未修正)。
//
// 対策として、アプリがサポートする ja / en の MaterialLocalizations を
// 「parseCompactDate が ArgumentError もパース失敗 (null) に丸める」
// サブクラスに差し替える。main.dart の localizationsDelegates で
// AppLocalizations.localizationsDelegates より前に置くこと (先勝ち)。

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

class SafeMaterialLocalizationJa extends MaterialLocalizationJa {
  const SafeMaterialLocalizationJa({
    required super.fullYearFormat,
    required super.compactDateFormat,
    required super.shortDateFormat,
    required super.mediumDateFormat,
    required super.longDateFormat,
    required super.yearMonthFormat,
    required super.shortMonthDayFormat,
    required super.decimalFormat,
    required super.twoDigitZeroPaddedFormat,
  });

  @override
  DateTime? parseCompactDate(String? inputString) {
    try {
      return super.parseCompactDate(inputString);
    } on ArgumentError {
      return null;
    }
  }
}

class SafeMaterialLocalizationEn extends MaterialLocalizationEn {
  const SafeMaterialLocalizationEn({
    required super.fullYearFormat,
    required super.compactDateFormat,
    required super.shortDateFormat,
    required super.mediumDateFormat,
    required super.longDateFormat,
    required super.yearMonthFormat,
    required super.shortMonthDayFormat,
    required super.decimalFormat,
    required super.twoDigitZeroPaddedFormat,
  });

  @override
  DateTime? parseCompactDate(String? inputString) {
    try {
      return super.parseCompactDate(inputString);
    } on ArgumentError {
      return null;
    }
  }
}

/// ja / en の [MaterialLocalizations] を安全化サブクラスで提供するデリゲート。
/// 対応外ロケールは isSupported = false を返し、後続の
/// GlobalMaterialLocalizations.delegate にフォールバックする。
class SafeMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const SafeMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) =>
      locale.languageCode == 'ja' || locale.languageCode == 'en';

  @override
  Future<MaterialLocalizations> load(Locale locale) {
    // intl のロケールデータ (日付記号・数値パターン) の読み込みは本家
    // デリゲートの load に任せ、その後で同じ構成のフォーマットを組み立てて
    // 安全化サブクラスに渡す (本家インスタンスのフォーマットは private で
    // 取り出せないため再構築する)。
    //
    // 本家 load は SynchronousFuture を返し、その then は同期実行されるため、
    // この load 全体も同期に完了する (async にすると実 Future になり、最初の
    // フレームがロケール未ロードで空になる)。
    return GlobalMaterialLocalizations.delegate
        .load(locale)
        .then((_) => _build(locale));
  }

  MaterialLocalizations _build(Locale locale) {
    final localeName = intl.Intl.canonicalizedLocale(locale.toString());
    final fullYearFormat = intl.DateFormat.y(localeName);
    final compactDateFormat = intl.DateFormat.yMd(localeName);
    final shortDateFormat = intl.DateFormat.yMMMd(localeName);
    final mediumDateFormat = intl.DateFormat.MMMEd(localeName);
    final longDateFormat = intl.DateFormat.yMMMMEEEEd(localeName);
    final yearMonthFormat = intl.DateFormat.yMMMM(localeName);
    final shortMonthDayFormat = intl.DateFormat.MMMd(localeName);
    final decimalFormat = intl.NumberFormat.decimalPattern(localeName);
    final twoDigitZeroPaddedFormat = intl.NumberFormat('00', localeName);

    if (locale.languageCode == 'ja') {
      return SafeMaterialLocalizationJa(
        fullYearFormat: fullYearFormat,
        compactDateFormat: compactDateFormat,
        shortDateFormat: shortDateFormat,
        mediumDateFormat: mediumDateFormat,
        longDateFormat: longDateFormat,
        yearMonthFormat: yearMonthFormat,
        shortMonthDayFormat: shortMonthDayFormat,
        decimalFormat: decimalFormat,
        twoDigitZeroPaddedFormat: twoDigitZeroPaddedFormat,
      );
    }
    return SafeMaterialLocalizationEn(
      fullYearFormat: fullYearFormat,
      compactDateFormat: compactDateFormat,
      shortDateFormat: shortDateFormat,
      mediumDateFormat: mediumDateFormat,
      longDateFormat: longDateFormat,
      yearMonthFormat: yearMonthFormat,
      shortMonthDayFormat: shortMonthDayFormat,
      decimalFormat: decimalFormat,
      twoDigitZeroPaddedFormat: twoDigitZeroPaddedFormat,
    );
  }

  @override
  bool shouldReload(SafeMaterialLocalizationsDelegate old) => false;
}
