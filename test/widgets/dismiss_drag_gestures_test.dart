import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/pages/full_screen_image_page.dart';

/// 画像ビューアの「下スワイプで閉じる」認識器と、InteractiveViewer (ピンチ /
/// パン) の競合を、ビューアと同じ入れ子構造で再現する。
void main() {
  late int dismissEnded;

  setUp(() => dismissEnded = 0);

  Future<void> pumpViewer(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => PageView(
            children: [
              RawGestureDetector(
                gestures: dismissDragGestures(
                  context,
                  onStart: (_) {},
                  onUpdate: (_) {},
                  onEnd: (_) => dismissEnded++,
                ),
                child: GestureDetector(
                  onDoubleTap: () {},
                  child: InteractiveViewer(
                    maxScale: 5.0,
                    boundaryMargin: const EdgeInsets.all(20),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Android 相当: エンジンが端末の touch slop (8dp) を渡してくる状態。
  void useAndroidTouchSlop(WidgetTester tester) {
    tester.view.gestureSettings = ui.GestureSettings(
      physicalTouchSlop: 8 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.reset);
  }

  Future<void> swipeDown(TestGesture gesture, WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, 5));
      await tester.pump(const Duration(milliseconds: 8));
    }
  }

  testWidgets('Android の touch slop でも下スワイプが InteractiveViewer のパンに負けない',
      (tester) async {
    useAndroidTouchSlop(tester);
    await pumpViewer(tester);

    final gesture = await tester.startGesture(const Offset(400, 300));
    await swipeDown(gesture, tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissEnded, 1);
  });

  testWidgets('touch slop 未提供 (iOS / Web / デスクトップ) でも下スワイプで閉じる',
      (tester) async {
    await pumpViewer(tester);

    final gesture = await tester.startGesture(const Offset(400, 300));
    await swipeDown(gesture, tester);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(dismissEnded, 1);
  });

  testWidgets('片方の指を止めたピンチは閉じる操作にならない', (tester) async {
    useAndroidTouchSlop(tester);
    await pumpViewer(tester);

    final still = await tester.startGesture(const Offset(400, 200), pointer: 1);
    await tester.pump(const Duration(milliseconds: 8));
    final moving = await tester.startGesture(const Offset(400, 300), pointer: 2);
    await swipeDown(moving, tester);
    await moving.up();
    await still.up();
    await tester.pumpAndSettle();

    expect(dismissEnded, 0);
  });
}
