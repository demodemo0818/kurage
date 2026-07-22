// SafeMaterialLocalizationsDelegate のテスト。
//
// flutter_localizations の parseCompactDate は FormatException しか catch
// せず、日付ピッカー入力の「日」が DateTime の表現範囲を超える巨大数字
// (例: "2026/7/210000000") だと ArgumentError が素通りする
// (flutter/flutter#126397)。ピッカーの autovalidate 中は build 内で parse が
// 走るため、素通りすると入力欄が ErrorWidget (release ではグレーの矩形) に
// 置き換わる。安全化デリゲートが null (= パース失敗扱い) に丸めることを固定する。

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/l10n/safe_material_localizations.dart';

Future<MaterialLocalizations> _loadFor(WidgetTester tester, Locale locale) async {
  late MaterialLocalizations loc;
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: const [
      SafeMaterialLocalizationsDelegate(),
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: const [Locale('ja'), Locale('en')],
    home: Builder(
      builder: (context) {
        loc = MaterialLocalizations.of(context);
        return const SizedBox.shrink();
      },
    ),
  ));
  return loc;
}

void main() {
  testWidgets('ja: 安全化サブクラスが選ばれ、正常な日付はパースできる',
      (tester) async {
    final loc = await _loadFor(tester, const Locale('ja'));
    expect(loc, isA<SafeMaterialLocalizationJa>());
    expect(loc.parseCompactDate('2026/7/22'), DateTime(2026, 7, 22));
    // 通常の不正入力は従来どおり null (FormatException 経路)
    expect(loc.parseCompactDate('2026072'), isNull);
  });

  testWidgets('ja: 日が DateTime 範囲外の巨大数字でも throw せず null',
      (tester) async {
    final loc = await _loadFor(tester, const Locale('ja'));
    // 素の GlobalMaterialLocalizations では ArgumentError になる入力
    expect(loc.parseCompactDate('2026/7/210000000'), isNull);
  });

  testWidgets('en: 安全化サブクラスが選ばれ、同様に安全', (tester) async {
    final loc = await _loadFor(tester, const Locale('en'));
    expect(loc, isA<SafeMaterialLocalizationEn>());
    expect(loc.parseCompactDate('7/22/2026'), DateTime(2026, 7, 22));
    expect(loc.parseCompactDate('7/210000000/2026'), isNull);
  });
}
