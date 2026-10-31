part of re_editor;

class _CodeInputController extends ChangeNotifier implements DeltaTextInputClient {

  CodeLineEditingController _controller;
  FocusNode _focusNode;
  bool _readOnly;
  bool _autocompleteSymbols;
  bool _updateCausedByFloatingCursor;
  late Offset _floatingCursorStartingOffset;

  TextInputConnection? _textInputConnection;
  TextEditingValue? _remoteEditingValue;
  // The lines [_remoteEditingValue] holds.
  _ImeWindow? _remoteWindow;
  // Set while an input method change is applied, so the half-applied states
  // are not sent back to it.
  bool _applyingRemote = false;

  final _CodeFloatingCursorController _floatingCursorController;
  Timer? _floatingCursorScrollTimer;

  GlobalKey? _editorKey;

  _CodeInputController({
    required CodeLineEditingController controller,
    required _CodeFloatingCursorController floatingCursorController,
    required FocusNode focusNode,
    required bool readOnly,
    required bool autocompleteSymbols,
  }) : _controller = controller,
    _floatingCursorController = floatingCursorController,
    _focusNode = focusNode,
    _readOnly = readOnly,
    _updateCausedByFloatingCursor = false,
    _autocompleteSymbols = autocompleteSymbols {
    _controller.addListener(_onCodeEditingChanged);
    _focusNode.addListener(_onFocusChanged);
  }

  void bindEditor(GlobalKey key) {
    _editorKey = key;
  }

  set controller(CodeLineEditingController value) {
    if (_controller == value) {
      return;
    }
    _controller.removeListener(_onCodeEditingChanged);
    _controller = value;
    _controller.addListener(_onCodeEditingChanged);
    _remoteWindow = null;
    _onCodeEditingChanged();
  }

  set focusNode(FocusNode value) {
    if (_focusNode == value) {
      return;
    }
    _focusNode.removeListener(_onFocusChanged);
    _focusNode = value;
    _focusNode.addListener(_onFocusChanged);
  }

  set readOnly(bool value) {
    if (_readOnly == value) {
      return;
    }
    _readOnly = value;
  }

  set autocompleteSymbols(bool value) {
    if (_autocompleteSymbols == value) {
      return;
    }
    _autocompleteSymbols = value;
  }

  set value(CodeLineEditingValue value) {
    _controller.value = value;
  }

  CodeLineEditingValue get value => _controller.value;

  set codeLines(CodeLines value) {
    _controller.codeLines = value.isEmpty ? _kInitialCodeLines : value;
  }

  CodeLines get codeLines => _controller.codeLines;

  set selection(CodeLineSelection value) => _controller.selection = value;

  CodeLineSelection get selection => _controller.selection;

  set composing(TextRange value) => _controller.composing = value;

  TextRange get composing => _controller.composing;

