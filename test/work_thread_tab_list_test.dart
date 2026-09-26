import 'package:cloud_code_editor/work_thread_tab_list.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpTabs(WidgetTester tester, {int count = 10}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 46,
            child: WorkThreadTabList(
              itemCount: count,
              itemBuilder: (_, index) => SizedBox(
                width: 120,
                child: InputChip(
                  label: Text('Thread $index'),
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  ScrollPosition position(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position;

  Future<void> wheel(WidgetTester tester, Offset delta) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byType(WorkThreadTabList)),
        scrollDelta: delta,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'vertical wheel scrolls tabs in both directions and clamps edges',
    (tester) async {
      await pumpTabs(tester);
      await wheel(tester, const Offset(0, 100));
      expect(position(tester).pixels, 100);
      await wheel(tester, const Offset(0, -40));
      expect(position(tester).pixels, 60);
      await wheel(tester, const Offset(0, 10000));
      expect(position(tester).pixels, position(tester).maxScrollExtent);
      await wheel(tester, const Offset(0, -10000));
      expect(position(tester).pixels, 0);
    },
  );

  testWidgets('horizontal trackpad scrolling is handled only once', (
    tester,
  ) async {
    await pumpTabs(tester);
    await wheel(tester, const Offset(80, 20));
    expect(position(tester).pixels, 80);
  });

  testWidgets('mouse and touch can drag the tabs', (tester) async {
    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
      await pumpTabs(tester);
      final before = position(tester).pixels;
      await tester.drag(
        find.byType(WorkThreadTabList),
        const Offset(-100, 0),
        kind: kind,
      );
      await tester.pumpAndSettle();
      expect(position(tester).pixels, greaterThan(before));
    }
  });

  testWidgets('wheel is harmless when tabs do not overflow', (tester) async {
    await pumpTabs(tester, count: 1);
    await wheel(tester, const Offset(0, 100));
    expect(position(tester).pixels, 0);
    expect(tester.takeException(), isNull);
  });
}
