import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/ai_suggestions.dart';
import 'package:wallet_log/backup_service.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/evidence_service.dart';
import 'package:wallet_log/gemini.dart';
import 'package:wallet_log/ledger_service.dart';
import 'package:wallet_log/match_service.dart';
import 'package:wallet_log/parser.dart';
import 'package:wallet_log/schema.dart';
import 'package:wallet_log/summary_service.dart';
import 'package:wallet_log/money_engine.dart';
import 'package:wallet_log/wallet_store.dart';

const _h = 3600 * 1000;

int bytes_mid(File f) => f.lengthSync() ~/ 2;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);
  late Directory dir, files;
  late WalletStore ws;
  late LedgerService led;
  late EvidenceService ev;
  late ConfirmationService conf;
  late MatchService match;
  late int w1, w2;

  Future<int> manual(int amount, String dirn,
          {int ts = 1000000,
          int fee = 0,
          int? wallet,
          String? party,
          String? ref}) =>
      led.createManual(
          walletAccountId: wallet ?? w1,
          amountMinor: amount,
          dir: dirn,
          type: 'transfer',
          feeMinor: fee,
          ts: ts,
          counterparty: party,
          reference: ref);

  Future<int> sms(int id, int ts, String d, int amount,
      {int fee = 0, String? ref, int? wallet, String? party}) async {
    id += 1000; // keep clear of ids given to manual rows
    await ws.db.insert('tx', {
      'id': id,
      'k': 'k$id',
      'ts': ts,
      'wallet': 'Vodafone Cash',
      'dir': d,
      'type': 'transfer',
      'amount': amount / 100.0,
      'amount_minor': amount,
      'fee': fee / 100.0,
      'fee_minor': fee,
      'body': 'sms $id',
      'source': 'sms',
      'wallet_account_id': wallet ?? w1,
      'reference': ref,
      'party': party,
      'confirmation': 'provider_confirmed',
      'sub_id': 1,
    });
    return id;
  }

  Future<File> img(String name, List<int> bytes) async {
    final f = File(p.join(dir.path, 'src', name));
    await f.parent.create(recursive: true);
    return f..writeAsBytesSync(bytes);
  }

  Future<Map<String, Object?>> row(int id) async =>
      (await ws.db.query('tx', where: 'id = ?', whereArgs: [id])).first;

  setUp(() async {
    await TxDb.close();
    dir = await Directory.systemTemp.createTemp('wallet-evidence-');
    files = Directory(p.join(dir.path, 'private'));
    await databaseFactory.setDatabasesPath(dir.path);
    ws = await TxDb.wallets();
    led = await TxDb.ledger();
    ev = EvidenceService(ws.db, files);
    conf = ConfirmationService(ws.db);
    match = MatchService(ws.db);
    w1 = await ws.addWallet(
        providerId: await ws.providerId('vodafone_cash'),
        phone: '01011111111',
        openingMinor: 100000);
    w2 = await ws.addWallet(
        providerId: await ws.providerId('orange_cash'),
        phone: '01022222222',
        openingMinor: 0);
  });
  tearDown(() async {
    await TxDb.close();
    await dir.delete(recursive: true);
  });

  group('manual transactions and status', () {
    test('manual incoming without proof is awaiting, not counted', () async {
      final id = await manual(50000, 'in', party: '01099999999');
      final r = await row(id);
      expect([r['source'], r['confirmation'], r['party']],
          ['manual', 'awaiting', '01099999999']);
      expect(await ev.activeCount(id), 0);
      final t = await ConfirmedTotals(ws.db).forWallet(w1);
      expect(t.confirmedBalanceMinor, 100000);
      expect([t.confirmedInMinor, t.pendingInMinor, t.pendingCount],
          [0, 50000, 1]);
    });

    test('evidence never confirms; only an explicit action does', () async {
      final id = await manual(50000, 'in');
      await ev.attachFile(id, await img('s.png', [1, 2, 3]),
          kind: EvidenceKind.walletApp,
          origin: EvidenceOrigin.senderWalletApp,
          uploadedBy: UploadedBy.owner);
      expect((await row(id))['confirmation'], 'awaiting');
      expect((await ConfirmedTotals(ws.db).forWallet(w1)).confirmedBalanceMinor,
          100000);
      await expectLater(conf.setStatus(id, Confirmation.providerConfirmed),
          throwsA(isA<LedgerException>()));
      await conf.confirmByProvider(id,
          reason: 'saw it in the wallet app history');
      expect((await row(id))['confirmation'], 'provider_confirmed');
      expect((await ConfirmedTotals(ws.db).forWallet(w1)).confirmedBalanceMinor,
          150000);
    });

    test('balance check confirms on agreement and flags mismatch', () async {
      final a = await manual(50000, 'in');
      expect(await conf.confirmByBalance(a, 150000), 0);
      expect((await row(a))['confirmation'], 'balance_confirmed');
      final b = await manual(20000, 'out', fee: 500, ts: 2000000);
      expect(await conf.confirmByBalance(b, 129000), -500); // expected 129500
      expect((await row(b))['confirmation'], 'mismatched');
      await conf.setStatus(b, Confirmation.disputed,
          reason: 'agent charged extra');
      expect((await row(b))['confirmation'], 'disputed');
    });

    test('pending amounts stay out of confirmed totals; reversal nets to zero',
        () async {
      final s = await sms(1, 1000, 'out', 10000, fee: 100);
      await manual(70000, 'in', ts: 2000);
      var t = await ConfirmedTotals(ws.db).forWallet(w1);
      expect([
        t.confirmedBalanceMinor,
        t.confirmedOutMinor,
        t.feesMinor,
        t.pendingInMinor
      ], [
        89900,
        10000,
        100,
        70000
      ]);
      await led.reverse(s, reason: 'entered twice');
      t = await ConfirmedTotals(ws.db).forWallet(w1);
      expect([t.confirmedBalanceMinor, t.confirmedOutMinor], [100000, 0]);
      await expectLater(conf.setStatus(s, Confirmation.awaiting),
          throwsA(isA<LedgerException>()));
    });

    test('status changes are audited', () async {
      final id = await manual(100, 'out');
      await conf.setStatus(id, Confirmation.cancelled, reason: 'changed mind');
      final h = await led.history(id);
      expect(h.map((e) => e['event']), containsAll(['create', 'confirmation']));
    });
  });

  group('evidence storage', () {
    test('copies file verbatim into private storage with hash and metadata',
        () async {
      final id = await manual(100, 'out');
      final src = await img('receipt.jpg', List.generate(5000, (i) => i % 251));
      final eid = await ev.attachFile(id, src,
          kind: EvidenceKind.receipt,
          origin: EvidenceOrigin.receipt,
          note: 'ATM slip');
      final e = (await ev.list(id)).single;
      expect(e['size'], 5000);
      expect(e['mime'], 'image/jpeg');
      expect((e['sha256'] as String).length, 64);
      final stored = ev.fileOf(e)!;
      expect(p.isWithin(files.path, stored.path), isTrue);
      expect(stored.readAsBytesSync(), src.readAsBytesSync());
      await src.delete(); // the original (gallery/cache) may vanish
      expect(await ev.verify(eid), isTrue);
      stored.writeAsBytesSync([9]);
      expect(await ev.verify(eid), isFalse); // tampering is detected
    });

    test('all proof kinds, uploader vs origin, multiple attachments', () async {
      final id = await manual(50000, 'in');
      await ev.attachSms(id,
          sender: 'VF-Cash', body: 'received 500', ts: 5, reference: 'R123456');
      await ev.attachFile(id, await img('a.png', [1]),
          kind: EvidenceKind.walletApp, origin: EvidenceOrigin.walletApp);
      await ev.attachFile(id, await img('b.png', [2]),
          kind: EvidenceKind.walletApp,
          origin: EvidenceOrigin.senderWalletApp,
          uploadedBy: UploadedBy.owner);
      await ev.attachFile(id, await img('c.png', [3]),
          kind: EvidenceKind.instantMessage,
          origin: EvidenceOrigin.instantMessage,
          uploadedBy: UploadedBy.sender);
      await ev.attachFile(id, await img('d.png', [4]),
          kind: EvidenceKind.receipt, origin: EvidenceOrigin.receipt);
      final list = await ev.list(id);
      expect(list, hasLength(5));
      final b = list.firstWhere((e) => e['file_name'] == 'b.png');
      expect([b['origin'], b['uploaded_by']], ['sender_wallet_app', 'owner']);
      await expectLater(ev.attachFile(id, await img('dup.png', [4])),
          throwsA(isA<LedgerException>()));
      await expectLater(
          ev.attachFile(id, await img('x.png', [5]), kind: 'bogus'),
          throwsA(isA<LedgerException>()));
    });

    test(
        'removal hides but never destroys; rows cannot be deleted or rewritten',
        () async {
      final id = await manual(100, 'out');
      final eid = await ev.attachFile(id, await img('a.png', [1, 2]));
      final file = ev.fileOf((await ev.list(id)).single)!;
      await expectLater(
          ev.remove(eid, reason: ' '), throwsA(isA<LedgerException>()));
      await ev.remove(eid, reason: 'wrong screenshot');
      expect(await ev.list(id), isEmpty);
      expect(await ev.list(id, includeRemoved: true), hasLength(1));
      expect(file.existsSync(), isTrue);
      expect((await led.history(id)).map((e) => e['event']),
          contains('evidence_removed'));
      await expectLater(ws.db.delete('evidence'), throwsA(anything));
      await expectLater(
          ws.db.update('evidence', {'sha256': 'x'}), throwsA(anything));
      await expectLater(
          ws.db.update('evidence', {'sms_body': 'x'}), throwsA(anything));
      // the same file can be attached again after removal
      await ev.attachFile(id, await img('a.png', [1, 2]));
    });

    test('evidence survives a restart', () async {
      final id = await manual(100, 'out');
      await ev.attachFile(id, await img('a.png', [7, 7]));
      await TxDb.close();
      final again = EvidenceService((await TxDb.wallets()).db, files);
      final e = (await again.list(id)).single;
      expect(await again.verify(e['id']! as int), isTrue);
    });
  });

  group('delayed SMS', () {
    test(
        'manual then delayed SMS: suggestion, explanation, accept links evidence',
        () async {
      final m = await manual(50000, 'in', ts: 10 * _h, party: '01099999999');
      await ev.attachFile(m, await img('s.png', [1]),
          origin: EvidenceOrigin.senderWalletApp);
      expect(await match.suggestAll(), 0); // SMS has not arrived: nothing yet
      final s = await sms(100, 10 * _h + 20 * 60000, 'in', 50000,
          ref: 'TX998877', party: '01099999999');
      expect(await match.suggestAll(), 1);
      expect(await match.suggestAll(), 0); // idempotent
      final sug = (await match.pending()).single;
      expect(jsonDecode(sug['reasons']! as String),
          containsAll(['same amount', 'same direction', 'same counterparty']));
      expect(jsonDecode(sug['conflicts']! as String), isEmpty);
      // nothing merged yet
      expect((await row(m))['confirmation'], 'awaiting');
      expect((await row(s))['disposition'], 'active');

      await match.accept(sug['id']! as int);
      final mr = await row(m), sr = await row(s);
      expect([mr['confirmation'], mr['reference']],
          ['provider_confirmed', 'TX998877']);
      expect([sr['disposition'], sr['linked_to_tx_id']], ['duplicate', m]);
      final kinds = (await ev.list(m)).map((e) => e['kind']).toList();
      expect(kinds, containsAll(['sms', 'other']));
      // counted once, not twice
      final t = await ConfirmedTotals(ws.db).forWallet(w1);
      expect([t.confirmedInMinor, t.confirmedBalanceMinor], [50000, 150000]);
    });

    test('rejected match leaves both records and the SMS reviewable', () async {
      final m = await manual(50000, 'in', ts: 10 * _h);
      final s = await sms(100, 10 * _h + 1000, 'in', 50000);
      await match.suggestAll();
      await match.reject((await match.pending()).single['id']! as int);
      expect((await row(m))['confirmation'], 'awaiting');
      expect((await row(s))['disposition'], 'active');
      expect(await match.suggestAll(), 0); // not re-suggested
      expect(await match.pending(), isEmpty);
    });

    test(
        'equal amount alone is not enough; wrong direction/wallet/time rejected',
        () async {
      await manual(50000, 'in', ts: 10 * _h);
      await sms(1, 10 * _h + 1000, 'out', 50000); // wrong direction
      await sms(2, 10 * _h + 1000, 'in', 50000, wallet: w2); // wrong wallet
      await sms(3, 10 * _h + 30 * _h, 'in', 50000); // a day later, no reference
      await sms(4, 10 * _h + 1000, 'in', 49000); // other amount
      expect(await match.suggestAll(), 0);
    });

    test('reference outranks time; reference conflict is shown', () async {
      await manual(50000, 'in', ts: 10 * _h, ref: 'ABC12345');
      await sms(1, 10 * _h + 40 * _h, 'in', 50000, ref: 'ABC12345');
      expect(await match.suggestAll(), 1);
      final sug = (await match.pending()).single;
      expect(jsonDecode(sug['reasons']! as String),
          contains('same provider reference'));
      final other = scoreMatch(
          {'dir': 'in', 'amount_minor': 1, 'ts': 1, 'reference': 'A1B2C3'},
          {'dir': 'in', 'amount_minor': 1, 'ts': 1, 'reference': 'Z9Y8X7'});
      expect(other.conflicts, contains('different provider reference'));
    });

    test(
        'two equal legitimate transactions: both suggested, accepting one supersedes the rest',
        () async {
      final m1 = await manual(10000, 'out', ts: 5 * _h);
      final m2 = await manual(10000, 'out', ts: 5 * _h + 600000);
      final s1 = await sms(1, 5 * _h + 60000, 'out', 10000);
      expect(await match.suggestAll(), 2); // ambiguous: user decides
      final sugs = await match.pending();
      expect(sugs, hasLength(2));
      await match.accept(sugs.first['id']! as int);
      expect(await match.pending(), isEmpty);
      final confirmed = [m1, m2].where((i) => true).toList();
      final states = [
        for (final i in confirmed) (await row(i))['confirmation']
      ];
      expect(states.where((s) => s == 'provider_confirmed'), hasLength(1));
      expect((await row(s1))['disposition'], 'duplicate');
    });

    test('amount conflict needs explicit adoption; otherwise mismatched',
        () async {
      final m = await manual(50000, 'out', ts: 10 * _h, ref: 'REF00001');
      await sms(1, 10 * _h, 'out', 50000, fee: 2000, ref: 'REF00001');
      await match.suggestAll();
      final sug = (await match.pending()).single;
      expect(jsonDecode(sug['conflicts']! as String), contains('fee differs'));
      await match.accept(sug['id']! as int);
      expect((await row(m))['confirmation'], 'mismatched');
      expect((await row(m))['fee_minor'], 0); // not silently changed
    });

    test('possible duplicate SMS vs two legitimate equal transactions',
        () async {
      await sms(1, 1000, 'in', 5000, ref: 'SAMEREF1');
      await sms(2, 1000 + 30000, 'in', 5000, ref: 'SAMEREF1');
      await sms(3, 9 * _h, 'in', 5000, ref: 'OTHER111');
      await sms(4, 9 * _h + 60000, 'in', 5000,
          ref: 'OTHER222'); // different refs: legitimate
      expect(await match.possibleDuplicates(), [
        [1001, 1002]
      ]);
    });

    test('out-of-order arrival does not create false gaps; a missing SMS does',
        () async {
      Future<void> bal(int id, int ts, String d, int amt, int after) =>
          ws.db.insert('tx', {
            'id': id,
            'k': 'g$id',
            'ts': ts,
            'wallet': 'Vodafone Cash',
            'dir': d,
            'type': 'transfer',
            'amount_minor': amt,
            'fee_minor': 0,
            'balance_minor': after,
            'source': 'sms',
            'body': 'b$id',
            'wallet_account_id': w1,
            'confirmation': 'provider_confirmed'
          });
      // arrival order 3,1,2 (ids) but time order 1,2,3
      await bal(3, 3000, 'in', 1000, 101000);
      await bal(1, 1000, 'in', 5000, 105000);
      await bal(2, 2000, 'out', 5000, 100000);
      expect(await match.balanceGaps(), isEmpty);
      await bal(5, 5000, 'in', 1000,
          110000); // 101000 -> 110000 with only +1000: 8000 missing
      expect(await match.balanceGaps(), [
        {'tx_id': 5, 'gap_minor': 8000}
      ]);
    });

    test('awaiting notification and evidence without provider confirmation',
        () async {
      final a = await manual(100, 'in', ts: 1000);
      final b = await manual(200, 'in', ts: 2000);
      await ev.attachFile(b, await img('p.png', [1]));
      final due = await match.awaitingNotification(
          olderThan: const Duration(hours: 1), nowMs: 2 * _h);
      expect({for (final r in due) r['id']: r['evidence_count']}, {a: 0, b: 1});
      expect(
          await match.awaitingNotification(
              olderThan: const Duration(hours: 5), nowMs: 2 * _h),
          isEmpty);
    });

    test('real SMS import extracts the reference and suggests the match',
        () async {
      final m = await manual(125050, 'in', ts: 1700000000000);
      await TxDb.importSms([
        const RawSms(
            'VF-Cash',
            'You have received 1,250.50 EGP from 01012345678. Your balance is EGP 3,400.00. Ref: 778899AB',
            1700000000000 + 1200000,
            null)
      ]);
      final rows = await ws.db.query('tx', where: "source = 'sms'");
      expect(rows.single['reference'], '778899AB');
      expect(rows.single['confirmation'], 'provider_confirmed');
      // the SMS is not yet linked to a wallet, so no suggestion can be made
      expect((await row(m))['confirmation'], 'awaiting');
    });
  });

  group('gemini suggestions', () {
    Future<int> reviewRow() async {
      await ws.db.insert('tx', {
        'id': 50,
        'k': 'ai1',
        'ts': 1,
        'wallet': 'Vodafone Cash',
        'dir': 'unknown',
        'type': 'other',
        'amount_minor': 1000,
        'amount': 10.0,
        'body': 'x',
        'source': 'sms',
        'review': 1,
        'wallet_account_id': w1,
        'confirmation': 'provider_confirmed'
      });
      return 50;
    }

    test('AI output is stored, never applied, until accepted', () async {
      final id = await reviewRow();
      await TxDb.applyAiUpdates([
        AiUpdate(
            id: id,
            type: TxType.topup,
            dir: Dir.outFlow,
            confirm: true,
            note: 'recharge')
      ]);
      var r = await row(id);
      expect([r['dir'], r['type'], r['review'], r['ai_note']],
          ['unknown', 'other', 1, 'recharge']);
      final svc = AiSuggestionService(ws.db);
      final sug = (await svc.pending()).single;
      await svc.accept(sug['id']! as int);
      r = await row(id);
      expect([r['dir'], r['type'], r['review']], ['out', 'topup', 0]);
      final h = await led.history(id);
      expect(h.every((e) => e['source'] == 'ai_accept'), isTrue);
      expect(await svc.pending(), isEmpty);
    });

    test('wrong suggestion dismissed leaves the transaction untouched',
        () async {
      final id = await reviewRow();
      await TxDb.applyAiUpdates([
        AiUpdate(id: id, type: TxType.cashIn, dir: Dir.inFlow, confirm: true)
      ]);
      final svc = AiSuggestionService(ws.db);
      await svc.dismiss((await svc.pending()).single['id']! as int);
      final r = await row(id);
      expect([r['dir'], r['type']], ['unknown', 'other']);
      expect(await led.history(id), isEmpty);
    });

    test('fee suggestion changes the fee only after acceptance, audited',
        () async {
      final id = await reviewRow();
      final svc = AiSuggestionService(ws.db);
      final sid = (await svc.store(
          txId: id,
          kind: AiKind.fee,
          action: 'review_fee',
          reason: 'ATM withdrawal usually has a fee',
          payload: {'fee_minor': 2000},
          confidence: 0.7,
          inputHash: 'h-fee'))!;
      expect((await row(id))['fee_minor'], isNull);
      await svc.accept(sid);
      expect((await row(id))['fee_minor'], 2000);
      await expectLater(svc.accept(sid), throwsA(isA<LedgerException>()));
    });

    test(
        'advisory kinds (duplicate, match, failed) change nothing when accepted',
        () async {
      final id = await reviewRow();
      final svc = AiSuggestionService(ws.db);
      for (final k in [AiKind.duplicate, AiKind.pending, AiKind.balanceGap]) {
        final sid = (await svc.store(
            txId: id, kind: k, action: 'review', inputHash: 'h-$k'))!;
        await svc.accept(sid);
      }
      final r = await row(id);
      expect([r['dir'], r['amount_minor'], r['confirmation']],
          ['unknown', 1000, 'provider_confirmed']);
    });

    test('same input is remembered so it is not analysed or stored twice',
        () async {
      final svc = AiSuggestionService(ws.db);
      final h = aiInputHash('تم تحويل 100 جنيه', model: 'm');
      expect(await svc.alreadyAnalysed(h), isFalse);
      await svc.store(kind: AiKind.analyzed, action: 'none', inputHash: h);
      expect(await svc.alreadyAnalysed(h), isTrue);
      expect(
          await svc.store(kind: AiKind.analyzed, action: 'none', inputHash: h),
          isNull);
      expect(aiInputHash('a', model: 'x'), isNot(aiInputHash('a', model: 'y')));
    });

    test('masking keeps amounts, hides phone and account numbers', () {
      final m = maskForAi(
          'حولت 500 جنيه إلى 01012345678 حساب 123456789012 رصيد 3400.50');
      expect(m, contains('01*****678'));
      expect(m, isNot(contains('01012345678')));
      expect(m, isNot(contains('123456789012')));
      expect(m, contains('500'));
      expect(m, contains('3400.50'));
    });

    test('failures are readable: quota, network, bad JSON', () {
      expect(() => parseAiResponse('not json', const []),
          throwsA(isA<GeminiException>()));
    });
  });

  group('backup and restore', () {
    test(
        'full backup restores into a clean install with evidence and without secrets',
        () async {
      final m = await manual(50000, 'in', ref: 'BKP12345');
      await ev.attachFile(
          m, await img('p.png', List.generate(300, (i) => i % 200)));
      await ev.attachSms(m, sender: 'VF', body: 'orig sms', ts: 1);
      await conf.confirmByProvider(m, reason: 'checked');
      await TxDb.setSetting(TxDb.settingsApiKey, 'SECRET-KEY');
      await TxDb.setSetting('gemini_model', 'gemini-flash');
      final zip = File(p.join(dir.path, 'backup.zip'));
      final manifest = await BackupService(ws.db, files).create(zip);
      expect((manifest['files'] as Map).keys, contains('wallet.db'));
      expect(zip.readAsBytesSync().length, greaterThan(0));
      expect(String.fromCharCodes(zip.readAsBytesSync()),
          isNot(contains('SECRET-KEY')));
      await TxDb.close();

      final clean = await Directory.systemTemp.createTemp('wallet-clean-');
      addTearDown(() => clean.delete(recursive: true));
      final dbPath = p.join(clean.path, 'db', 'wallet.db');
      final root = Directory(p.join(clean.path, 'private'));
      await restoreBackup(zip, dbPath, root);
      await expectLater(restoreBackup(zip, dbPath, root),
          throwsA(isA<LedgerException>())); // no silent overwrite

      final d = await openDatabase(dbPath, readOnly: true);
      expect(await integrityProblems(d), isEmpty);
      final t = (await d.query('tx', where: 'id = ?', whereArgs: [m])).single;
      expect([t['confirmation'], t['reference'], t['amount_minor']],
          ['provider_confirmed', 'BKP12345', 50000]);
      expect(await d.query('wallet_accounts'), hasLength(2));
      expect(
          (await d.query('audit_events', where: 'tx_id = ?', whereArgs: [m]))
              .length,
          greaterThan(2));
      expect(
          await d.query('settings', where: "key = 'gemini_api_key'"), isEmpty);
      expect(
          (await d.query('settings', where: "key = 'gemini_model'"))
              .single['value'],
          'gemini-flash');
      final restoredEv = EvidenceService(d, root);
      final file =
          (await restoredEv.list(m)).firstWhere((e) => e['file_path'] != null);
      expect(await restoredEv.verify(file['id']! as int), isTrue);
      expect((await restoredEv.list(m)).any((e) => e['sms_body'] == 'orig sms'),
          isTrue);
      await d.close();
    });

    test('damaged or tampered backups are refused', () async {
      final zip = File(p.join(dir.path, 'b.zip'));
      await BackupService(ws.db, files).create(zip);
      final bytes = zip.readAsBytesSync();
      final bad = File(p.join(dir.path, 'bad.zip'))
        ..writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      await expectLater(restoreBackup(bad, p.join(dir.path, 'x.db'), files),
          throwsA(anything));
      final junk = File(p.join(dir.path, 'junk.zip'))
        ..writeAsBytesSync([1, 2, 3]);
      await expectLater(restoreBackup(junk, p.join(dir.path, 'y.db'), files),
          throwsA(anything));
    });
  });

  group('restore over existing data', () {
    test(
        'inspect shows version/date; restore replaces data, keeps a pre-restore backup',
        () async {
      final a = await manual(50000, 'in', ref: 'STATE-A1');
      await ev.attachFile(a, await img('a.png', [1, 1, 1]));
      final zip = File(p.join(dir.path, 'a.zip'));
      await BackupService(ws.db, files).create(zip);
      final info = await inspectBackup(zip);
      expect([info.format, info.schemaVersion], [backupFormat, schemaVersion]);
      expect(info.createdAt, greaterThan(0));
      // The live data moves on after the backup.
      final b = await manual(70000, 'out', ts: 5000000);
      await ev.attachFile(b, await img('b.png', [2, 2, 2]));
      final dbPath = ws.db.path;

      final pre = await restoreOver(zip, dbPath, files,
          live: ws.db,
          closeDb: TxDb.close,
          reopenDb: () async => (await TxDb.wallets()).db.rawQuery('select 1'));
      final db = (await TxDb.wallets()).db;
      expect((await db.query('tx', where: 'id = ?', whereArgs: [a])),
          hasLength(1));
      expect((await db.query('tx', where: 'id = ?', whereArgs: [b])), isEmpty);
      final restoredEv = EvidenceService(db, files);
      expect((await restoredEv.list(a)).single['file_name'], 'a.png');
      expect(
          await restoredEv
              .verify((await restoredEv.list(a)).single['id']! as int),
          isTrue);
      // The pre-restore backup holds the state we replaced.
      expect(pre, isNotNull);
      final cleanDir = await Directory.systemTemp.createTemp('wallet-pre-');
      addTearDown(() => cleanDir.delete(recursive: true));
      await restoreBackup(pre!, p.join(cleanDir.path, 'w.db'),
          Directory(p.join(cleanDir.path, 'r')));
      final old =
          await openDatabase(p.join(cleanDir.path, 'w.db'), readOnly: true);
      expect(
          await old.query('tx', where: 'id = ?', whereArgs: [b]), hasLength(1));
      await old.close();
      expect(
          Directory(files.path)
              .listSync()
              .any((e) => e.path.contains('.restore-staging')),
          isFalse);
    });

    test('failure after the swap rolls back to the previous data', () async {
      final a = await manual(50000, 'in');
      final zip = File(p.join(dir.path, 'a.zip'));
      await BackupService(ws.db, files).create(zip);
      final b = await manual(70000, 'out', ts: 5000000);
      final eb = await ev.attachFile(b, await img('b.png', [2, 2, 2]));
      await expectLater(
          restoreOver(zip, ws.db.path, files,
              live: ws.db,
              closeDb: TxDb.close,
              reopenDb: () async =>
                  (await TxDb.wallets()).db.rawQuery('select 1'),
              verifyAfterSwitch: () async => throw StateError('boom')),
          throwsA(isA<LedgerException>()));
      final db = (await TxDb.wallets()).db;
      expect(await db.query('tx', where: 'id IN (?, ?)', whereArgs: [a, b]),
          hasLength(2));
      expect(await EvidenceService(db, files).verify(eb),
          isTrue); // files back in place
    });

    test('a damaged archive is refused before anything is touched', () async {
      final a = await manual(100, 'in');
      final zip = File(p.join(dir.path, 'a.zip'));
      await BackupService(ws.db, files).create(zip);
      final bytes = zip.readAsBytesSync()..[bytes_mid(zip)] ^= 0xff;
      final bad = File(p.join(dir.path, 'bad.zip'))..writeAsBytesSync(bytes);
      await expectLater(
          restoreOver(bad, ws.db.path, files, live: ws.db, closeDb: TxDb.close),
          throwsA(anything));
      expect((await ws.db.query('tx', where: 'id = ?', whereArgs: [a])),
          hasLength(1));
      expect(
          Directory(p.join(files.path, 'pre-restore')).existsSync(), isFalse);
    });
  });

  group('fee ownership, internal transfers, reversals, dashboard', () {
    Future<void> confirm(int id) => conf.confirmByProvider(id, reason: 'test');

    test('fee owner decides the wallet impact', () {
      expect(walletImpactMinor('in', 10000, 500), 9500); // owner pays (default)
      expect(walletImpactMinor('in', 10000, 500, feeOwner: 'sender'), 10000);
      expect(walletImpactMinor('out', 10000, 500, feeOwner: 'owner'), -10500);
      expect(walletImpactMinor('out', 10000, 500, feeOwner: 'other'), -10000);
      expect(walletImpactMinor('out', 10000, 500, feeOwner: 'unknown'), -10000);
    });

    test('balances, fees and uncertain fees follow the owner', () async {
      final a = await led.createManual(
          walletAccountId: w1,
          amountMinor: 10000,
          dir: 'in',
          type: 'transfer',
          feeMinor: 500,
          ts: 1000,
          feeOwner: 'sender');
      final b = await led.createManual(
          walletAccountId: w1,
          amountMinor: 20000,
          dir: 'out',
          type: 'cashOut',
          feeMinor: 300,
          ts: 2000,
          feeOwner: 'owner');
      final c = await led.createManual(
          walletAccountId: w1,
          amountMinor: 5000,
          dir: 'out',
          type: 'payment',
          feeMinor: 100,
          ts: 3000,
          feeOwner: 'unknown');
      for (final id in [a, b, c]) {
        await confirm(id);
      }
      final t = await ConfirmedTotals(ws.db).forWallet(w1);
      expect(t.confirmedBalanceMinor, 100000 + 10000 - 20300 - 5000);
      expect([t.feesMinor, t.uncertainFeeMinor], [300, 100]);
      expect((await led.calculatedBalance(w1)).balanceMinor,
          t.confirmedBalanceMinor);
      await expectLater(
          led.createManual(
              walletAccountId: w1,
              amountMinor: 1,
              dir: 'in',
              type: 'transfer',
              ts: 1,
              feeOwner: 'bogus'),
          throwsA(isA<LedgerException>()));
      // changing the owner is an audited correction
      await led.correct(a, {CorrectableField.feeOwner: 'owner'},
          reason: 'fee was mine');
      expect((await ConfirmedTotals(ws.db).forWallet(w1)).confirmedBalanceMinor,
          100000 + 9500 - 20300 - 5000);
    });

    test('internal transfer keeps both wallets, leaves consolidated totals',
        () async {
      final out = await manual(30000, 'out', ts: 5000);
      final inn = await manual(30000, 'in', ts: 5100, wallet: w2);
      final ext = await manual(1000, 'in', ts: 6000);
      for (final id in [out, inn, ext]) {
        await confirm(id);
      }
      // equal amounts are only candidates until the owner links them
      expect(await led.internalTransferCandidates(), [(out, inn)]);
      var d = await SummaryService(ws.db).dashboard();
      expect([d.incomeMinor, d.spendMinor], [31000, 30000]);
      await led.linkInternalTransfer(out, inn);
      d = await SummaryService(ws.db).dashboard();
      expect([d.incomeMinor, d.spendMinor], [1000, 0]);
      final w1t = d.wallets.firstWhere((w) => w.walletId == w1).totals;
      final w2t = d.wallets.firstWhere((w) => w.walletId == w2).totals;
      expect([
        w1t.confirmedOutMinor,
        w1t.internalOutMinor,
        w1t.confirmedBalanceMinor
      ], [
        30000,
        30000,
        100000 - 30000 + 1000
      ]);
      expect([
        w2t.confirmedInMinor,
        w2t.internalInMinor,
        w2t.confirmedBalanceMinor
      ], [
        30000,
        30000,
        30000
      ]);
      expect(await led.internalTransferCandidates(), isEmpty);
      await expectLater(
          led.linkInternalTransfer(out, inn), throwsA(isA<LedgerException>()));
      await led.unlinkInternalTransfer(out);
      d = await SummaryService(ws.db).dashboard();
      expect([d.incomeMinor, d.spendMinor], [31000, 30000]);
    });

    test(
        'internal links are refused for the same wallet, other amounts, wrong directions',
        () async {
      final a = await manual(100, 'out');
      final b = await manual(100, 'in', ts: 2000000);
      final c = await manual(200, 'in', ts: 2000000, wallet: w2);
      await expectLater(led.linkInternalTransfer(a, b),
          throwsA(isA<LedgerException>())); // same wallet
      await expectLater(led.linkInternalTransfer(a, c),
          throwsA(isA<LedgerException>())); // amount
      await expectLater(led.linkInternalTransfer(b, a),
          throwsA(isA<LedgerException>())); // direction
    });

    test(
        'reversal: original and reversal both visible, net zero, not income or expense',
        () async {
      final s = await sms(1, 1000, 'out', 10000, fee: 200);
      final before = await SummaryService(ws.db).dashboard();
      expect(before.spendMinor, 10000);
      final rev = await led.reverse(s, reason: 'recharge failed');
      final info = (await led.reversalInfo(s))!;
      expect([
        info.originalId,
        info.reversalId,
        info.originalImpactMinor,
        info.reversalImpactMinor,
        info.netMinor
      ], [
        1001,
        rev,
        -10200,
        10200,
        0
      ]);
      expect(
          (await led.reversalInfo(rev))!.originalId, 1001); // from either side
      expect(await led.reversalInfo(await manual(1, 'in')), isNull);
      final d = await SummaryService(ws.db).dashboard();
      expect([d.incomeMinor, d.spendMinor, d.feesMinor], [0, 0, 0]);
      expect((await row(rev))['disposition'], 'active'); // not "ignored"
    });

    test('dashboard separates confirmed, pending and discrepancies', () async {
      final a = await sms(1, 1000, 'in', 40000);
      await manual(25000, 'in', ts: 2000);
      await manual(7000, 'out', ts: 3000, fee: 100);
      final m = await manual(9000, 'out', ts: 4000);
      await conf.confirmByBalance(m, 1); // wrong reading -> mismatched
      await ws.confirmBalance(w1, 150000); // owner says 1,500.00
      final d = await SummaryService(ws.db).dashboard();
      final w = d.wallets.firstWhere((x) => x.walletId == w1);
      expect(w.totals.confirmedBalanceMinor, 140000); // only the SMS counts
      expect([w.totals.pendingInMinor, w.totals.pendingOutMinor],
          [25000, 7100 + 9000]);
      expect(w.discrepancyMinor, 10000);
      expect([d.incomeMinor, d.spendMinor, d.pendingCount, d.mismatchedCount],
          [40000, 0, 3, 1]);
      expect((await SummaryService(ws.db).awaiting()).length, 2);
      expect(a, 1001);
    });

    test('category spending and fees come from confirmed rows only', () async {
      final x = await led.createManual(
          walletAccountId: w1,
          amountMinor: 3000,
          dir: 'out',
          type: 'topup',
          feeMinor: 100,
          ts: 1000);
      await led.createManual(
          walletAccountId: w1,
          amountMinor: 9000,
          dir: 'out',
          type: 'bill',
          ts: 2000);
      await confirm(x);
      final d = await SummaryService(ws.db).dashboard();
      expect(d.spendByType, {'topup': 3000});
      expect(d.feesMinor, 100);
    });
  });

  group('financial correctness', () {
    test('ATM withdrawal with owner-paid fee, recharge and refund', () async {
      await sms(1, 1000, 'out', 20000, fee: 500);
      await ws.db.update('tx', {'type': 'cashOut'}, where: 'id = 1');
      await sms(2, 2000, 'out', 3000);
      await ws.db.update('tx', {'type': 'topup'}, where: 'id = 2');
      await sms(3, 3000, 'in', 3000);
      await ws.db.update('tx', {'type': 'refund'}, where: 'id = 3');
      final t = await ConfirmedTotals(ws.db).forWallet(w1);
      expect([t.confirmedInMinor, t.confirmedOutMinor, t.feesMinor],
          [3000, 23000, 500]);
      expect(t.confirmedBalanceMinor, 100000 - 20500 - 3000 + 3000);
    });

    test('failed and cancelled records are never counted or pending', () async {
      final a = await manual(9000, 'out');
      final b = await manual(8000, 'in');
      await conf.setStatus(a, Confirmation.failed, reason: 'sms says failed');
      await conf.setStatus(b, Confirmation.cancelled,
          reason: 'sender cancelled');
      final t = await ConfirmedTotals(ws.db).forWallet(w1);
      expect([
        t.confirmedBalanceMinor,
        t.pendingCount,
        t.pendingInMinor,
        t.pendingOutMinor
      ], [
        100000,
        0,
        0,
        0
      ]);
    });
  });
}