  @override
  void connectionClosed() {
  }

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  TextEditingValue? get currentTextEditingValue => _remoteEditingValue ?? _buildTextEditingValue().value;

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline) {
      // Fix issue #42, iOS will insert duplicate new lines.
      // We only do this on Android.
      if (kIsAndroid) {
        _controller.applyNewLine();
      }
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
  }

  @override
  bool onFocusReceived() {
    if (!_focusNode.hasFocus && _focusNode.canRequestFocus) {
      _focusNode.requestFocus();
      return true;
    }
    return false;
  }

  @override
  void showToolbar() {
  }

  @override
  void insertTextPlaceholder(Size size) {
  }

  @override
  void removeTextPlaceholder() {
  }

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    if (_updateCausedByFloatingCursor) {
      // This is necessary because otherwise the content of the line where the floating cursor was started
      // will be pasted over to the line where the floating cursor was stopped.
      _updateCausedByFloatingCursor = false;
      return;
    }

    if (textEditingDeltas.any((delta) => delta is TextEditingDeltaInsertion && delta.textInserted == '\n')) {
      TextEditingValue newValue = _remoteEditingValue!;
      for (final TextEditingDelta delta in textEditingDeltas) {
        newValue = delta.apply(newValue);
      }
      _remoteEditingValue = newValue;
      _controller.applyNewLine();
      return;
    }

    final TextEditingValue remoteValue = _remoteEditingValue!;
    final _ImeWindow window = _remoteWindow!;
    if (window.single) {
      _applyLineDeltas(textEditingDeltas, textEditingDeltas, remoteValue);
      return;
    }
    final _LineDeltas? lineDeltas = _localizeDeltas(textEditingDeltas, remoteValue, window);
    if (lineDeltas != null) {
      _applyLineDeltas(textEditingDeltas, lineDeltas.deltas, lineDeltas.value);
    } else {
      _applyWindowDeltas(textEditingDeltas, remoteValue, window);
    }
  }

  /// Edits inside the selected line, as the line alone would have received
  /// them: the smart symbols and the composing range work per line.
  void _applyLineDeltas(List<TextEditingDelta> deltas, List<TextEditingDelta> lineDeltas, TextEditingValue lineValue) {
    // _Trace.begin('updateEditingValue all');
    TextEditingValue newValue = lineValue;
    bool smartChange = false;
    for (final TextEditingDelta delta in lineDeltas) {
      if (_autocompleteSymbols) {
        TextEditingDelta newDelta = _SmartTextEditingDelta(delta).apply(selection);
        if (newDelta != delta) {
          smartChange = true;
        }
        newValue = newDelta.apply(newValue);
      } else {
        newValue = delta.apply(newValue);
      }
    }
    if (newValue == lineValue) {
      return;
    }
    if (!smartChange) {
      TextEditingValue remoteValue = _remoteEditingValue!;
      for (final TextEditingDelta delta in deltas) {
        remoteValue = delta.apply(remoteValue);
      }
      _remoteEditingValue = remoteValue;
    }
    // print('update text ${newValue.text}');
    // print('update selection ${newValue.selection}');
    // print('update composing ${newValue.composing}');
    if (newValue.usePrefix) {
      if (newValue.selection.isCollapsed && newValue.selection.start == 0) {
        _deleteBackward();
      } else {
        _controller.edit(newValue.removePrefixIfNecessary());
      }
    } else {
      _controller.edit(newValue);
    }
    notifyListeners();
    // _Trace.end('updateEditingValue all');
  }

  /// Edits and selections that reach past the selected line: a selection
  /// over several lines, the cursor moved to another one, a paste of lines.
  void _applyWindowDeltas(List<TextEditingDelta> deltas, TextEditingValue remoteValue, _ImeWindow window) {
    TextEditingValue newValue = remoteValue;
    for (final TextEditingDelta delta in deltas) {
      newValue = delta.apply(newValue);
    }
    if (newValue == remoteValue) {
      return;
    }
    _remoteEditingValue = newValue;
    final int prefix = window.lineStarts.first;
    final String oldText = remoteValue.text;
    final String newText = newValue.text;
    if (prefix > 0 && newText == oldText.substring(prefix)) {
      // The prefix alone was deleted: a backspace before the first line.
      _deleteBackward();
      return;
    }
    if (oldText == newText) {
      final TextSelection textSelection = newValue.selection;
      // What an input method's select all does: it can only select what it
      // was given. The window follows the selection, so a selection reaches
      // both of its ends only at the ends of the code, where it is whole.
      if (!window.whole && newText.length > prefix && textSelection.start <= prefix
        && textSelection.end >= newText.length) {
        _controller.selectAll();
      } else {
        _applyRemote(() {
          _controller.value = _controller.value.copyWith(
            selection: window.selectionOf(textSelection),
            composing: window.composingOf(newValue.composing, textSelection),
          );
        });
      }
      notifyListeners();
      return;
    }
    int head = 0;
    while (head < oldText.length && head < newText.length && oldText.codeUnitAt(head) == newText.codeUnitAt(head)) {
      head++;
    }
    int tail = 0;
    while (tail < oldText.length - head && tail < newText.length - head
      && oldText.codeUnitAt(oldText.length - 1 - tail) == newText.codeUnitAt(newText.length - 1 - tail)) {
      tail++;
    }
    final TextSelection oldSelection = remoteValue.selection;
    if (head + tail + 1 == oldText.length && head + tail == newText.length && oldText.codeUnitAt(head) == 0x0A
      && oldSelection.isCollapsed && oldSelection.baseOffset == head + 1) {
      // The line break before the cursor: a backspace at the start of a line,
      // which the editor has its own handling for.
      _deleteBackward();
      return;
    }
    final CodeLinePosition start = window.positionOf(head);
    final CodeLinePosition end = window.positionOf(oldText.length - tail);
    String replacement = newText.substring(head, newText.length - tail);
    if (prefix > 0) {
      replacement = replacement.replaceAll(_kPrefix, '');
    }
    final _ImeWindow newWindow = _ImeWindow.fromText(window, newText,
      newText.startsWith(_kPrefix) ? prefix : 0);
    _applyRemote(() {
      _controller.replaceSelection(replacement, CodeLineSelection(
        baseIndex: start.index,
        baseOffset: start.offset,
        extentIndex: end.index,
        extentOffset: end.offset,
      ));
      _controller.value = _controller.value.copyWith(
        selection: newWindow.selectionOf(newValue.selection),
        composing: newWindow.composingOf(newValue.composing, newValue.selection),
      );
    });
    notifyListeners();
  }

  /// A backspace, after which the input method is told what is there even
  /// when nothing changed: it has already removed what it thinks was deleted.
  void _deleteBackward() {
    _controller.deleteBackward();
    _remoteEditingValue = null;
    _updateRemoteEditingValueIfNeeded();
    notifyListeners();
  }

  /// Runs [apply] without sending each step to the input method, then sends
  /// where it ended up.
  void _applyRemote(VoidCallback apply) {
    _applyingRemote = true;
    try {
      apply();
    } finally {
      _applyingRemote = false;
    }
    _onCodeEditingChanged();
  }

  /// [deltas] made relative to the selected line, with the prefix in front of
  /// it, or null when any of them reaches outside that line.
  _LineDeltas? _localizeDeltas(List<TextEditingDelta> deltas,
    TextEditingValue remoteValue, _ImeWindow window) {
    if (!selection.isSameLine) {
      return null;
    }
    final int line = selection.baseIndex - window.start;
    if (line < 0 || line >= window.lineStarts.length) {
      return null;
    }
    final int prefix = window.lineStarts.first;
    final int lineStart = window.lineStarts[line];
    // Window offset minus this is the offset in the line value.
    final int shift = lineStart - prefix;
    // The prefix belongs to the first line.
    final int low = line == 0 ? 0 : lineStart;
    int high = lineStart + window.lineLengths[line];
    bool inside(int offset) => offset >= low && offset <= high;
    bool insideRange(TextRange range) => !range.isValid || (inside(range.start) && inside(range.end));
    bool insideSelection(TextSelection value) => !value.isValid || (inside(value.baseOffset) && inside(value.extentOffset));
    TextSelection shiftSelection(TextSelection value) => value.isValid ? value.copyWith(
      baseOffset: value.baseOffset - shift,
      extentOffset: value.extentOffset - shift,
    ) : value;
    TextRange shiftRange(TextRange value) => value.isValid ? TextRange(
      start: value.start - shift,
      end: value.end - shift,
    ) : value;

    final TextEditingValue lineValue = TextEditingValue(
      text: remoteValue.text.substring(0, prefix) + remoteValue.text.substring(lineStart, lineStart + window.lineLengths[line]),
      selection: shiftSelection(remoteValue.selection),
      composing: shiftRange(remoteValue.composing),
    );
    TextEditingValue current = lineValue;
    final List<TextEditingDelta> lineDeltas = [];
    for (final TextEditingDelta delta in deltas) {
      if (delta is TextEditingDeltaInsertion) {
        if (!inside(delta.insertionOffset) || delta.textInserted.contains('\n')) {
          return null;
        }
        high += delta.textInserted.length;
      } else if (delta is TextEditingDeltaDeletion) {
        if (!insideRange(delta.deletedRange)) {
          return null;
        }
        high -= delta.deletedRange.end - delta.deletedRange.start;
      } else if (delta is TextEditingDeltaReplacement) {
        if (!insideRange(delta.replacedRange) || delta.replacementText.contains('\n')) {
          return null;
        }
        high += delta.replacementText.length - (delta.replacedRange.end - delta.replacedRange.start);
      }
      // Against the line after this delta, which is what they are in.
      if (!insideSelection(delta.selection) || !insideRange(delta.composing)) {
        return null;
      }
      final TextEditingDelta lineDelta;
      if (delta is TextEditingDeltaInsertion) {
        lineDelta = TextEditingDeltaInsertion(
          oldText: current.text,
          textInserted: delta.textInserted,
          insertionOffset: delta.insertionOffset - shift,
          selection: shiftSelection(delta.selection),
          composing: shiftRange(delta.composing),
        );
      } else if (delta is TextEditingDeltaDeletion) {
        lineDelta = TextEditingDeltaDeletion(
          oldText: current.text,
          deletedRange: shiftRange(delta.deletedRange),
          selection: shiftSelection(delta.selection),
          composing: shiftRange(delta.composing),
        );
      } else if (delta is TextEditingDeltaReplacement) {
        lineDelta = TextEditingDeltaReplacement(
          oldText: current.text,
          replacementText: delta.replacementText,
          replacedRange: shiftRange(delta.replacedRange),
          selection: shiftSelection(delta.selection),
          composing: shiftRange(delta.composing),
        );
      } else {
        lineDelta = TextEditingDeltaNonTextUpdate(
          oldText: current.text,
          selection: shiftSelection(delta.selection),
          composing: shiftRange(delta.composing),
        );
      }
      current = lineDelta.apply(current);
      lineDeltas.add(lineDelta);
    }
    return _LineDeltas(lineDeltas, lineValue);
  }

  @override
  void updateEditingValue(TextEditingValue textEditingValue) {
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    _updateCausedByFloatingCursor = true;
    final _CodeFieldRender? render = _editorKey?.render;
    if (render == null) {
      return;
    }
    switch(point.state) {
      case FloatingCursorDragState.Start:
        _floatingCursorStartingOffset = render.calculateTextPositionViewportOffset(selection.base)!;
        _floatingCursorController.setFloatingCursorPositions(
          floatingCursorOffset: _floatingCursorStartingOffset,
          finalCursorSelection: selection,
        );
        break;
      case FloatingCursorDragState.Update:
        final Offset updatedOffset = _floatingCursorStartingOffset + point.offset!;

        final double topBound = render.paintBounds.top + render.paddingTop;
        final double leftBound = render.paintBounds.left + render.paddingLeft;
        final double bottomBound = render.paintBounds.bottom - render.paddingBottom - render.floatingCursorHeight;
        final double rightBound = render.paintBounds.right - render.paddingRight;

        // Clamp the offset coordinates to the paint bounds
        Offset clampedUpdatedOffset = Offset(
          updatedOffset.dx.clamp(leftBound, rightBound),
          updatedOffset.dy.clamp(topBound, bottomBound),
        );

        // An adjustment is made on the y-axis so that whenever it is in between lines, the line where the center
        // of the floating cursor is will be selected.
        Offset adjustedClampedUpdatedOffset = clampedUpdatedOffset + Offset(0, render.floatingCursorHeight / 2);
        final CodeLinePosition newPosition = render.calculateTextPosition(adjustedClampedUpdatedOffset)!;

        // The offset at which the actual cursor would end up if floating cursor was terminated now.
        final Offset? snappedNewOffset = render.calculateTextPositionViewportOffset(newPosition);

        CodeLineSelection newSelection = CodeLineSelection.fromPosition(position: newPosition);


        if (clampedUpdatedOffset != updatedOffset) {
          // When the cursor is at one of the edges, adjust the starting offset so that the floating cursor
          // does not get "loose" when starting to move in the opposite direction.
          _floatingCursorStartingOffset += clampedUpdatedOffset - updatedOffset;
        }

        if (clampedUpdatedOffset.dy == topBound || clampedUpdatedOffset.dy == bottomBound || clampedUpdatedOffset.dx == rightBound || clampedUpdatedOffset.dx == leftBound) {
          _floatingCursorScrollTimer ??= Timer.periodic(const Duration(milliseconds: 50), (timer) {
            render.autoScrollWhenDraggingFloatingCursor(clampedUpdatedOffset);
            final CodeLinePosition newPos = render.calculateTextPosition(adjustedClampedUpdatedOffset)!;
            final Offset? snappedNewOffset = render.calculateTextPositionViewportOffset(newPos);

            // This step ensures that the preview cursor will keep updating when scrolling
            if (adjustedClampedUpdatedOffset.dx > snappedNewOffset!.dx + render.textStyle.fontSize!) {
              _floatingCursorController.updatePreviewCursorOffset(snappedNewOffset);
            }
            else {
              _floatingCursorController.updatePreviewCursorOffset(null);
            }
          });
        }
        else {
          if (_floatingCursorScrollTimer != null) {
            _floatingCursorScrollTimer!.cancel();
            _floatingCursorScrollTimer = null;
          }
        }

        // Only turn on the preview cursor if we are away from the end of the line (relatively to the font size)
        if (adjustedClampedUpdatedOffset.dx > snappedNewOffset!.dx + render.textStyle.fontSize!) {
          _floatingCursorController.setFloatingCursorPositions(
            floatingCursorOffset: clampedUpdatedOffset,
            previewCursorOffset: snappedNewOffset,
            finalCursorOffset: snappedNewOffset,
            finalCursorSelection:newSelection
          );
        }
        else {
          _floatingCursorController.setFloatingCursorPositions(
            floatingCursorOffset: clampedUpdatedOffset,
            finalCursorOffset: snappedNewOffset,
            finalCursorSelection: newSelection
          );
        }

        break;
      case FloatingCursorDragState.End:
        if (_floatingCursorScrollTimer != null) {
          _floatingCursorScrollTimer!.cancel();
          _floatingCursorScrollTimer = null;
        }
        selection = _floatingCursorController.value.finalCursorSelection!;
        final CodeLinePosition finalPosition = CodeLinePosition(
          index: selection.baseIndex,
          offset: selection.baseOffset,
          affinity: selection.baseAffinity);

        final Offset? finalOffset = render.calculateTextPositionViewportOffset(finalPosition);

        // If the final selection is in not the viewport, make it visible without animating the floating cursor.
        // Otherwise, play the floating cursor reset animation.
        if (finalOffset != null && (finalOffset.dx < 0 || finalOffset.dy < 0)) {
          render.makePositionCenterIfInvisible(
            CodeLinePosition(
              index: selection.baseIndex,
              offset: selection.baseOffset,
              affinity: selection.baseAffinity),
            animated: true);
            _floatingCursorController.disableFloatingCursor();
        }
        else {
          _floatingCursorController.animateDisableFloatingCursor();
        }


    }
  }

  @override
  void didChangeInputControl(TextInputControl? oldControl, TextInputControl? newControl) {
  }

  @override
  void performSelector(String selectorName) {
  }

  @override
  void insertContent(KeyboardInsertedContent content) {
  }

  void ensureInput() {
    if (_focusNode.hasFocus) {
      if (!_readOnly) {
        _openInputConnection();
      }
    } else {
      _focusNode.requestFocus();
    }
  }

  @override
  void notifyListeners() {
    // Do nothing here.
    super.notifyListeners();
  }

  @override
  void dispose() {
    super.dispose();
    _closeInputConnectionIfNeeded();
    _controller.removeListener(_onCodeEditingChanged);
    _focusNode.removeListener(_onFocusChanged);
  }

  bool get _hasInputConnection => _textInputConnection?.attached ?? false;

  void _onCodeEditingChanged() {
    if (_applyingRemote) {
      return;
    }
    _updateRemoteEditingValueIfNeeded();
    _updateRemoteComposingIfNeeded();
  }

  void _updateRemoteEditingValueIfNeeded() {
    if (!_hasInputConnection) {
      return;
    }
    final _ImeValue local = _buildTextEditingValue();
    TextEditingValue localValue = local.value;
    _remoteWindow = local.window;
    if (localValue == _remoteEditingValue) {
      return;
    }
    if (localValue.composing.isValid && max(localValue.composing.start, localValue.composing.end) > localValue.text.length) {
      localValue = localValue.copyWith(
        composing: TextRange.empty
      );
    }
    // print('post text ${localValue.text}');
    // print('post selection ${localValue.selection}');
    // print('post composing ${localValue.composing}');
    _remoteEditingValue = localValue;

    _textInputConnection!.setEditingState(localValue);
  }

  void _updateRemoteComposingIfNeeded({
    bool retry = false
  }) {
    if (!_hasInputConnection) {
      return;
    }
    final _CodeFieldRender? render = _editorKey?.render;
    if (render == null) {
      return;
    }
    final Offset? composingStart = render.calculateTextPositionViewportOffset(selection.base.copyWith(
      offset: composing.start
    ));
    final Offset? composingEnd = render.calculateTextPositionViewportOffset(selection.extent.copyWith(
      offset: composing.end
    ));
    if (composingStart != null && composingEnd != null) {
      _textInputConnection!.setComposingRect(Rect.fromPoints(composingStart, composingEnd + Offset(0, render.lineHeight)));
    }
    final Offset? caret = render.calculateTextPositionViewportOffset(selection.base) ?? composingStart;
    if (caret != null) {
      _textInputConnection!.setCaretRect(Rect.fromLTWH(caret.dx, caret.dy, render.cursorWidth, render.lineHeight));
    } else if (!retry) {
      Future.delayed(const Duration(milliseconds: 10), () {
        _updateRemoteComposingIfNeeded(
          retry: true
        );
      });
    }
  }

  void _updateRemoteEditableSizeAndTransform() {
    if (!_hasInputConnection) {
      return;
    }
    final _CodeFieldRender? render = _editorKey?.render;
    if (render == null || !render.hasSize) {
      return;
    }
    _textInputConnection!.setEditableSizeAndTransform(render.size, render.getTransformTo(null));
  }

  void _onFocusChanged() {
    _openOrCloseInputConnectionIfNeeded();
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (_focusNode.hasFocus && !_readOnly) {
      if (_focusNode.consumeKeyboardToken()) {
        _openInputConnection();
      }
    } else {
      _closeInputConnectionIfNeeded();
      _controller.clearComposing();
    }
  }

  void _openInputConnection() {
    final BuildContext? context = _editorKey?.currentContext;
    if (context == null) {
      return;
    }
    if (!_hasInputConnection) {
      // Fix PlatformException issue on new flutter version.
      // See https://github.com/reqable/re-editor/issues/83
      final TextInputConnection connection = TextInput.attach(this,
        _TextInputConfiguration(
          flutterViewId: View.maybeOf(context)?.viewId ?? 0,
          enableDeltaModel: true,
          inputAction: TextInputAction.newline,
          autocorrect: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          textCapitalization: TextCapitalization.none,
          keyboardAppearance: Theme.of(context).brightness,
        ),
      );
      final _ImeValue local = _buildTextEditingValue();
      _remoteEditingValue = local.value;
      _remoteWindow = local.window;
      connection.setEditingState(_remoteEditingValue!);
      connection.show();
      _textInputConnection = connection;
    } else {
      _textInputConnection?.show();
    }
    _updateRemoteComposingIfNeeded();
    _updateRemoteEditableSizeAndTransform();
  }

  void _closeInputConnectionIfNeeded() {
    if (_hasInputConnection) {
      _textInputConnection!.close();
    }
    _textInputConnection = null;
    _remoteEditingValue = null;
    _remoteWindow = null;
  }

  /// What the input method is given: the selected lines and up to
  /// [_kImeWindowLines] on either side of them.
  ///
  /// More than the selected line, because an input method only acts on the
  /// text it holds: with one line, its select all and its cursor keys could
  /// not leave it. Not every line, because all of it is sent again on each
  /// change. A folded line ends it, since its text is not what is shown.
  _ImeValue _buildTextEditingValue() {
    final CodeLines lines = codeLines;
    final int prefix = _usePrefix ? _kPrefix.length : 0;
    int first = selection.startIndex;
    int last = selection.endIndex;
    int selected = 0;
    for (int i = first; i <= last && selected <= _kImeWindowChars; i++) {
      selected += lines[i].length + 1;
    }
    if (selected > _kImeWindowChars) {
      return _buildLineValue(prefix);
    }
    final _ImeWindow? previous = _remoteWindow;
    final bool reuse = previous != null && !previous.single && previous.lineCount == lines.length
      && previous.start <= first && previous.end >= last
      // Kept while composing: a window that moved would replace the text the
      // input method is composing in. Otherwise until the selection nears an
      // edge, so moving the cursor does not resend it.
      && (composing.isValid || (
        (previous.start == 0 || first - previous.start >= _kImeWindowMargin)
        && (previous.end == lines.length - 1 || previous.end - last >= _kImeWindowMargin)));
    if (reuse) {
      first = previous.start;
      last = previous.end;
    } else {
      int chars = 0;
      for (int i = 0; i < _kImeWindowLines && first > 0; i++) {
        final CodeLine line = lines[first - 1];
        if (line.chunkParent || chars + line.length > _kImeWindowChars) {
          break;
        }
        chars += line.length + 1;
        first--;
      }
      chars = 0;
      for (int i = 0; i < _kImeWindowLines && last < lines.length - 1; i++) {
        final CodeLine line = lines[last + 1];
        if (line.chunkParent || chars + line.length > _kImeWindowChars) {
          break;
        }
        chars += line.length + 1;
        last++;
      }
    }
    final StringBuffer text = StringBuffer(prefix > 0 ? _kPrefix : '');
    final List<int> lineStarts = [];
    final List<int> lineLengths = [];
    for (int i = first; i <= last; i++) {
      if (i > first) {
        text.write('\n');
      }
      lineStarts.add(text.length);
      lineLengths.add(lines[i].length);
      text.write(lines[i].text);
    }
    final _ImeWindow window = _ImeWindow(
      start: first,
      lineStarts: lineStarts,
      lineLengths: lineLengths,
      lineCount: lines.length,
    );
    final TextRange textComposing;
    if (composing.isValid) {
      textComposing = TextRange(
        start: window.offsetOf(selection.baseIndex, composing.start),
        end: window.offsetOf(selection.baseIndex, composing.end),
      );
    } else {
      textComposing = composing;
    }
    return _ImeValue(TextEditingValue(
      text: text.toString(),
      selection: TextSelection(
        baseOffset: window.offsetOf(selection.baseIndex, selection.baseOffset),
        extentOffset: window.offsetOf(selection.extentIndex, selection.extentOffset),
      ),
      composing: textComposing,
    ), window);
  }

  /// The selection's first line alone, for a selection too long to send: the
  /// input method holds its part of that line, and an edit to it applies to
  /// the whole selection.
  _ImeValue _buildLineValue(int prefix) {
    final TextSelection textSelection;
    if (selection.baseIndex < selection.extentIndex) {
      textSelection = TextSelection(
        baseOffset: prefix + selection.baseOffset,
        extentOffset: prefix + codeLines[selection.baseIndex].length,
      );
    } else {
      textSelection = TextSelection(
        baseOffset: prefix,
        extentOffset: prefix + selection.baseOffset,
      );
    }
    final CodeLine line = codeLines[selection.baseIndex];
    return _ImeValue(TextEditingValue(
      text: (prefix > 0 ? _kPrefix : '') + line.text,
      selection: textSelection,
      composing: composing.isValid ? TextRange(
        start: prefix + composing.start,
        end: prefix + composing.end,
      ) : composing,
    ), _ImeWindow(
      start: selection.baseIndex,
      lineStarts: [prefix],
      lineLengths: [line.length],
      lineCount: codeLines.length,
      single: true,
    ));
  }

}

