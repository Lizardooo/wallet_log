import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/importer.dart';
import 'package:wallet_log/logic.dart';
import 'package:wallet_log/parser.dart';
import 'package:wallet_log/tabs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);
  late Directory dir;
  setUp(() async {
    await TxDb.close();
    dir = await Directory.systemTemp.createTemp('wallet-excel-wallet-');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  tearDown(() async {
    await TxDb.close();
    await dir.delete(recursive: true);
  });

  final day = DateTime(2026, 11, 2, 10);
  ImportRow row(String key, double amount, {String wallet = ''}) => ImportRow(
        key: key,
        ts: day.millisecondsSinceEpoch,
        wallet: wallet.isEmpty ? excelWalletFallback : wallet,
        type: TxType.transfer,
        dir: Dir.inFlow,
        amount: amount,
        party: '01099999999',
      );

  /// Two Vodafone Cash numbers that live on other phones: no SIM on this one,
  /// so matching by wallet type alone cannot tell them apart.
  Future<List<Account>> twoPhones() async {
    for (final n in ['01011111111', '01022222222']) {
      await TxDb.saveAccount(Account(
          id: null,
          name: 'Vodafone Cash $n',
          wallet: 'Vodafone Cash',
          number: n,
          subId: null,
          slot: null));
    }
    return TxDb.accounts();
  }

  test('a file imported for a chosen wallet is reported under that wallet',
      () async {
    final acc = await twoPhones();
    final rows = [row('r1', 100), row('r2', 250, wallet: 'InstaPay')];

    expect(await TxDb.importRows(rows, account: acc[0]), 2);
    // The same file for the second phone is a different wallet's report.
    expect(await TxDb.importRows([row('r1', 100)], account: acc[1]), 1);
    // Importing again for the same wallet adds nothing.
    expect(await TxDb.importRows(rows, account: acc[0]), 0);

    final txs = await TxDb.allTx();
    expect(txs, hasLength(3));
    for (final t in txs) {
      expect(t.review, isFalse);
      expect(accountFor(t, acc), isNotNull);
    }

    final daily = dailyRows(dayKey(day), txs, acc, {});
    expect(daily, hasLength(2), reason: 'no "unlinked" row');
    expect(daily[0].account!.id, acc[0].id);
    expect(daily[0].inSum, 350);
    expect(daily[0].txs.map((t) => t.amount), [100, 250]);
    expect(daily[1].account!.id, acc[1].id);
    expect(daily[1].inSum, 100);
  });

  test('a row imported earlier without a wallet is not duplicated', () async {
    final acc = await twoPhones();
    expect(await TxDb.importRows([row('old', 70)]), 1);
    expect(await TxDb.importRows([row('old', 70)], account: acc[0]), 0);
  });

  testWidgets('the daily report shows or hides the day\'s transactions',
      (tester) async {
    final acc = await tester.runAsync(twoPhones);
    await tester
        .runAsync(() => TxDb.importRows([row('r1', 125)], account: acc![0]));
    final txs = (await tester.runAsync(TxDb.allTx))!;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DailyTab(
          txs: txs,
          accounts: acc!,
          openings: const {},
          onSetOpening: (_, __, ___) async {},
        ),
      ),
    ));
    await tester.pump();
    // Move to the imported day.
    final back = DateTime(2026, 11, 2)
        .difference(DateTime(
            DateTime.now().year, DateTime.now().month, DateTime.now().day))
        .inDays;
    for (var i = 0; i < -back; i++) {
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
    }

    expect(find.text('+125.00'), findsNothing);
    final toggle = find.byKey(const ValueKey('daily-show-tx'));
    await tester.scrollUntilVisible(toggle, 100);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('+125.00'), findsOneWidget);
    expect(find.text('لا توجد معاملات في هذا اليوم'), findsOneWidget,
        reason: 'the second wallet had nothing that day');

    final saved = await tester.runAsync(() => TxDb.setting(settingDailyShowTx));
    expect(saved, '1');

    await tester.tap(toggle);
    await tester.pump();
    expect(find.text('لا توجد معاملات في هذا اليوم'), findsNothing);
  });
}
