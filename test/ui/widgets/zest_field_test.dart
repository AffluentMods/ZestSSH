import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('ZestField placeholder-vs-value contrast rule', () {
    testWidgets('a stored value renders bright (textPrimary)', (tester) async {
      await tester.pumpWidget(_host(const ZestField(
        label: 'Host',
        value: 'localhost',
      )));
      await tester.pumpAndSettle();

      // The value is the field TEXT: EditableText carries the bright style.
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.controller.text, 'localhost');
      expect(editable.style.color, ZestTokens.textPrimary);
    });

    testWidgets('a placeholder renders dim (textPlaceholder)', (tester) async {
      await tester.pumpWidget(_host(const ZestField(
        label: 'Host',
        placeholder: 'localhost',
      )));
      await tester.pumpAndSettle();

      // The placeholder is the empty-state HINT: a separate dim Text.
      final hint = tester.widget<Text>(find.text('localhost'));
      expect(hint.style?.color, ZestTokens.textPlaceholder);

      // ...and the two colours are genuinely different (the whole point).
      expect(ZestTokens.textPlaceholder, isNot(ZestTokens.textPrimary));
    });
  });

  group('ZestField structure', () {
    testWidgets('never uses a notched Material label (no labelText)',
        (tester) async {
      await tester.pumpWidget(_host(const ZestField(
        label: 'Host',
        placeholder: 'localhost',
        helperText: 'The server address',
      )));

      final textFields = tester.widgetList<TextField>(find.byType(TextField));
      expect(textFields, isNotEmpty);
      for (final tf in textFields) {
        expect(tf.decoration?.labelText, isNull);
      }
    });

    testWidgets('errorText wins over helperText and renders critical',
        (tester) async {
      await tester.pumpWidget(_host(const ZestField(
        label: 'Host',
        helperText: 'The server address',
        errorText: 'Host is required',
      )));

      expect(find.text('Host is required'), findsOneWidget);
      expect(find.text('The server address'), findsNothing);
      final err = tester.widget<Text>(find.text('Host is required'));
      expect(err.style?.color, ZestTokens.statusCritical);
    });
  });

  group('ZestFieldGroup', () {
    testWidgets('two grouped fields share ONE label cell', (tester) async {
      await tester.pumpWidget(_host(const ZestFieldGroup(
        label: 'Endpoint',
        fields: [
          ZestField.grouped(label: 'Host', value: 'example.com'),
          ZestField.grouped(label: 'Port', value: '22'),
        ],
      )));
      await tester.pumpAndSettle();

      // The shared cell shows the group label exactly once...
      expect(find.text('Endpoint'), findsOneWidget);
      // ...and the grouped children draw no label cell of their own.
      expect(find.text('Host'), findsNothing);
      expect(find.text('Port'), findsNothing);

      // Both inputs are still present.
      expect(find.byType(EditableText), findsNWidgets(2));
    });
  });
}