class _ImeValue {
  final TextEditingValue value;
  final _ImeWindow window;

  const _ImeValue(this.value, this.window);
}

class _LineDeltas {
  final List<TextEditingDelta> deltas;
  /// The line they apply to, behind the prefix.
  final TextEditingValue value;

  const _LineDeltas(this.deltas, this.value);
}

const int _kImeWindowLines = 50;
const int _kImeWindowChars = 8192;
const int _kImeWindowMargin = 10;

/// Which lines the text an input method holds is made of, and where each of
/// them starts in it.
class _ImeWindow {
  /// The index of the first line.
  final int start;
  /// Where each line starts in the text, after the prefix.
  final List<int> lineStarts;
  final List<int> lineLengths;
  /// How many lines the code had.
  final int lineCount;
  /// Whether this is the selection's first line alone, see
  /// [_CodeInputController._buildLineValue].
  final bool single;

  const _ImeWindow({
    required this.start,
    required this.lineStarts,
    required this.lineLengths,
    required this.lineCount,
    this.single = false,
  });

  /// The lines of [text], an edited copy of what [window] held, behind a
  /// prefix [prefix] long.
  factory _ImeWindow.fromText(_ImeWindow window, String text, int prefix) {
    final List<int> lineStarts = [prefix];
    final List<int> lineLengths = [];
    for (int i = prefix; i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        lineLengths.add(i - lineStarts.last);
        lineStarts.add(i + 1);
      }
    }
    lineLengths.add(text.length - lineStarts.last);
    return _ImeWindow(
      start: window.start,
      lineStarts: lineStarts,
      lineLengths: lineLengths,
      lineCount: window.lineCount + lineStarts.length - window.lineStarts.length,
    );
  }

  /// Whether these are all the lines there are.
  bool get whole => start == 0 && end == lineCount - 1;

  int get end => start + lineStarts.length - 1;

  int offsetOf(int index, int offset) {
    final int line = (index - start).clamp(0, lineStarts.length - 1);
    return lineStarts[line] + offset.clamp(0, lineLengths[line]);
  }

  /// Where [offset] is. One in the prefix is the start of the first line.
  CodeLinePosition positionOf(int offset, [TextAffinity affinity = TextAffinity.downstream]) {
    int line = lineStarts.length - 1;
    while (line > 0 && lineStarts[line] > offset) {
      line--;
    }
    return CodeLinePosition(
      index: start + line,
      offset: (offset - lineStarts[line]).clamp(0, lineLengths[line]),
      affinity: affinity,
    );
  }

  CodeLineSelection selectionOf(TextSelection value) {
    final CodeLinePosition base = positionOf(value.baseOffset, value.affinity);
    final CodeLinePosition extent = positionOf(value.extentOffset, value.affinity);
    return CodeLineSelection(
      baseIndex: base.index,
      baseOffset: base.offset,
      baseAffinity: base.affinity,
      extentIndex: extent.index,
      extentOffset: extent.offset,
      extentAffinity: extent.affinity,
    );
  }

  /// [value] in the line [selection] starts on, which is where the editor
  /// keeps its composing range; empty when it is on any other line.
  TextRange composingOf(TextRange value, TextSelection selection) {
    if (!value.isValid) {
      return TextRange.empty;
    }
    final CodeLinePosition start = positionOf(value.start);
    final CodeLinePosition end = positionOf(value.end);
    final int line = positionOf(selection.baseOffset).index;
    if (start.index != line || end.index != line) {
      return TextRange.empty;
    }
    return TextRange(start: start.offset, end: end.offset);
  }

}

