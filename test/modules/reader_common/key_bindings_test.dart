import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/reader_common/mixins/reader_gestures.dart';
import 'package:mangayomi/modules/reader_common/key_bindings.dart';

void main() {
  const ctrlB = KeyCombo(LogicalKeyboardKey.keyB, control: true);

  test('only the changed keys are saved, and read back', () {
    expect(encodeKeyBindings(defaultKeyBindings), isEmpty);
    final saved = encodeKeyBindings({
      ...defaultKeyBindings,
      ReaderShortcut.nextChapter: [ctrlB],
    });
    expect(saved, ['reader.nextChapter=c+${LogicalKeyboardKey.keyB.keyId}']);
    final read = resolveKeyBindings([
      ...saved,
      'player.mute=c+${LogicalKeyboardKey.keyB.keyId}',
      'garbage',
      'reader.nope=1',
    ]);
    expect(read[ReaderShortcut.nextChapter], [ctrlB]);
    expect(read[ReaderShortcut.toggleBars], [
      const KeyCombo(LogicalKeyboardKey.keyM),
    ]);
    expect(read.keys, everyElement(isA<ReaderShortcut>()));
  });

  testWidgets('the reader follows a rebound key', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderKeyboardHandler(
          onNextChapter: () => calls.add('next chapter'),
          bindings: {
            ...defaultKeyBindings,
            ReaderShortcut.nextChapter: [ctrlB],
          },
        ).wrapWithKeyboardListener(child: const SizedBox.expand()),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    expect(calls, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(calls, ['next chapter']);
  });

  test('reader shortcut labels preserve default key hints', () {
    final labels = readerShortcutKeys().map((entry) => entry.$2).toList();
    expect(labels.first, ['←', '↑', '⇧ Space']);
  });
}
