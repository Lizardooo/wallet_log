import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/exclusions.dart';
import 'package:wallet_log/importer.dart';
import 'package:wallet_log/logic.dart';
import 'package:wallet_log/parser.dart';

String body(int amount, {String suffix = ''}) =>
    'تم تحويل $amount جنيه إلى 01012345678 بنجاح. $suffix';
RawSms sms(String text, int day, {String sender = 'VF-Cash'}) => RawSms(
    sender, text, DateTime(2026, 11, day, 12).millisecondsSinceEpoch, null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });
  late Directory dir;
  setUp(() async {
    await TxDb.close();
    dir = await Directory.systemTemp.createTemp('wallet-exclusions-');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  tearDown(() async {
    await TxDb.close();
    await dir.delete(recursive: true);
  });

  test('v4 migration preserves existing transaction provenance and data',
      () async {
    final old = await openDatabase(join(dir.path, 'wallet.db'), version: 4,
        onCreate: (db, _) async {
      await db.execute('CREATE TABLE tx(id INTEGER PRIMARY KEY AUTOINCREMENT, '
          'k TEXT UNIQUE, ts INTEGER, wallet TEXT, dir TEXT, type TEXT, '
          'amount REAL, fee REAL, party TEXT, balance REAL, sub_id INTEGER, '
          'review INTEGER, manual INTEGER, ai INTEGER, ai_note TEXT, note TEXT, body TEXT)');
    });
    final id = await old.insert('tx', {
      'k': smsKey(body(100), DateTime(2026, 11, 1).millisecondsSinceEpoch),
      'ts': DateTime(2026, 11, 1).millisecondsSinceEpoch,
      'wallet': 'Vodafone Cash',
      'dir': 'out',
      'type': 'transfer',
      'amount': 100.0,
      'fee': 1.0,
      'balance': 900.0,
      'review': 0,
      'manual': 1,
      'ai': 1,
      'note': 'keep my note',
      'ai_note': 'keep the reason',
      'body': body(100),
    });
    await old.close();
    final t = (await TxDb.allTx()).single;
    expect(t.id, id);
    expect(t.disposition, TxDisposition.active);
    expect(t.note, 'keep my note');
    expect(t.aiNote, 'keep the reason');
    expect(t.manual && t.ai, isTrue);
    expect(t.balance, 900);
    expect(t.fee, 1);
    expect(await TxDb.exclusionRules(), isEmpty);
    await TxDb.exclude(t.id, TxDisposition.ignored);
    expect((await TxDb.allTx()).single.isExcluded, isTrue);
  });

  for (final state in [
    TxDisposition.deferred,
    TxDisposition.ignored,
    TxDisposition.duplicate
  ]) {
    test('$state persists across rescan, restart and an in-flight AI response',
        () async {
      final raw = sms(body(150), 1);
      await TxDb.importSms([raw]);
      final original = (await TxDb.allTx()).single;
      await TxDb.setNote(original.id, 'preserved');
      await TxDb.exclude(original.id, state);
      await TxDb.importSms([raw]);
      await TxDb.applyAiUpdates([
        AiUpdate(
            id: original.id, type: TxType.bill, dir: Dir.inFlow, confirm: true)
      ]);
      await TxDb.setClass(original.id, TxType.bill, Dir.inFlow);
      await TxDb.close();
      final t = (await TxDb.allTx()).single;
      expect(t.disposition, state);
      expect(t.type, original.type);
      expect(t.dir, original.dir);
      expect(t.ai, isFalse);
      expect(t.note, 'preserved');
      expect(totalsOf([t]).count, 0);
      expect(TxFilter().matchesBase(t, []), isFalse);
    });
  }

  test(
      'exact rules apply retroactively and in future but preserve wallet scope',
      () async {
    final text = body(100);
    await TxDb.importSms([sms(text, 1), sms(text, 2)]);
    final selected = (await TxDb.allTx()).last;
    await TxDb.exclude(selected.id, TxDisposition.ignored,
        match: ExclusionMatch.exact, text: text);
    expect((await TxDb.allTx()).every((t) => t.isExcluded), isTrue);
    await TxDb.importSms([
      sms('  ${text.replaceAll('100', '١٠٠')}  ', 3),
      sms(text, 4, sender: 'Orange Cash'),
      sms(body(200), 5),
    ]);
    final rows = await TxDb.allTx();
    expect(rows.where((t) => t.isExcluded), hasLength(3));
    expect(rows.where((t) => !t.isExcluded), hasLength(2));
    await TxDb.exclude(selected.id, TxDisposition.ignored,
        match: ExclusionMatch.exact, text: text);
    expect(await TxDb.exclusionRules(), hasLength(1));
  });

  test('contains rules match changed amounts only when explicitly chosen',
      () async {
    await TxDb.importSms([sms(body(100, suffix: 'رسالة للتجربة'), 1)]);
    final t = (await TxDb.allTx()).single;
    await TxDb.exclude(t.id, TxDisposition.ignored,
        match: ExclusionMatch.contains, text: 'رسالة للتجربة');
    await TxDb.importSms([
      sms(body(900, suffix: 'رسالة للتجربة'), 2),
      sms(body(100), 3),
    ]);
    final rows = await TxDb.allTx();
    expect(rows.where((t) => t.isExcluded), hasLength(2));
    expect(rows.where((t) => !t.isExcluded).single.amount, 100);
  });

  test(
      'text rules never fabricate transactions for unparseable future messages',
      () async {
    await TxDb.importSms([sms(body(100, suffix: 'رسالة صيانة'), 1)]);
    await TxDb.exclude((await TxDb.allTx()).single.id, TxDisposition.ignored,
        match: ExclusionMatch.contains, text: 'رسالة صيانة');
    await TxDb.importSms([sms('رسالة صيانة فقط ولا توجد عملية مالية', 2)]);
    final archived = (await TxDb.allTx()).single;
    expect(archived.isExcluded, isTrue);
    expect(archived.amount, 100);
    expect(archived.body, contains('رسالة صيانة'));
  });

  test(
      'restoration exempts only that record and requires explicit reconfirmation',
      () async {
    final text = body(100);
    final raw = sms(text, 1);
    await TxDb.importSms([raw]);
    final id = (await TxDb.allTx()).single.id;
    await TxDb.exclude(id, TxDisposition.ignored,
        match: ExclusionMatch.exact, text: text);
    await TxDb.restoreToReview(id);
    await TxDb.importSms([raw, sms(text, 2)]);
    var restored = (await TxDb.allTx()).singleWhere((t) => t.id == id);
    expect(restored.isExcluded, isFalse);
    expect(restored.ruleExempt, isTrue);
    expect(restored.review, isTrue);
    expect(totalsOf([restored]).outSum, 0);
    expect((await TxDb.allTx()).where((t) => t.isExcluded), hasLength(1));
    await TxDb.setClass(id, restored.type, restored.dir);
    await TxDb.importSms([raw]);
    restored = (await TxDb.allTx()).singleWhere((t) => t.id == id);
    expect(restored.review, isFalse);
    expect(totalsOf([restored]).outSum, 100);
  });

  test(
      'deleting a rule returns auto-excluded rows to review, not counted totals',
      () async {
    final text = body(100);
    await TxDb.importSms([sms(text, 1), sms(text, 2)]);
    final selected = (await TxDb.allTx()).last;
    await TxDb.exclude(selected.id, TxDisposition.ignored,
        match: ExclusionMatch.exact, text: text);
    final rule = (await TxDb.exclusionRules()).single;
    await TxDb.deleteExclusionRule(rule.id);
    var rows = await TxDb.allTx();
    expect(rows.last.isExcluded, isTrue);
    expect(rows.first.review, isTrue);
    expect(rows.first.isExcluded, isFalse);
    await TxDb.importSms([sms(text, 2)]);
    rows = await TxDb.allTx();
    expect(rows.first.review, isTrue,
        reason: 'rule removal must not be undone by rescanning');
    expect(totalsOf(rows).outSum, 0);
  });

  test('removing one overlapping rule does not disable the other', () async {
    final text = body(100, suffix: 'رسالة للتجربة');
    await TxDb.importSms([sms(text, 1), sms(text, 2)]);
    final id = (await TxDb.allTx()).last.id;
    await TxDb.exclude(id, TxDisposition.ignored,
        match: ExclusionMatch.exact, text: text);
    await TxDb.exclude(id, TxDisposition.ignored,
        match: ExclusionMatch.contains, text: 'رسالة للتجربة');
    final exact = (await TxDb.exclusionRules())
        .singleWhere((r) => r.match == ExclusionMatch.exact);
    await TxDb.deleteExclusionRule(exact.id);
    expect((await TxDb.allTx()).every((t) => t.isExcluded), isTrue);
  });

  test('AI cannot classify a row excluded by a rule after the request began',
      () async {
    final text = body(100);
    await TxDb.importSms([sms(text, 1), sms(text, 2)]);
    final rows = await TxDb.allTx();
    await TxDb.exclude(rows.last.id, TxDisposition.ignored,
        match: ExclusionMatch.exact, text: text);
    await TxDb.applyAiUpdates([
      AiUpdate(
          id: rows.first.id, type: TxType.bill, dir: Dir.inFlow, confirm: true)
    ]);
    final t = (await TxDb.allTx()).first;
    expect(t.isExcluded, isTrue);
    expect(t.ai, isFalse);
    expect(t.type, TxType.transfer);
  });

  test('Excel reimport cannot recreate a manually excluded row', () async {
    final row = ImportRow(
        key: 'import-fixture',
        ts: DateTime(2026, 11).millisecondsSinceEpoch,
        wallet: 'Vodafone Cash',
        type: TxType.transfer,
        dir: Dir.inFlow,
        amount: 100,
        body: body(100));
    await TxDb.importRows([row]);
    await TxDb.exclude((await TxDb.allTx()).single.id, TxDisposition.duplicate);
    expect(await TxDb.importRows([row]), 0);
    expect((await TxDb.allTx()).single.disposition, TxDisposition.duplicate);
  });

  test('later AI batches refresh exclusions and report only persisted updates',
      () async {
    await TxDb.importSms([sms(body(100), 1), sms(body(200), 2)]);
    final queued = await TxDb.allTx();
    await TxDb.exclude(queued.last.id, TxDisposition.deferred);
    final batch = await TxDb.classificationBatch(queued.map((t) => t.id));
    expect(batch.map((t) => t.id), [queued.first.id]);
    final saved = await TxDb.applyAiUpdates([
      for (final t in queued)
        AiUpdate(
            id: t.id, type: TxType.transfer, dir: Dir.outFlow, confirm: true)
    ]);
    expect(saved, {queued.first.id});
  });

  test('empty rule validation is atomic and never excludes anything', () async {
    await TxDb.importSms([sms(body(100), 1)]);
    final id = (await TxDb.allTx()).single.id;
    await expectLater(
        TxDb.exclude(id, TxDisposition.ignored,
            match: ExclusionMatch.contains, text: '  '),
        throwsArgumentError);
    expect((await TxDb.allTx()).single.isExcluded, isFalse);
    expect(await TxDb.exclusionRules(), isEmpty);
  });
}