class _SmartTextEditingDelta {

  static const List<_ClosureSymbol> _closureSymbols = [
    _ClosureSymbol('{', '}'),
    _ClosureSymbol('[', ']'),
    _ClosureSymbol('(', ')'),
  ];

  static const List<String> _quoteSymbols = [
    '\'', '"', '`'
  ];

  static const List<_ClosureSymbol> _wrapSymbols = [
    _ClosureSymbol('{', '}'),
    _ClosureSymbol('[', ']'),
    _ClosureSymbol('(', ')'),
    _ClosureSymbol('\'', '\''),
    _ClosureSymbol('"', '"'),
    _ClosureSymbol('`', '`'),
  ];

  final TextEditingDelta _delta;

  _SmartTextEditingDelta(this._delta);

  TextEditingDelta apply(CodeLineSelection selection) {
    TextEditingDelta delta = _delta;
    if (delta is TextEditingDeltaInsertion) {
      delta = _smartInsertion(delta);
    } else if (delta is TextEditingDeltaReplacement) {
      delta = _smartReplacement(delta, selection);
    }
    return delta;
  }

  TextEditingDelta _smartInsertion(TextEditingDeltaInsertion delta) {
    for (final _ClosureSymbol symbol in _closureSymbols) {
      if (delta.textInserted == symbol.left) {
        if (!_shouldAutoClosed(delta.oldText, delta.insertionOffset, symbol)) {
          break;
        }
        return TextEditingDeltaInsertion(
          oldText: delta.oldText,
          textInserted: symbol.toString(),
          insertionOffset: delta.insertionOffset,
          selection: delta.selection,
          composing: delta.composing,
        );
      } else if (delta.textInserted == symbol.right) {
        if (!_shouldSkipClosed(delta.oldText, delta.insertionOffset, symbol)) {
          break;
        }
        return TextEditingDeltaNonTextUpdate(
          oldText: delta.oldText,
          selection: TextSelection.collapsed(
            offset: delta.insertionOffset + 1
          ),
          composing: delta.composing
        );
      }
    }
    for (final String symbol in _quoteSymbols) {
      if (delta.textInserted != symbol) {
        continue;
      }
      if (!_shouldAutoQuoted(delta.oldText, symbol, delta.insertionOffset)) {
        break;
      }
      return TextEditingDeltaInsertion(
        oldText: delta.oldText,
        textInserted: symbol * 2,
        insertionOffset: delta.insertionOffset,
        selection: delta.selection,
        composing: delta.composing,
      );
    }
    return delta;
  }

