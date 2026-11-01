import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/schema.dart';
import 'package:wallet_log/summary_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);
  late Directory dir;
  setUp(() async {
    await TxDb.close();
    dir = await Directory.systemTemp.createTemp('wallet-sync-');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  tearDown(() async {
    await TxDb.close();
    await dir.delete(recursive: true);
  });

  Account acct(String wallet, String number, {int? sub, int? id}) => Account(
      id: id,
      name: '$wallet $number',
      wallet: wallet,
      number: number,
      subId: sub,
      slot: null);

  test('an account made by the setup wizard becomes a usable wallet', () async {
    await TxDb.saveAccount(acct('Vodafone Cash', '01011111111'));
    final ws = await TxDb.wallets();
    final w = await ws.wallets();
    expect(w.single.providerCode, 'vodafone_cash');
    expect(w.single.phone, '01011111111');
    // edits follow, repeated saves do not duplicate
    final id = (await TxDb.accounts()).single.id;
    await TxDb.saveAccount(acct('Vodafone Cash', '01022222222', id: id));
    expect((await ws.wallets()).single.phone, '01022222222');
    // removing the account archives the wallet but keeps it (and its history)
    await TxDb.deleteAccount(id!);
    expect(await ws.wallets(), isEmpty);
    expect(await ws.wallets(includeArchived: true), hasLength(1));
  });

  test('imported SMS is attributed only when exactly one wallet can own it',
      () async {
    await TxDb.saveAccount(acct('Vodafone Cash', '01011111111', sub: 1));
    await TxDb.importSms([
      const RawSms(
          'VF-Cash',
          'You have received 100.00 EGP from 01012345678. Your balance is EGP 500.00',
          1700000000000,
          1),
    ]);
    final db = (await TxDb.wallets()).db;
    final w1 = (await db.query('wallet_accounts')).single['id'];
    expect((await db.query('tx')).single['wallet_account_id'], w1);

    // a second Vodafone wallet on another SIM: the SIM decides
    await TxDb.saveAccount(acct('Vodafone Cash', '01033333333', sub: 2));
    await TxDb.importSms([
      const RawSms(
          'VF-Cash',
          'You have received 50.00 EGP from 01012345678. Your balance is EGP 550.00',
          1700000100000,
          2),
    ]);
    final rows = await db.query('tx', orderBy: 'ts');
    expect(rows.last['wallet_account_id'], isNot(w1));
    // no SIM info and two candidates: left for the owner, never guessed
    await db.insert('tx', {
      'k': 'amb',
      'ts': 1,
      'wallet': 'Vodafone Cash',
      'dir': 'in',
      'amount_minor': 100,
      'source': 'sms',
      'body': 'x'
    });
    await autoLinkTransactions(db);
    expect(
        (await db.query('tx', where: "k = 'amb'")).single['wallet_account_id'],
        isNull);
  });

  test('dashboard sees the wizard wallet and its confirmed SMS', () async {
    await TxDb.saveAccount(acct('Vodafone Cash', '01011111111', sub: 1));
    final ws = await TxDb.wallets();
    final id = (await ws.wallets()).single.id;
    await ws.setOpening(id, 100000, '2020-01-01');
    await TxDb.importSms([
      const RawSms(
          'VF-Cash',
          'You have received 100.00 EGP from 01012345678. Your balance is EGP 1,100.00',
          1700000000000,
          1),
    ]);
    final d = await SummaryService(ws.db).dashboard();
    expect(d.wallets.single.totals.confirmedBalanceMinor, 110000);
    expect(d.incomeMinor, 10000);
  });
}
