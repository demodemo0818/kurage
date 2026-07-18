// 時刻フォーマッタのテスト。
//
// `formatRelative` は `DateTime.now()` を内部参照するため、テストでは
// 「現在からの相対オフセット」で入力 DateTime を作って、出力の単位ラベル
// (秒前 / 分前 / 時間前 / 日前 / か月前 / 年前) と数字を検証する。

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/utils/time_formatter.dart';

void main() {
  group('formatRelative', () {
    test('60 秒未満は "秒前"', () {
      final dt = DateTime.now().subtract(const Duration(seconds: 30));
      expect(formatRelative(dt), endsWith('秒前'));
    });

    test('60 分未満は "分前"', () {
      final dt = DateTime.now().subtract(const Duration(minutes: 15));
      expect(formatRelative(dt), '15分前');
    });

    test('24 時間未満は "時間前"', () {
      final dt = DateTime.now().subtract(const Duration(hours: 5));
      expect(formatRelative(dt), '5時間前');
    });

    test('30 日未満は "日前"', () {
      final dt = DateTime.now().subtract(const Duration(days: 10));
      expect(formatRelative(dt), '10日前');
    });

    test('12 か月未満は "か月前"', () {
      final dt = DateTime.now().subtract(const Duration(days: 60));
      expect(formatRelative(dt), endsWith('か月前'));
    });

    test('1 年以上は "年前"', () {
      final dt = DateTime.now().subtract(const Duration(days: 800));
      expect(formatRelative(dt), endsWith('年前'));
    });
  });

  group('formatAbsolute', () {
    test('yyyy/MM/dd HH:mm 形式 (ローカルタイムゾーン)', () {
      final dt = DateTime.utc(2026, 5, 24, 3, 45);
      // toLocal() が掛かるためタイムゾーン依存。形式だけ検証。
      expect(formatAbsolute(dt), matches(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$'));
    });
  });

  group('formatTime', () {
    test('24 時間以内 → 相対時間', () {
      final dt = DateTime.now().subtract(const Duration(hours: 2));
      expect(formatTime(dt), '2時間前');
    });

    test('24 時間以上 → 絶対時間 (yyyy/MM/dd HH:mm)', () {
      final dt = DateTime.now().subtract(const Duration(days: 2));
      expect(formatTime(dt), matches(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$'));
    });
  });

  group('TimeText (auto-updating widget)', () {
    testWidgets('useRelative=true で formatRelative の出力を表示', (tester) async {
      final dt = DateTime.now().subtract(const Duration(minutes: 3));
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: TimeText(dt: dt, useRelative: true),
      ));
      expect(find.text('3分前'), findsOneWidget);
    });

    testWidgets('useRelative=false で絶対時刻フォーマットを表示', (tester) async {
      final dt = DateTime.now().subtract(const Duration(days: 2));
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: TimeText(dt: dt, useRelative: false),
      ));
      // yyyy/MM/dd HH:mm 形式
      expect(
        find.byWidgetPredicate((w) =>
            w is Text &&
            w.data != null &&
            RegExp(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$').hasMatch(w.data!)),
        findsOneWidget,
      );
    });
  });
}
