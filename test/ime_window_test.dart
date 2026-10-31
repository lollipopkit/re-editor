import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

/// What an input method is given, and what its edits do to the code.
///
/// It used to hold the selected line alone, so its select all selected that
/// line and its cursor keys could not leave it.
void main() {
  // Android puts a prefix in front of the text: a backspace at its start has
  // to reach the editor. `kIsAndroid` is read once, so every test is Android.
  final android = TargetPlatformVariant.only(TargetPlatform.android);

  void testIme(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      await body(tester);
      // The cursor is shown 100ms after focus on a phone, and blinks on a
      // timer after that.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpWidget(const SizedBox());
    }, variant: android);
  }
  const String prefix = '\u200b';

  late CodeLineEditingController controller;

  Future<void> pumpEditor(WidgetTester tester, String text, CodeLineSelection selection) async {
    controller = CodeLineEditingController.fromText(text);
    controller.selection = selection;
    final FocusNode focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CodeEditor(controller: controller, focusNode: focusNode),
      ),
    ));
    focusNode.requestFocus();
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
  }

  Map<String, dynamic> editingState(WidgetTester tester) => tester.testTextInput.editingState!;

  int client(WidgetTester tester) => tester.testTextInput.log
      .lastWhere((call) => call.method == 'TextInput.setClient')
      .arguments[0] as int;

  Future<void> sendDelta(WidgetTester tester, {
    String deltaText = '',
    int deltaStart = -1,
    int deltaEnd = -1,
    required int selectionBase,
    int? selectionExtent,
    int composingBase = -1,
    int composingExtent = -1,
  }) async {
    final String oldText = editingState(tester)['text'] as String;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.textInput.name,
      SystemChannels.textInput.codec.encodeMethodCall(MethodCall(
        'TextInputClient.updateEditingStateWithDeltas',
        <dynamic>[client(tester), <String, dynamic>{
          'deltas': [<String, dynamic>{
            'oldText': oldText,
            'deltaText': deltaText,
            'deltaStart': deltaStart,
            'deltaEnd': deltaEnd,
            'selectionBase': selectionBase,
            'selectionExtent': selectionExtent ?? selectionBase,
            'composingBase': composingBase,
            'composingExtent': composingExtent,
          }],
        }],
      )),
      (_) {},
    );
    await tester.pump();
  }

  testIme('holds the lines around the selection, not only its own', (tester) async {
    await pumpEditor(tester, 'one\ntwo\nthree', const CodeLineSelection.collapsed(index: 1, offset: 1));

    expect(editingState(tester)['text'], '${prefix}one\ntwo\nthree');
    // After the prefix and "one\n", one into "two".
    expect(editingState(tester)['selectionBase'], 6);
  });

  testIme('its select all selects every line', (tester) async {
    await pumpEditor(tester, 'one\ntwo\nthree', const CodeLineSelection.collapsed(index: 1, offset: 1));
    final String text = editingState(tester)['text'] as String;

    await sendDelta(tester, selectionBase: 0, selectionExtent: text.length);

    expect(controller.selection, const CodeLineSelection(
      baseIndex: 0, baseOffset: 0, extentIndex: 2, extentOffset: 5,
    ));
    expect(controller.text, 'one\ntwo\nthree');
  });

  testIme('and every line when there are more than it holds', (tester) async {
    final String text = List.generate(500, (i) => 'line $i').join('\n');
    await pumpEditor(tester, text, const CodeLineSelection.collapsed(index: 250, offset: 0));
    final String held = editingState(tester)['text'] as String;
    expect(held.split('\n').length, lessThan(500));

    await sendDelta(tester, selectionBase: 0, selectionExtent: held.length);

    expect(controller.selection.start, const CodeLinePosition(index: 0, offset: 0));
    expect(controller.selection.end, CodeLinePosition(index: 499, offset: 'line 499'.length));
  });

  testIme('its cursor keys reach another line', (tester) async {
    await pumpEditor(tester, 'one\ntwo\nthree', const CodeLineSelection.collapsed(index: 1, offset: 1));

    // Into "three", two along.
    await sendDelta(tester, selectionBase: 1 + 8 + 2);

    expect(controller.selection, const CodeLineSelection.collapsed(index: 2, offset: 2));
  });

  testIme('typing changes the selected line alone', (tester) async {
    await pumpEditor(tester, 'one\ntwo\nthree', const CodeLineSelection.collapsed(index: 1, offset: 3));

    await sendDelta(tester, deltaText: 'x', deltaStart: 8, deltaEnd: 8, selectionBase: 9);

    expect(controller.text, 'one\ntwox\nthree');
    expect(controller.selection, const CodeLineSelection.collapsed(index: 1, offset: 4));
  });

  testIme('a bracket typed on a line still closes itself', (tester) async {
    await pumpEditor(tester, 'one\ntwo\nthree', const CodeLineSelection.collapsed(index: 1, offset: 3));

    await sendDelta(tester, deltaText: '(', deltaStart: 8, deltaEnd: 8, selectionBase: 9);

    expect(controller.text, 'one\ntwo()\nthree');
    expect(controller.selection, const CodeLineSelection.collapsed(index: 1, offset: 4));
  });

  testIme('composing stays on its line', (tester) async {
    await pumpEditor(tester, 'one\ntwo\nthree', const CodeLineSelection.collapsed(index: 1, offset: 3));

    await sendDelta(tester, deltaText: 'ni', deltaStart: 8, deltaEnd: 8, selectionBase: 10,
      composingBase: 8, composingExtent: 10);

    expect(controller.text, 'one\ntwoni\nthree');
    expect(controller.composing, const TextRange(start: 3, end: 5));
  });

  testIme('a backspace at the start of a line joins it to the one above', (tester) async {
    await pumpEditor(tester, 'one\ntwo\nthree', const CodeLineSelection.collapsed(index: 1, offset: 0));

    // The line break between "one" and "two".
    await sendDelta(tester, deltaStart: 4, deltaEnd: 5, selectionBase: 4);

    expect(controller.text, 'onetwo\nthree');
    expect(controller.selection, const CodeLineSelection.collapsed(index: 0, offset: 3));
  });

  testIme('replacing a selection over lines', (tester) async {
    await pumpEditor(tester, 'one\ntwo\nthree', const CodeLineSelection(
      baseIndex: 0, baseOffset: 1, extentIndex: 2, extentOffset: 2,
    ));
    expect(editingState(tester)['selectionBase'], 2);
    expect(editingState(tester)['selectionExtent'], 11);

    await sendDelta(tester, deltaText: 'X', deltaStart: 2, deltaEnd: 11, selectionBase: 3);

    expect(controller.text, 'oXree');
    expect(controller.selection, const CodeLineSelection.collapsed(index: 0, offset: 2));
  });

  testIme('a backspace before the first line deletes nothing', (tester) async {
    await pumpEditor(tester, 'one\ntwo', const CodeLineSelection.collapsed(index: 0, offset: 0));

    // The prefix, which is all there is in front of the cursor.
    await sendDelta(tester, deltaStart: 0, deltaEnd: 1, selectionBase: 0);

    expect(controller.text, 'one\ntwo');
    expect(controller.selection, const CodeLineSelection.collapsed(index: 0, offset: 0));
    // It already dropped the prefix, so it is sent again.
    expect(editingState(tester)['text'], '${prefix}one\ntwo');
  });

  testIme('typing over its select all replaces every line', (tester) async {
    await pumpEditor(tester, 'one\ntwo\nthree', const CodeLineSelection.collapsed(index: 1, offset: 1));
    final String text = editingState(tester)['text'] as String;
    await sendDelta(tester, selectionBase: 0, selectionExtent: text.length);

    // The prefix goes with the selection it is part of.
    await sendDelta(tester, deltaText: 'a', deltaStart: 0, deltaEnd: text.length, selectionBase: 1);

    expect(controller.text, 'a');
    expect(controller.selection, const CodeLineSelection.collapsed(index: 0, offset: 1));
  });

  testIme('a selection too long to send is edited as a whole', (tester) async {
    final String text = List.generate(2000, (i) => 'line $i').join('\n');
    await pumpEditor(tester, text, const CodeLineSelection.collapsed(index: 0, offset: 0));
    controller.selectAll();
    await tester.pump();
    // Only the first line goes.
    expect(editingState(tester)['text'], '${prefix}line 0');

    await sendDelta(tester, deltaText: 'x', deltaStart: 1, deltaEnd: 7, selectionBase: 2);

    expect(controller.text, 'x');
  });

  testIme('moving the cursor inside what it holds sends nothing back', (tester) async {
    await pumpEditor(tester, 'one\ntwo\nthree', const CodeLineSelection.collapsed(index: 1, offset: 1));
    int sent() => tester.testTextInput.log.where((call) => call.method == 'TextInput.setEditingState').length;
    final int before = sent();

    await sendDelta(tester, selectionBase: 11);

    expect(controller.selection, const CodeLineSelection.collapsed(index: 2, offset: 2));
    expect(sent(), before);
  });
}
