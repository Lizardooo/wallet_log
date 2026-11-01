import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/exclusions.dart';
import 'package:wallet_log/parser.dart';
import 'package:wallet_log/review_actions.dart';
import 'package:wallet_log/review_tab.dart';
import 'package:wallet_log/tabs.dart';

List<Tx> messages() => [
      for (var i = 0; i < TxDisposition.values.length; i++)
        Tx(
          id: i + 1,
          ts: DateTime(2026, 11, 1).millisecondsSinceEpoch,
          wallet: 'Vodafone Cash',
          type: TxType.bill,
          dir: Dir.outFlow,
          amount: 100,
          review: true,
          disposition: TxDisposition.values[i],
          body:
              'رسالة طويلة للتجربة This message has numbers 100 EGP but might not be a transaction. ' *
                  3,
        )
    ];
Widget app(Widget child, {String locale = 'ar', double scale = 1}) =>
    MaterialApp(
      locale: Locale(locale),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate
      ],
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Scaffold(body: child),
    );
Widget review(
        {Future<void> Function(Tx)? onExclude,
        Future<void> Function(Tx)? onRestore}) =>
    ReviewTab(
      txs: messages(),
      accounts: const [],
      rules: const [
        ExclusionRule(
            id: 1,
            wallet: 'Vodafone Cash',
            match: ExclusionMatch.contains,
            text:
                'عبارة طويلة للتجاهل A distinctive non-transaction notification phrase')
      ],
      onOpen: (_) async {},
      onExclude: onExclude ?? (_) async {},
      onRestore: onRestore ?? (_) async {},
      onDeleteRule: (_) async {},
    );
Future<void> chooseBucket(WidgetTester tester, ReviewBucket bucket) async {
  await tester.tap(find.byType(DropdownButtonFormField<ReviewBucket>));
  await tester.pumpAndSettle();
  final item = find.byWidgetPredicate(
      (w) => w is DropdownMenuItem<ReviewBucket> && w.value == bucket);
  await tester.ensureVisible(item.last);
  final text = find.descendant(of: item.last, matching: find.byType(Text));
  await tester.tap(text.last);
  await tester.pumpAndSettle();
  expect(
      tester
          .widget<DropdownButton<ReviewBucket>>(
              find.byType(DropdownButton<ReviewBucket>))
          .value,
      bucket);
}

void main() {
  for (final locale in ['ar', 'en']) {
    for (final width in [320.0, 390.0, 768.0, 1200.0]) {
      testWidgets('review buckets render at $width in $locale with large text',
          (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(app(review(), locale: locale, scale: 1.6));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(Directionality.of(tester.element(find.byType(ReviewTab))),
            locale == 'ar' ? TextDirection.rtl : TextDirection.ltr);
        for (final bucket in ReviewBucket.values) {
          await chooseBucket(tester, bucket);
          expect(tester.takeException(), isNull, reason: bucket.name);
        }
      });
    }
    testWidgets('review renders at 320px and double text size in $locale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(review(), locale: locale, scale: 2));
      await tester.pumpAndSettle();
      for (final bucket in ReviewBucket.values) {
        await chooseBucket(tester, bucket);
        expect(tester.takeException(), isNull, reason: bucket.name);
      }
    });
    testWidgets(
        'exclusion dialog validates text and returns a scoped rule in $locale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ExclusionDecision? result;
      await tester.pumpWidget(app(
          Builder(
              builder: (context) => TextButton(
                    onPressed: () async {
                      result = await showExclusionDialog(
                          context, messages().first, messages());
                    },
                    child: const Text('open'),
                  )),
          locale: locale,
          scale: 1.6));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(TextFormField));
      await tester.enterText(find.byType(TextFormField), '  ');
      final button = find.widgetWithText(
          FilledButton, locale == 'ar' ? 'استبعاد' : 'Exclude');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(find.byType(TextFormField), 'distinctive notice');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(result!.disposition, TxDisposition.ignored);
      expect(result!.match, ExclusionMatch.exact);
      expect(result!.text, 'distinctive notice');
      expect(tester.takeException(), isNull);
    });
    testWidgets('existing transaction dialog can flag a message in $locale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TxEdit? decision;
      await tester.pumpWidget(app(
          Builder(
              builder: (context) => TextButton(
                  onPressed: () async {
                    decision =
                        await showTxDialog(context, messages().first, null);
                  },
                  child: const Text('open'))),
          locale: locale,
          scale: 1.6));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final exclude = find.widgetWithText(
          TextButton, locale == 'ar' ? 'استبعاد' : 'Exclude');
      await tester.ensureVisible(exclude);
      await tester.tap(exclude);
      await tester.pumpAndSettle();
      expect(decision!.exclude, isTrue);
      expect(decision!.confirm, isFalse);
      expect(tester.takeException(), isNull);
    });
    testWidgets('excluded-message details render on small $locale screens',
        (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(
          Builder(
              builder: (context) => TextButton(
                  onPressed: () =>
                      showExcludedMessage(context, messages().last),
                  child: const Text('open'))),
          locale: locale,
          scale: 1.6));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('review excludes and restores the selected record only',
      (tester) async {
    Tx? excluded;
    Tx? restored;
    await tester.pumpWidget(app(review(onExclude: (t) async {
      excluded = t;
    }, onRestore: (t) async {
      restored = t;
    })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('استبعاد'));
    await tester.pumpAndSettle();
    expect(excluded!.disposition, TxDisposition.active);
    await chooseBucket(tester, ReviewBucket.ignored);
    await tester.tap(find.text('إعادة للمراجعة'));
    await tester.pumpAndSettle();
    expect(restored!.disposition, TxDisposition.ignored);
    expect(restored!.id, isNot(excluded!.id));
  });
}
