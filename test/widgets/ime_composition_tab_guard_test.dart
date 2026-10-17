import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kurage/widgets/ime_composition_tab_guard.dart';

void main() {
  late TextEditingController controller;
  late FocusNode fieldFocus;
  late FocusNode buttonFocus;
  late int pressed;

  setUp(() {
    controller = TextEditingController();
    fieldFocus = FocusNode();
    buttonFocus = FocusNode();
    pressed = 0;
  });

  tearDown(() {
    controller.dispose();
    fieldFocus.dispose();
    buttonFocus.dispose();
  });

  // 投稿画面と同じく「本文 TextField の次に投稿ボタン」の並び。
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            ImeCompositionTabGuard(enabled: true, child: child!),
        home: Scaffold(
          body: Column(
            children: [
              TextField(controller: controller, focusNode: fieldFocus),
              ElevatedButton(
                focusNode: buttonFocus,
                onPressed: () => pressed++,
                child: const Text('post'),
              ),
            ],
          ),
        ),
      ),
    );
    fieldFocus.requestFocus();
    await tester.pump();
  }

  testWidgets('変換中の Tab ではフォーカスが移らず、続く Enter でボタンが押されない',
      (tester) async {
    await pumpApp(tester);
    controller.value = const TextEditingValue(
      text: 'あいう',
      selection: TextSelection.collapsed(offset: 3),
      composing: TextRange(start: 0, end: 3),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(fieldFocus.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(pressed, 0);
  });

  testWidgets('変換していなければ Tab で従来どおり次へフォーカスが移る', (tester) async {
    await pumpApp(tester);
    controller.value = const TextEditingValue(
      text: 'abc',
      selection: TextSelection.collapsed(offset: 3),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(buttonFocus.hasPrimaryFocus, isTrue);
  });
}
