import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/logic.dart';
import 'package:wallet_log/parser.dart';
import 'package:wallet_log/tabs.dart';

final firstDay = DateTime(2026, 11, 1, 13);
const accounts = [
  Account(id: 1, name: 'VF 1', wallet: 'Vodafone Cash', subId: 11),
  Account(id: 2, name: 'VF 2', wallet: 'Vodafone Cash', subId: 22),
];
Tx tx(
  int id,
  DateTime when, {
  Dir dir = Dir.inFlow,
  bool review = false,
  TxType type = TxType.transfer,
  int subId = 11,
}) =>
    Tx(
      id: id,
      ts: when.millisecondsSinceEpoch,
      wallet: 'Vodafone Cash',
      type: type,
      dir: dir,
      amount: id * 10,
      subId: subId,
      party: 'party-$id',
      review: review,
    );
Widget app(Widget child) => MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: Scaffold(body: child),
    );
Finder chip(String label) => find.widgetWithText(ChoiceChip, label);
bool selected(WidgetTester tester, String label) =>
    tester.widget<ChoiceChip>(chip(label)).selected;
Future<void> openFilters(WidgetTester tester) async {
  await tester.tap(find.byTooltip('تصفية'));
  await tester.pumpAndSettle();
}

Future<void> closeFilters(WidgetTester tester) async {
  await tester.tap(find.text('عرض النتائج'));
  await tester.pumpAndSettle();
}