  TextEditingDelta _smartReplacement(TextEditingDeltaReplacement delta, CodeLineSelection selection) {
    if (!selection.isSameLine) {
      return delta;
    }
    if (delta.replacementText.length > 1) {
      return delta;
    }
    final int index = _wrapSymbols.indexWhere((element) => element.left == delta.replacementText);
    if (index < 0) {
      return delta;
    }
    final _ClosureSymbol symbol = _wrapSymbols[index];
    return TextEditingDeltaReplacement(
      oldText: delta.oldText,
      replacementText: symbol.left + delta.textReplaced + symbol.right,
      replacedRange: delta.replacedRange,
      selection: TextSelection(
        baseOffset: selection.startOffset + 1,
        extentOffset: selection.endOffset + 1
      ),
      composing: delta.composing
    );
  }

  bool _shouldAutoClosed(String text, int offset, _ClosureSymbol symbol) {
    final Characters characters = text.characters;
    if (characters.isEmpty) {
      return true;
    }
    int leftSymbolCount = 0;
    int rightSymbolCount = 0;
    for (int i = 0; i < characters.length; i++) {
      final String character = characters.elementAt(i);
      if (i <= offset) {
        if (character == symbol.left) {
          leftSymbolCount++;
        } else if (character == symbol.right) {
          leftSymbolCount--;
        }
      } else {
        if (character == symbol.left) {
          rightSymbolCount--;
        } else if (character == symbol.right) {
          rightSymbolCount++;
        }
      }
    }
    return max(0, leftSymbolCount) >= rightSymbolCount;
  }

