import 'package:flutter/material.dart';

class const MiddleEllipsisText({
  super.key,
  required final String value,
  final TextStyle? style,
  final TextAlign textAlign = TextAlign.start,
  final int maxLines = 1,
}) extends StatelessWidget {
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
      return Text(
        ellipsizeMiddle(
          value,
          maxWidth: constraints.maxWidth,
          style: effectiveStyle,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        ),
        maxLines: maxLines,
        semanticsLabel: value,
        style: effectiveStyle,
        textAlign: textAlign,
      );
    },
  );
}

class const MiddleEllipsisTextFormField({
  super.key,
  required final TextEditingController controller,
  final Key? fieldKey,
  final Key? collapsedTextKey,
  final bool autofocus = false,
  final bool autocorrect = true,
  final bool enableSuggestions = true,
  final InputDecoration decoration = const InputDecoration(),
  final TextStyle? style,
  final FormFieldValidator<String>? validator,
}) extends StatefulWidget {
  @override
  State<MiddleEllipsisTextFormField> createState() =>
      _MiddleEllipsisTextFormFieldState();
}

class _MiddleEllipsisTextFormFieldState
    extends State<MiddleEllipsisTextFormField> {
  final _focusNode = FocusNode();

  bool get _collapsed =>
      !_focusNode.hasFocus && widget.controller.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_refresh);
    widget.controller.addListener(_refresh);
  }

  @override
  void didUpdateWidget(MiddleEllipsisTextFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;
    oldWidget.controller.removeListener(_refresh);
    widget.controller.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _focusNode
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final effectiveStyle =
        widget.style ?? Theme.of(context).textTheme.titleMedium;
    return Stack(
      children: [
        TextFormField(
          key: widget.fieldKey,
          controller: widget.controller,
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          autocorrect: widget.autocorrect,
          enableSuggestions: widget.enableSuggestions,
          decoration: widget.decoration,
          style: _collapsed
              ? effectiveStyle?.copyWith(color: Colors.transparent)
              : effectiveStyle,
          validator: widget.validator,
        ),
        if (_collapsed)
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: MiddleEllipsisText(
                      key: widget.collapsedTextKey,
                      value: widget.controller.text,
                      style: effectiveStyle,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

String ellipsizeMiddle(
  String value, {
  required double maxWidth,
  required TextStyle style,
  required TextDirection textDirection,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  double widthOf(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout();
    return painter.width;
  }

  if (widthOf(value) <= maxWidth) return value;
  for (var visible = value.length - 1; visible >= 2; visible--) {
    final leading = (visible + 1) ~/ 2;
    final trailing = visible - leading;
    final shortened =
        '${value.substring(0, leading)}…'
        '${value.substring(value.length - trailing)}';
    if (widthOf(shortened) <= maxWidth) return shortened;
  }
  return '…';
}
