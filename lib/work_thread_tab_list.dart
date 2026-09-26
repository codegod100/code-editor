import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A horizontal tab strip that also accepts a conventional mouse wheel.
class WorkThreadTabList extends StatefulWidget {
  const WorkThreadTabList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  @override
  State<WorkThreadTabList> createState() => _WorkThreadTabListState();
}

class _WorkThreadTabListState extends State<WorkThreadTabList> {
  final _scroll = ScrollController();

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.scrollDelta.dx != 0 ||
        event.scrollDelta.dy == 0 ||
        !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final delta = position.axisDirection == AxisDirection.left
        ? -event.scrollDelta.dy
        : event.scrollDelta.dy;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;

    // The inner list gets first choice, preserving native horizontal and
    // Shift-wheel handling and preventing a single event from scrolling twice.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      position.pointerScroll(delta);
      event.respond(allowPlatformDefault: false);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerSignal: _onPointerSignal,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            dragDevices: {
              ...ScrollConfiguration.of(context).dragDevices,
              PointerDeviceKind.mouse,
            },
          ),
          child: ListView.separated(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            itemCount: widget.itemCount,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder: widget.itemBuilder,
          ),
        ),
      );
}