  bool _shouldSkipClosed(String text, int offset, _ClosureSymbol symbol) {
    if (text.isEmpty) {
      return false;
    }
    if (offset == text.length) {
      return false;
    }
    return text.substring(offset, offset + 1) == symbol.right;
  }

  bool _shouldAutoQuoted(String text, String symbol, int offset) {
    final Characters characters = text.characters;
    if (characters.isEmpty) {
      return true;
    }
    int leftSymbolCount = 0;
    int rightSymbolCount = 0;
    for (int i = 0; i < characters.length; i++) {
      final String character = characters.elementAt(i);
      if (i < offset) {
        if (character == symbol) {
          leftSymbolCount++;
        }
      } else {
        if (character == symbol) {
          rightSymbolCount++;
        }
      }
    }
    if (leftSymbolCount == 0 && rightSymbolCount == 0) {
      return true;
    }
    if (rightSymbolCount == 0) {
      return leftSymbolCount % 2 == 0;
    }
    if (leftSymbolCount == 0) {
      return rightSymbolCount % 2 == 0;
    }
    return leftSymbolCount % 2 == rightSymbolCount % 2;
  }

}

class _ClosureSymbol {
  final String left;
  final String right;

  const _ClosureSymbol(this.left, this.right);

  @override
  String toString() {
    return left + right;
  }

}

