import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Rebuilds when the selected immutable values change, using shallow equality.
class const SelectorBuilder({
  super.key,
  required final Listenable listenable,
  required final List<Object?> Function() select,
  required final TransitionBuilder builder,
  final Widget? child,
}) extends StatefulWidget {
  @override
  State<SelectorBuilder> createState() => _SelectorBuilderState();
}

class _SelectorBuilderState extends State<SelectorBuilder> {
  late List<Object?> _values;

  @override
  void initState() {
    super.initState();
    _values = widget.select();
    widget.listenable.addListener(_onChange);
  }

  @override
  void didUpdateWidget(SelectorBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_onChange);
      widget.listenable.addListener(_onChange);
    }
    _values = widget.select();
  }

  void _onChange() {
    final next = widget.select();
    if (listEquals(_values, next)) return;
    setState(() => _values = next);
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.child);
}