Future<void> showTransactions(
  WidgetTester tester,
  TxFilter filter,
  List<Tx> rows,
) async {
  await tester.pumpWidget(
    app(
      TransactionsTab(
        txs: rows,
        accounts: accounts,
        filter: filter,
        mismatches: const {},
        onChanged: () {},
        onTap: (_) {},
        onRefresh: () async {},
        now: () => firstDay,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'month shortcut is exclusive on day one and keeps today results',
    (tester) async {
      final f = TxFilter();
      await showTransactions(tester, f, [
        tx(1, DateTime(2026, 10, 31, 23, 59)),
        tx(2, DateTime(2026, 11, 1, 8)),
      ]);
      await openFilters(tester);
      await tester.tap(chip('هذا الشهر'));
      await tester.pumpAndSettle();
      expect(selected(tester, 'هذا الشهر'), isTrue);
      expect(selected(tester, 'اليوم'), isFalse);
      expect(selected(tester, '7 أيام'), isFalse);
      expect(f.date.period, DatePeriod.thisMonth);
      await closeFilters(tester);
      expect(find.text('party-2'), findsOneWidget);
      expect(find.text('party-1'), findsNothing);
      await openFilters(tester);
      expect(selected(tester, 'هذا الشهر'), isTrue);
      await tester.tap(chip('اليوم'));
      await tester.pumpAndSettle();
      expect(selected(tester, 'اليوم'), isTrue);
      expect(selected(tester, 'هذا الشهر'), isFalse);
    },
  );

  testWidgets('custom date picker apply and cancel preserve explicit selection',
      (tester) async {
    final f = TxFilter(period: DatePeriod.thisMonth);
    await showTransactions(tester, f, [tx(1, firstDay)]);
    await openFilters(tester);
    await tester.tap(chip('نطاق محدد'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(f.date.period, DatePeriod.thisMonth);
    expect(selected(tester, 'هذا الشهر'), isTrue);
    await tester.tap(chip('نطاق محدد'));
    await tester.pumpAndSettle();
    final saveLabel = MaterialLocalizations.of(
            tester.element(find.byType(DateRangePickerDialog)))
        .saveButtonLabel;
    await tester.tap(find.text(saveLabel));
    await tester.pumpAndSettle();
    expect(f.date.period, DatePeriod.custom);
    expect(selected(tester, '2026-11-01 – 2026-11-01'), isTrue);
    expect(selected(tester, 'اليوم'), isFalse);
    expect(selected(tester, 'هذا الشهر'), isFalse);
    await closeFilters(tester);
    expect(find.text('party-1'), findsOneWidget);
  });

  testWidgets('same-day custom range does not select any shortcut', (
    tester,
  ) async {
    final f = TxFilter()..date.setCustom(firstDay, firstDay);
    await showTransactions(tester, f, [tx(1, firstDay)]);
    await openFilters(tester);
    expect(selected(tester, 'اليوم'), isFalse);
    expect(selected(tester, 'هذا الشهر'), isFalse);
    expect(selected(tester, '2026-11-01 – 2026-11-01'), isTrue);
  });

  testWidgets('all date shortcuts return the expected transactions', (
    tester,
  ) async {
    final f = TxFilter();
    await showTransactions(tester, f, [
      tx(1, DateTime(2026, 10, 20)),
      tx(2, DateTime(2026, 10, 31, 23, 59)),
      tx(3, DateTime(2026, 11, 1, 8)),
    ]);
    for (final entry in {
      'اليوم': [3],
      'أمس': [2],
      '7 أيام': [2, 3],
      'هذا الشهر': [3],
      'الكل': [1, 2, 3],
    }.entries) {
      await openFilters(tester);
      // "All" also labels the account choice; the last chip is the date one.
      await tester.tap(chip(entry.key).last);
      await tester.pumpAndSettle();
      await closeFilters(tester);
      for (var id = 1; id <= 3; id++) {
        expect(
          find.text('party-$id'),
          entry.value.contains(id) ? findsOneWidget : findsNothing,
          reason: entry.key,
        );
      }
    }
  });

  testWidgets(
    'account, type and direction combine; clear resets direction too',
    (tester) async {
      final f = TxFilter();
      await showTransactions(tester, f, [
        tx(1, firstDay),
        tx(2, firstDay, dir: Dir.outFlow, type: TxType.bill),
        tx(3, firstDay, subId: 22),
      ]);
      await tester.tap(find.text('خارج').first);
      await tester.pumpAndSettle();
      expect(find.text('party-2'), findsOneWidget);
      expect(find.text('party-1'), findsNothing);
      // Summary follows the direction actually visible on screen.
      expect(find.text('0.00'), findsOneWidget);
      await openFilters(tester);
      await tester.tap(chip('VF 1'));
      await tester.tap(find.widgetWithText(FilterChip, 'فواتير وخدمات'));
      await tester.pumpAndSettle();
      await closeFilters(tester);
      expect(find.text('party-2'), findsOneWidget);
      expect(
        f.matches(
          tx(2, firstDay, dir: Dir.outFlow, type: TxType.bill),
          accounts,
        ),
        isTrue,
      );
      await openFilters(tester);
      await tester.tap(find.text('مسح الكل'));
      await tester.pumpAndSettle();
      await closeFilters(tester);
      expect(f.isActive, isFalse);
      expect(find.text('party-1'), findsOneWidget);
      expect(find.text('party-2'), findsOneWidget);
      expect(find.text('party-3'), findsOneWidget);
    },
  );

  testWidgets(
    'review still works with an outgoing filter and unknown direction',
    (tester) async {
      final f = TxFilter()..dir = Dir.outFlow;
      await showTransactions(tester, f, [
        tx(1, firstDay),
        tx(2, firstDay, dir: Dir.unknown, review: true),
      ]);
      expect(find.text('party-2'), findsNothing);
      await tester.tap(find.byTooltip('تحتاج مراجعة'));
      await tester.pumpAndSettle();
      expect(find.text('party-2'), findsOneWidget);
      expect(f.reviewOnly, isTrue);
      expect(
        f.matches(tx(2, firstDay, dir: Dir.unknown, review: true), accounts),
        isTrue,
      );
      await tester.tap(find.byTooltip('رجوع'));
      await tester.pumpAndSettle();
      expect(f.reviewOnly, isFalse);
      expect(f.dir, Dir.outFlow);
    },
  );

  testWidgets(
    'reports shortcuts share correct bounds and exclusive selection',
    (tester) async {
      final f = TxFilter(period: DatePeriod.thisMonth);
      await tester.pumpWidget(
        app(
          ReportsTab(
            txs: [
              tx(1, DateTime(2026, 10, 31)),
              tx(2, firstDay),
              tx(3, DateTime(2026, 11, 2)),
            ],
            accounts: accounts,
            filter: f,
            onChanged: () async {},
            now: () => firstDay,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(selected(tester, 'هذا الشهر'), isTrue);
      expect(selected(tester, 'اليوم'), isFalse);
      expect(find.text('20.00'), findsWidgets);
      for (final entry in {
        'اليوم': DatePeriod.today,
        '7 أيام': DatePeriod.last7Days,
        '30 يوم': DatePeriod.last30Days,
        'الكل': DatePeriod.all,
        'هذا الشهر': DatePeriod.thisMonth,
      }.entries) {
        await tester.tap(chip(entry.key));
        await tester.pumpAndSettle();
        expect(f.date.period, entry.value);
        expect(
          tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).where(
                (c) =>
                    c.selected &&
                    c.label is Text &&
                    [
                      'اليوم',
                      '7 أيام',
                      '30 يوم',
                      'الكل',
                      'هذا الشهر',
                    ].contains((c.label as Text).data),
              ),
          hasLength(1),
        );
      }
      await tester.tap(chip('VF 2'));
      await tester.pumpAndSettle();
      expect(f.accountId, 2);
      expect(find.text('0.00'), findsWidgets);
      await tester.tap(chip('كل المحافظ'));
      await tester.pumpAndSettle();
      expect(f.accountId, isNull);
    },
  );
}