const String _kPrefix = '\u200b';

/// Whether the text an input method holds starts with [_kPrefix], so that a
/// backspace at its start still reaches the editor.
bool get _usePrefix => kIsIOS || kIsAndroid;

extension _TextEditingValueExtension on TextEditingValue {

  bool get startWithPrefix => text.startsWith(_kPrefix);

  bool get usePrefix => _usePrefix;

  TextEditingValue removePrefixIfNecessary() {
    if (!usePrefix) {
      return this;
    }
    if (!startWithPrefix) {
      return this;
    }
    return copyWith(
      text: text.substring(1),
      selection: selection.copyWith(
        baseOffset: max(0, selection.baseOffset - 1),
        extentOffset: max(0, selection.extentOffset - 1),
      ),
      composing: composing.isValid ? TextRange(
        start: max(0, composing.start - 1),
        end: max(0, composing.end - 1)
      ) : null
    );
  }

}

class _TextInputConfiguration extends TextInputConfiguration {

  final int flutterViewId;

  const _TextInputConfiguration({
    required this.flutterViewId,
    required super.enableDeltaModel,
    required super.inputAction,
    super.autocorrect = false,
    super.smartDashesType = SmartDashesType.disabled,
    super.smartQuotesType = SmartQuotesType.disabled,
    super.textCapitalization = TextCapitalization.none,
    super.keyboardAppearance,
  });

  @override
  Map<String, dynamic> toJson() {
    return {
      ...super.toJson(),
      'viewId': flutterViewId,
    };
  }

}
