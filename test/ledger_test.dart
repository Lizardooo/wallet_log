import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/ledger_service.dart';
import 'package:wallet_log/logic.dart';
import 'package:wallet_log/parser.dart';
import 'package:wallet_log/schema.dart';
import 'package:wallet_log/wallet_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);
  late Directory dir;
  late LedgerService led;
  late WalletStore ws;
  late int w1, w2;

  Future<int> addTx(int id, int ts, String dir, int amount,
      {int fee = 0, int? wallet, String body = 'original sms'}) async {
    await ws.db.insert('tx', {
      'id': id,
      'k': 'k$id',
      'ts': ts,
      'wallet': 'Vodafone Cash',
      'dir': dir,
      'type': 'transfer',
      'amount': amount / 100.0,
      'amount_minor': amount,
      'fee': fee / 100.0,
      'fee_minor': fee,
      'body': body,
      'wallet_account_id': wallet ?? w1,
    });
    return id;
  }

  Future<Map<String, Object?>> row(int id) async =>
      (await ws.db.query('tx', where: 'id = ?', whereArgs: [id])).first;

  setUp(() async {
    await TxDb.close();
    dir = await Directory.systemTemp.createTemp('wallet-ledger-');
    await databaseFactory.setDatabasesPath(dir.path);
    ws = await TxDb.wallets();
    led = await TxDb.ledger();
    final p = await ws.providerId('vodafone_cash');
    w1 = await ws.addWallet(
        providerId: p, phone: '01011111111', openingMinor: 100000);
    w2 = await ws.addWallet(
        providerId: await ws.providerId('orange_cash'), phone: '01022222222');
  });
  tearDown(() async {
    await TxDb.close();
    await dir.delete(recursive: true);
  });

  test('audit history is append-only', () async {
    await addTx(1, 1000, 'out', 10000);
    await led.correct(1, {CorrectableField.amount: 12000}, reason: 'typo');
    final h = await led.history(1);
    expect(h, hasLength(1));
    await expectLater(
        ws.db.update('audit_events', {'new_value': '1'}), throwsA(anything));
    await expectLater(ws.db.delete('audit_events'), throwsA(anything));
    await expectLater(ws.db.delete('audit_groups'), throwsA(anything));
    expect(await led.history(1), hasLength(1));
  });

  test('amount correction keeps original, evidence and records why', () async {
    await addTx(1, 1000, 'out', 10000, body: 'تم تحويل 100 جنيه');
    final n = await led.correct(1, {CorrectableField.amount: 15000},
        source: AuditSource.manual, reason: 'sms was truncated');
    expect(n, 1);
    final r = await row(1);
    expect(r['amount_minor'], 15000);
    expect(r['amount'], 150.0);
    expect(r['body'], 'تم تحويل 100 جنيه'); // evidence untouched
    expect(r['manual'], 1);
    final e = (await led.history(1)).single;
    expect([
      e['event'],
      e['field'],
      e['old_value'],
      e['new_value'],
      e['source'],
      e['reason']
    ], [
      'correct',
      'amount_minor',
      '10000',
      '15000',
      'manual',
      'sms was truncated'
    ]);
    expect(e['related_id'], isNotNull);
    expect(await led.originalValue(1, CorrectableField.amount), '10000');
    // The original SMS text cannot be replaced even by direct SQL.
    await expectLater(ws.db.update('tx', {'body': 'edited'}, where: 'id = 1'),
        throwsA(anything));
  });

  test('direction, category, fee, date, description and balances', () async {
    await addTx(1, 1000, 'in', 5000);
    final n = await led.correct(
        1,
        {
          CorrectableField.dir: 'out',
          CorrectableField.type: 'cashOut',
          CorrectableField.fee: 200,
          CorrectableField.ts: 2000,
          CorrectableField.note: 'atm',
          CorrectableField.balanceBefore: 100000,
          CorrectableField.balanceAfter: 94800,
        },
        reason: 'fix');
    expect(n, 7);
    final r = await row(1);
    expect([
      r['dir'],
      r['type'],
      r['fee_minor'],
      r['fee'],
      r['ts'],
      r['note'],
      r['balance_before_minor'],
      r['balance_minor'],
      r['balance']
    ], [
      'out',
      'cashOut',
      200,
      2.0,
      2000,
      'atm',
      100000,
      94800,
      948.0
    ]);
    expect(await led.originalValue(1, CorrectableField.dir), 'in');
    expect(await led.originalValue(1, CorrectableField.ts), '1000');
    await expectLater(led.correct(1, {CorrectableField.dir: 'sideways'}),
        throwsA(isA<LedgerException>()));
  });

  test('unconverted legacy REAL is preserved as the previous value', () async {
    await ws.db.insert('tx', {
      'id': 5,
      'k': 'k5',
      'ts': 1,
      'wallet': 'Vodafone Cash',
      'dir': 'in',
      'amount': 12.345,
      'body': 'x'
    });
    await led.correct(5, {CorrectableField.amount: 1235});
    expect((await led.history(5)).single['old_value'], 'legacy_real:12.345');
  });

  test('wallet association change is audited on both sides', () async {
    await addTx(1, 1000, 'in', 5000);
    await addTx(2, 2000, 'in', 100);
    await led.correct(1, {CorrectableField.walletAccount: w2},
        reason: 'wrong wallet');
    final r = await row(1);
    expect(r['wallet_account_id'], w2);
    expect(r['wallet'], 'Orange Cash');
    final fields = (await led.history(1)).map((e) => e['field']).toList();
    expect(fields, containsAll(['wallet_account_id', 'wallet']));
    expect(await led.originalValue(1, CorrectableField.walletAccount), '$w1');
    // The wallet it left must be re-validated from that date.
    expect(await led.needsRevalidation(2), isTrue);
    expect(await led.needsRevalidation(1), isTrue);
    await expectLater(led.correct(1, {CorrectableField.walletAccount: 9999}),
        throwsA(anything));
  });

  test('consecutive corrections chain; unchanged values write nothing',
      () async {
    await addTx(1, 1000, 'out', 10000);
    await led.correct(1, {CorrectableField.amount: 15000});
    await led.correct(1, {CorrectableField.amount: 17500}, reason: 'again');
    expect(await led.correct(1, {CorrectableField.amount: 17500}), 0);
    final h = await led.history(1);
    expect(h.map((e) => [e['old_value'], e['new_value']]), [
      ['10000', '15000'],
      ['15000', '17500']
    ]);
    expect(await led.originalValue(1, CorrectableField.amount), '10000');
    expect((await row(1))['amount_minor'], 17500);
  });

  test('a failed correction rolls back completely', () async {
    await addTx(1, 1000, 'out', 10000);
    await expectLater(
        led.correct(1, {
          CorrectableField.amount: 20000,
          CorrectableField.walletAccount: 9999
        }),
        throwsA(anything));
    expect((await row(1))['amount_minor'], 10000);
    expect(await led.history(1), isEmpty);
    expect(await ws.db.query('audit_groups'), isEmpty);
    expect(await led.openRevalidation(), isEmpty);
    await expectLater(led.correct(1, {CorrectableField.amount: -5}),
        throwsA(isA<LedgerException>()));
    await expectLater(led.correct(404, {CorrectableField.note: 'x'}),
        throwsA(isA<LedgerException>()));
  });

  test('full reversal: linked record, original intact, balance restored',
      () async {
    await addTx(1, 1000, 'out', 10000, fee: 200); // recharge 100 + fee 2
    expect((await led.calculatedBalance(w1)).balanceMinor, 89800);
    final before = await row(1);

    final rev = await led.reverse(1, reason: 'recharge failed');
    final r = await row(rev);
    expect([
      r['dir'],
      r['amount_minor'],
      r['fee_minor'],
      r['reverses_tx_id'],
      r['source'],
      r['note']
    ], [
      'in',
      10200,
      0,
      1,
      'reversal',
      'recharge failed'
    ]);
    expect(await row(1), before); // original not rewritten
    expect((await led.calculatedBalance(w1)).balanceMinor, 100000);
    final ev = await led.history(1);
    expect(ev.single['event'], 'reversed');
    expect(ev.single['new_value'], '$rev');
    expect((await led.history(rev)).single['event'], 'create');

    // Duplicate and chained reversals, and edits to a reversed pair, are refused.
    await expectLater(led.reverse(1, reason: 'again'),
        throwsA(isA<AlreadyReversedException>()));
    await expectLater(
        led.reverse(rev, reason: 'x'), throwsA(isA<LedgerException>()));
    await expectLater(led.correct(1, {CorrectableField.amount: 1}),
        throwsA(isA<LedgerException>()));
    await expectLater(led.correct(rev, {CorrectableField.note: 'x'}),
        throwsA(isA<LedgerException>()));
    expect(
        (await ws.db.query('tx', where: 'reverses_tx_id = 1')), hasLength(1));
    // Neither can be deleted.
    await expectLater(ws.db.delete('tx', where: 'id = 1'), throwsA(anything));
    await expectLater(ws.db.delete('tx', where: 'id = ?', whereArgs: [rev]),
        throwsA(anything));
  });

  test('reversal of an incoming transaction and unknown cases', () async {
    await addTx(1, 1000, 'in', 5000, fee: 100); // +49.00
    final rev = await led.reverse(1, reason: 'bounced');
    final r = await row(rev);
    expect([r['dir'], r['amount_minor']], ['out', 4900]);
    expect((await led.calculatedBalance(w1)).balanceMinor, 100000);

    await ws.db.insert('tx', {
      'id': 9,
      'k': 'k9',
      'ts': 1,
      'wallet': 'W',
      'dir': 'unknown',
      'amount': 1.0,
      'amount_minor': 100
    });
    await expectLater(
        led.reverse(9, reason: 'x'), throwsA(isA<LedgerException>()));
    await ws.db.insert('tx', {
      'id': 10,
      'k': 'k10',
      'ts': 1,
      'wallet': 'W',
      'dir': 'in',
      'amount': 12.345
    });
    await expectLater(
        led.reverse(10, reason: 'x'), throwsA(isA<LedgerException>()));
    expect(
        await ws.db.query('tx', where: 'reverses_tx_id IN (9, 10)'), isEmpty);
  });

  test('reports do not count a reversed pair', () async {
    await addTx(1, 1000, 'out', 10000, fee: 200);
    await addTx(2, 2000, 'in', 50000);
    await led.reverse(1, reason: 'r');
    final txs = await TxDb.allTx();
    expect(txs, hasLength(3)); // all still listed
    final totals = totalsOf(txs);
    expect(totals.outSum, 0);
    expect(totals.fee, 0);
    expect(totals.inSum, 500.0);
    expect(txs.firstWhere((t) => t.id == 1).reversed, isTrue);
    expect(txs.firstWhere((t) => t.reversalOf == 1).isExcluded, isTrue);
  });

  test(
      'balance-affecting corrections flag later transactions, never confirmed balances',
      () async {
    await ws.confirmBalance(w1, 123456);
    await addTx(1, 1000, 'in', 100);
    await addTx(2, 2000, 'in', 100);
    await addTx(3, 3000, 'in', 100);
    await led.correct(2, {CorrectableField.amount: 300});
    expect(await led.openRevalidation(), [2, 3]);
    expect(await led.needsRevalidation(1), isFalse);
    final w = (await ws.wallets()).firstWhere((x) => x.id == w1);
    expect(w.lastConfirmedMinor, 123456);
    // A category/description change does not invalidate anything.
    await led.clearRevalidation([2, 3]);
    await led.correct(
        2, {CorrectableField.type: 'refund', CorrectableField.note: 'n'});
    expect(await led.openRevalidation(), isEmpty);
    // Moving a date back flags from the earlier date.
    await led.correct(3, {CorrectableField.ts: 500});
    expect(await led.openRevalidation(), [1, 2, 3]);
  });

  test('manual transactions: created, audited, distinguishable', () async {
    final id = await led.createManual(
        walletAccountId: w1,
        amountMinor: 25000,
        dir: 'out',
        type: 'cashOut',
        feeMinor: 500,
        ts: 5000,
        description: 'agent withdrawal',
        balanceBeforeMinor: 100000,
        balanceAfterMinor: 74500);
    final r = await row(id);
    expect([
      r['source'],
      r['manual'],
      r['review'],
      r['wallet'],
      r['amount_minor'],
      r['fee_minor'],
      r['balance_minor'],
      r['balance_before_minor'],
      r['note']
    ], [
      'manual',
      1,
      0,
      'Vodafone Cash',
      25000,
      500,
      74500,
      100000,
      'agent withdrawal'
    ]);
    expect(r['k'].toString().startsWith('manual|'), isTrue);
    final ev = (await led.history(id)).single;
    expect(ev['event'], 'create');
    expect(ev['source'], 'manual');
    expect((await led.calculatedBalance(w1)).balanceMinor, 74500);
    final t = (await TxDb.allTx()).single;
    expect(t.source, 'manual');

    // Inconsistent verified balances are kept but flagged, not rejected.
    final bad = await led.createManual(
        walletAccountId: w1,
        amountMinor: 100,
        dir: 'in',
        type: 'other',
        ts: 6000,
        balanceBeforeMinor: 1000,
        balanceAfterMinor: 5000);
    expect((await row(bad))['review'], 1);
    // Validation.
    await expectLater(
        led.createManual(
            walletAccountId: w1,
            amountMinor: 0,
            dir: 'in',
            type: 'other',
            ts: 1),
        throwsA(isA<LedgerException>()));
    await expectLater(
        led.createManual(
            walletAccountId: w1,
            amountMinor: 1,
            dir: 'unknown',
            type: 'other',
            ts: 1),
        throwsA(isA<LedgerException>()));
    await expectLater(
        led.createManual(
            walletAccountId: 999,
            amountMinor: 1,
            dir: 'in',
            type: 'other',
            ts: 1),
        throwsA(isA<LedgerException>()));
    await ws.archiveWallet(w2);
    await expectLater(
        led.createManual(
            walletAccountId: w2,
            amountMinor: 1,
            dir: 'in',
            type: 'other',
            ts: 1),
        throwsA(isA<LedgerException>()));
  });

  test('transactions before the opening date are not counted', () async {
    await ws.db.update('wallet_accounts', {'opening_date': '2026-01-01'},
        where: 'id = ?', whereArgs: [w1]);
    await addTx(1, 1000, 'out', 5000); // 1970: before the opening balance
    await addTx(2, DateTime(2026, 2, 1).millisecondsSinceEpoch, 'out', 2000);
    final b = await led.calculatedBalance(w1);
    expect([b.balanceMinor, b.counted], [98000, 1]);
  });

  test('a missing opening balance gives no balance, not zero', () async {
    await addTx(1, 1000, 'in', 100, wallet: w2);
    final b = await led.calculatedBalance(w2);
    expect(b.balanceMinor, isNull);
    expect(b.counted, 1);
  });

  test(
      'audit history persists across restart; rescans never overwrite corrections',
      () async {
    final sms = RawSms('VF-Cash', 'تم تحويل 500 جنيه إلى 01012345678 بنجاح.',
        DateTime(2026, 11, 2, 12).millisecondsSinceEpoch, null);
    await TxDb.importSms([sms]);
    final id = (await TxDb.allTx()).single.id;
    await TxDb.setNote(id, 'client A');
    await TxDb.setClass(id, TxType.cashOut, Dir.outFlow);
    await led.correct(id, {CorrectableField.amount: 51000},
        reason: 'fee included');

    await TxDb.close(); // restart
    final led2 = await TxDb.ledger();
    final h = await led2.history(id);
    expect(h.map((e) => e['field']),
        containsAll(['note', 'type', 'amount_minor']));

    await TxDb.importSms([sms]); // rescan
    final t = (await TxDb.allTx()).single;
    expect(t.amount, 510.0);
    expect(t.type, TxType.cashOut);
    expect(t.note, 'client A');
    expect(t.body, sms.body);
    expect(await led2.history(id), hasLength(h.length));
  });

  test('v6 database upgrades to v7 with every row and no data change',
      () async {
    await TxDb.close();
    final d2 = await Directory.systemTemp.createTemp('wallet-v6-');
    await databaseFactory.setDatabasesPath(d2.path);
    final path = join(d2.path, 'wallet.db');
    final old = await openDatabase(path, version: 6, onCreate: (d, _) async {
      await createCore(d);
      await applyV6(d, 0);
    });
    await old.insert('tx', {
      'id': 21,
      'k': 'a',
      'ts': 5,
      'wallet': 'Orange Cash',
      'dir': 'out',
      'amount': 20.5,
      'amount_minor': 2050,
      'fee': 0.5,
      'fee_minor': 50,
      'note': 'keep',
      'body': 'b'
    });
    await old.close();
    final t = (await TxDb.allTx()).single;
    expect(
        [t.id, t.amount, t.fee, t.note, t.body], [21, 20.5, 0.5, 'keep', 'b']);
    await TxDb.close();
    final d = await openDatabase(path, singleInstance: false);
    expect(await d.rawQuery('PRAGMA user_version'), [
      {'user_version': schemaVersion}
    ]);
    expect(await integrityProblems(d), isEmpty);
    expect((await d.query('tx')).single['reverses_tx_id'], isNull);
    expect(await d.query('audit_events'), isEmpty);
    await d.close();
    await d2.delete(recursive: true);
  });
}
