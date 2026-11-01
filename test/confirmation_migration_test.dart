import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/confirmation_rules.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/importer.dart';
import 'package:wallet_log/parser.dart';
import 'package:wallet_log/schema.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);

  group('message content decides completion', () {
    test('completed', () {
      for (final b in [
        'You have received 1,250.50 EGP from 01012345678. Your balance is EGP 3,400.00',
        'تم تحويل 100 جنيه بنجاح الى 01012345678',
        'تم استلام 500 جنيه من 01099999999',
        'تم سحب 200 جنيه من ATM',
      ]) {
        expect(classifySmsCompletion(b), SmsOutcome.completed, reason: b);
      }
    });
    test('failed, pending, otp and plain notices are not completed', () {
      expect(classifySmsCompletion('فشلت عملية تحويل 100 جنيه'),
          SmsOutcome.failed);
      expect(
          classifySmsCompletion(
              'Transaction of 100 EGP failed. Insufficient balance'),
          SmsOutcome.failed);
      expect(
          classifySmsCompletion('تم رفض العملية 100 جنيه'), SmsOutcome.failed);
      expect(classifySmsCompletion('عملية تحويل 100 جنيه قيد المعالجة'),
          SmsOutcome.pending);
      expect(classifySmsCompletion('Your transfer of 100 EGP is pending'),
          SmsOutcome.pending);
      expect(classifySmsCompletion('رمز التحقق 1234 لتحويل 100 جنيه'),
          SmsOutcome.unclear);
      expect(classifySmsCompletion('رصيدك 100 جنيه'), SmsOutcome.unclear);
    });
  });

  group('v9 re-judges legacy rows', () {
    late Directory dir;
    setUp(() async {
      await TxDb.close();
      dir = await Directory.systemTemp.createTemp('wallet-conf-');
      await databaseFactory.setDatabasesPath(dir.path);
    });
    tearDown(() async {
      await TxDb.close();
      await dir.delete(recursive: true);
    });

    Future<void> legacy(dynamic db, int id, String source, String body,
            {String conf = 'provider_confirmed'}) =>
        db.insert('tx', {
          'id': id,
          'k': 'l$id',
          'ts': 1000 + id,
          'wallet': 'Vodafone Cash',
          'dir': 'in',
          'amount': 1.0,
          'amount_minor': 100,
          'body': body,
          'source': source,
          'confirmation': conf,
          'confirmed_at': 1000 + id,
        });

    test('each source and content state, with audit and no evidence loss',
        () async {
      final db = (await TxDb.wallets()).db;
      // State left by the earlier blanket back-fill: everything "confirmed", no method.
      await legacy(db, 1, 'sms', 'You have received 5.00 EGP from 01012345678');
      await legacy(db, 2, 'sms', 'فشلت عملية تحويل 100 جنيه');
      await legacy(db, 3, 'sms', 'عملية تحويل 100 جنيه قيد المعالجة');
      await legacy(db, 4, 'sms', 'رصيدك 100 جنيه');
      await legacy(db, 5, 'excel', 'sheet row');
      await legacy(db, 6, 'manual', '', conf: 'awaiting');
      await legacy(db, 7, 'sms', 'تم تحويل 10 جنيه',
          conf: 'awaiting'); // never confirmed before
      await db.insert('evidence',
          {'tx_id': 5, 'kind': 'other', 'origin': 'other', 'created_at': 1});
      await applyV9(db);
      Future<Map<String, Object?>> r(int id) async =>
          (await db.query('tx', where: 'id = ?', whereArgs: [id])).first;
      expect(
          [(await r(1))['confirmation'], (await r(1))['confirmation_method']],
          ['provider_confirmed', 'sms_content']);
      expect((await r(2))['confirmation'], 'failed');
      expect((await r(3))['confirmation'], 'awaiting');
      expect((await r(4))['confirmation'], 'awaiting');
      expect([(await r(5))['confirmation'], (await r(5))['confirmed_at']],
          ['awaiting', null]); // sheet import
      expect((await r(6))['confirmation'], 'awaiting'); // manual untouched
      expect(
          [(await r(7))['confirmation'], (await r(7))['confirmation_method']],
          ['provider_confirmed', 'sms_content']);
      // downgrades are audited; unchanged rows are not
      expect(
          (await db.query('audit_events', where: "tx_id IN (2,3,4,5)")).length,
          4);
      expect(await db.query('audit_events', where: 'tx_id = 1'), isEmpty);
      expect(await db.query('evidence'), hasLength(1));
      // running again changes nothing (idempotent)
      final before = await db.query('audit_events');
      await applyV9(db);
      expect((await db.query('audit_events')).length, before.length);
    });

    test('owner decisions made before the migration are not overridden',
        () async {
      final db = (await TxDb.wallets()).db;
      await legacy(db, 1, 'sms', 'رصيدك 100 جنيه');
      await db.insert('audit_events', {
        'tx_id': 1,
        'event': 'confirmation',
        'field': 'confirmation',
        'old_value': 'awaiting',
        'new_value': 'provider_confirmed',
        'source': 'manual',
        'ts': 1
      });
      await applyV9(db);
      expect((await db.query('tx', where: 'id = 1')).first['confirmation'],
          'provider_confirmed');
    });

    test(
        'fresh SMS import: completed confirmed by content, failed/pending are not',
        () async {
      await TxDb.importSms([
        const RawSms(
            'VF-Cash',
            'You have received 100.00 EGP from 01012345678. Your balance is EGP 500.00',
            1700000000000,
            null),
        const RawSms('VF-Cash', 'تم تحويل 50 جنيه الى 01012345678 قيد المعالجة',
            1700000100000, null),
      ]);
      final db = (await TxDb.wallets()).db;
      final rows = await db.query('tx', orderBy: 'ts');
      expect(rows[0]['confirmation'], 'provider_confirmed');
      expect(rows[0]['confirmation_method'], 'sms_content');
      expect(rows.length < 2 || rows[1]['confirmation'] == 'awaiting', isTrue);
    });

    test('Excel import stays unverified, even with evidence attached',
        () async {
      await TxDb.importRows([
        const ImportRow(
            key: 'xlsx|1',
            ts: 1700000000000,
            wallet: 'Vodafone Cash',
            type: TxType.transfer,
            dir: Dir.inFlow,
            amount: 100,
            fee: 0,
            party: null,
            note: '',
            body: 'تم استلام 100 جنيه'),
      ]);
      final db = (await TxDb.wallets()).db;
      final r = (await db.query('tx')).single;
      expect([
        r['source'],
        r['confirmation'],
        r['confirmation_method'],
        r['confirmed_at']
      ], [
        'excel',
        'awaiting',
        null,
        null
      ]);
      await db.insert('evidence', {
        'tx_id': r['id'],
        'kind': 'receipt',
        'origin': 'receipt',
        'created_at': 1
      });
      expect((await db.query('tx')).single['confirmation'], 'awaiting');
    });

    test('attaching evidence never changes the status', () async {
      final db = (await TxDb.wallets()).db;
      await legacy(db, 1, 'manual', '', conf: 'awaiting');
      await db.insert('evidence', {
        'tx_id': 1,
        'kind': 'receipt',
        'origin': 'receipt',
        'created_at': 1
      });
      expect((await db.query('tx', where: 'id = 1')).first['confirmation'],
          'awaiting');
    });
  });
}
