import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/services/stale_modifier_key_guard.dart';

/// Windows エンジンが extended フラグ誤報時に作る非標準の物理キー
/// (Windows プレーン | 右 Shift のスキャンコード 0x36)。flutter/flutter#181907。
const _nonStandardShiftRight = PhysicalKeyboardKey(0x1600000036);
const _nonStandardControl = PhysicalKeyboardKey(0x160000001d);

void _down(PhysicalKeyboardKey physical, LogicalKeyboardKey logical) {
  HardwareKeyboard.instance.handleKeyEvent(
    KeyDownEvent(
      physicalKey: physical,
      logicalKey: logical,
      timeStamp: Duration.zero,
    ),
  );
}

void _up(PhysicalKeyboardKey physical, LogicalKeyboardKey logical) {
  HardwareKeyboard.instance.handleKeyEvent(
    KeyUpEvent(
      physicalKey: physical,
      logicalKey: logical,
      timeStamp: Duration.zero,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('releaseStaleModifiers', () {
    test('標準の Shift が離されているのに非標準の物理キーで残った Shift を解除する', () {
      _down(_nonStandardShiftRight, LogicalKeyboardKey.shiftRight);
      expect(HardwareKeyboard.instance.isShiftPressed, isTrue);

      expect(
        StaleModifierKeyGuard.releaseStaleModifiers(Duration.zero),
        isTrue,
      );

      expect(HardwareKeyboard.instance.isShiftPressed, isFalse);
      expect(HardwareKeyboard.instance.physicalKeysPressed, isEmpty);
    });

    test('Ctrl も同じ条件で解除する', () {
      _down(_nonStandardControl, LogicalKeyboardKey.controlLeft);

      expect(
        StaleModifierKeyGuard.releaseStaleModifiers(Duration.zero),
        isTrue,
      );

      expect(HardwareKeyboard.instance.isControlPressed, isFalse);
    });

    test('標準の Shift が押下中 (= OS 上も押されている) なら触らない', () {
      _down(_nonStandardShiftRight, LogicalKeyboardKey.shiftRight);
      _down(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft);

      expect(
        StaleModifierKeyGuard.releaseStaleModifiers(Duration.zero),
        isFalse,
      );
      expect(
        HardwareKeyboard.instance.physicalKeysPressed,
        contains(_nonStandardShiftRight),
      );

      _up(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft);
      _up(_nonStandardShiftRight, LogicalKeyboardKey.shiftRight);
    });

    test('修飾キー以外の押下中キーには触らない', () {
      _down(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA);

      expect(
        StaleModifierKeyGuard.releaseStaleModifiers(Duration.zero),
        isFalse,
      );
      expect(
        HardwareKeyboard.instance.physicalKeysPressed,
        contains(PhysicalKeyboardKey.keyA),
      );

      _up(PhysicalKeyboardKey.keyA, LogicalKeyboardKey.keyA);
    });
  });

  testWidgets('Shift が取り残されても、マウスを動かせばホイールが縦スクロールに戻る', (tester) async {
    StaleModifierKeyGuard.install();
    final horizontal = ScrollController();
    final vertical = ScrollController();
    addTearDown(horizontal.dispose);
    addTearDown(vertical.dispose);

    // Deck と同じ「横スクロールの中に縦スクロールのカラム」構成。
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(
          controller: horizontal,
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 500,
                height: 600,
                child: ListView.builder(
                  controller: vertical,
                  itemCount: 100,
                  itemBuilder:
                      (_, i) => SizedBox(height: 50, child: Text('$i')),
                ),
              ),
              const SizedBox(width: 1000, height: 600),
            ],
          ),
        ),
      ),
    );

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    const center = Offset(250, 300);
    await tester.sendEventToBinding(pointer.hover(center));

    // 取り残された Shift があると、縦ホイールが横スクロールになる (issue #7 の症状)。
    _down(_nonStandardShiftRight, LogicalKeyboardKey.shiftRight);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pump();
    expect(horizontal.offset, greaterThan(0));
    expect(vertical.offset, 0);
    horizontal.jumpTo(0);

    // マウスを動かすとガードが解除し、以降のホイールは縦に効く。
    await tester.sendEventToBinding(pointer.hover(center));
    expect(HardwareKeyboard.instance.isShiftPressed, isFalse);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await tester.pump();
    expect(vertical.offset, greaterThan(0));
    expect(horizontal.offset, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
