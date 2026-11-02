import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/exclusions.dart';
import 'package:wallet_log/parser.dart';

String cashIn(int amount, int balance) =>
    'تم ايداع $amount جنيه في محفظتك. رصيدك الحالي $balance جنيه';
String transfer(int amount, String to) =>
    'تم تحويل $amount جنيه الى $to بنجاح. رصيدك الحالي 900 جنيه';
RawSms sms(String body, int hour) => RawSms(
    'VF-Cash', body, DateTime(2026, 11, 2, hour).millisecondsSinceEpoch, null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);
  late Directory dir;
  setUp(() async {
    await TxDb.close();
    dir = await Directory.systemTemp.createTemp('wallet-same-text-');
    await databaseFactory.setDatabasesPath(dir.path);
  });
  tearDown(() async {
    await TxDb.close();
    await dir.delete(recursive: true);
  });

  test('numbers do not change the text', () {
    expect(messageTemplate(cashIn(500, 900)), messageTemplate(cashIn(20, 35)));
    expect(
        messageTemplate(
            'تم ايداع ٢٠٠٠ جنيه في محفظتك. رصيدك الحالي 5,000.50 جنيه'),
        messageTemplate(cashIn(1, 2)));
    expect(messageTemplate(cashIn(500, 900)),
        isNot(messageTemplate(transfer(500, '01012345678'))));
  });

  Future<Tx> byBody(String body) async =>
      (await TxDb.allTx()).firstWhere((t) => t.body == body);

  test(
      'excluding one waiting message excludes the others like it, now and '
      'later, and never a counted one', () async {
    await TxDb.importSms([
      sms(cashIn(500, 900), 9),
      sms(cashIn(20, 920), 10),
      sms(cashIn(700, 1620), 11),
      sms(transfer(200, '01012345678'), 12),
    ]);
    final first = await byBody(cashIn(500, 900));
    expect(first.review, isTrue, reason: 'cash in waits for review');
    // The owner already confirmed this one: it counts and must stay.
    final kept = await byBody(cashIn(700, 1620));
    await TxDb.setClass(kept.id, kept.type, Dir.inFlow);

    await TxDb.exclude(first.id, TxDisposition.ignored, similar: true);

    var all = await TxDb.allTx();
    Tx t(String body) => all.firstWhere((x) => x.body == body);
    expect(t(cashIn(500, 900)).isExcluded, isTrue);
    expect(t(cashIn(20, 920)).isExcluded, isTrue, reason: 'same text');
    expect(t(cashIn(700, 1620)).isExcluded, isFalse, reason: 'confirmed');
    expect(t(transfer(200, '01012345678')).isExcluded, isFalse);
    final rule = (await TxDb.exclusionRules()).single;
    expect(rule.match, ExclusionMatch.template);
    expect(t(cashIn(20, 920)).exclusionRuleId, rule.id);

    // A new message with the same text is excluded as soon as it is read.
    await TxDb.importSms([sms(cashIn(5, 925), 13)]);
    all = await TxDb.allTx();
    expect(t(cashIn(5, 925)).isExcluded, isTrue);

    // Restored by hand: it stays in review, even after another scan.
    await TxDb.restoreToReview(t(cashIn(20, 920)).id);
    await TxDb.importSms([sms(cashIn(20, 920), 10)]);
    all = await TxDb.allTx();
    expect(t(cashIn(20, 920)).isExcluded, isFalse);
    expect(t(cashIn(20, 920)).review, isTrue);

    // Deleting the rule brings back what it excluded, not the one the owner
    // excluded himself.
    await TxDb.deleteExclusionRule(rule.id);
    all = await TxDb.allTx();
    expect(t(cashIn(5, 925)).isExcluded, isFalse);
    expect(t(cashIn(5, 925)).review, isTrue);
    expect(t(cashIn(500, 900)).isExcluded, isTrue);
    expect(await TxDb.exclusionRules(), isEmpty);
  });

  test('without the option only that one message is excluded', () async {
    await TxDb.importSms([sms(cashIn(500, 900), 9), sms(cashIn(20, 920), 10)]);
    await TxDb.exclude(
        (await byBody(cashIn(500, 900))).id, TxDisposition.duplicate);
    expect((await byBody(cashIn(20, 920))).isExcluded, isFalse);
    expect(await TxDb.exclusionRules(), isEmpty);
  });

  test('a message ignored before the update teaches the rule too', () async {
    await TxDb.importSms([sms(cashIn(500, 900), 9), sms(cashIn(20, 920), 10)]);
    final db = await TxDb.database();
    // As an older version left it: ignored, and no same-text rule yet.
    await db.update('tx', {'disposition': 'ignored'},
        where: 'body = ?', whereArgs: [cashIn(500, 900)]);
    await db.execute('PRAGMA user_version = 9');
    await TxDb.close();

    expect((await byBody(cashIn(20, 920))).isExcluded, isTrue);
    expect((await TxDb.exclusionRules()).single.match, ExclusionMatch.template);
  });
}
