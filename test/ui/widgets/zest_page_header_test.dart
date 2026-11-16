import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_page_header.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('ZestPageHeader', () {
    // `metaLine` is a required, non-nullable String on the constructor, so a
    // header with no meta line simply will not compile - this suite exercises
    // only the runtime render, the absence guarantee is enforced at build time.
    testWidgets('renders title and metaLine', (tester) async {
      await tester.pumpWidget(_host(const ZestPageHeader(
        title: 'Hosts',
        metaLine: '12 connections · 3 groups',
      )));
      expect(find.text('Hosts'), findsOneWidget);
      expect(find.text('12 connections · 3 groups'), findsOneWidget);
    });

    testWidgets('renders actions on the title row', (tester) async {
      await tester.pumpWidget(_host(ZestPageHeader(
        title: 'Hosts',
        metaLine: 'meta',
        actions: [
          ZestButton(label: 'New', onPressed: () {}),
        ],
      )));
      expect(find.text('New'), findsOneWidget);
      expect(find.byType(ZestButton), findsOneWidget);
    });
  });
}
