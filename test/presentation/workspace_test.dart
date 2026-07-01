import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synapse/main.dart';

void main() {
  testWidgets('shows the three-pane learning workspace', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    await tester.pumpWidget(const SynapseApp());

    expect(find.text('Synapse'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('Markdown'), findsOneWidget);
    expect(find.text('素材'), findsOneWidget);
    expect(find.text('AI 建议'), findsOneWidget);
  });
}
