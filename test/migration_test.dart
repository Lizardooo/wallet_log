import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/importer.dart';
import 'package:wallet_log/money_engine.dart';
import 'package:wallet_log/parser.dart';
import 'package:wallet_log/schema.dart';
import 'package:wallet_log/wallet_store.dart';

// Exact table layouts of every shipped version (from git history), so the
// upgrade paths are exercised on real old shapes. Isolated temp dirs only.
const _v1 =
    'CREATE TABLE tx(id INTEGER PRIMARY KEY AUTOINCREMENT, k TEXT UNIQUE, '
    'ts INTEGER, wallet TEXT, dir TEXT, amount REAL, party TEXT, balance REAL, body TEXT)';
const _v2tx =
    'CREATE TABLE tx(id INTEGER PRIMARY KEY AUTOINCREMENT, k TEXT UNIQUE, '
    'ts INTEGER, wallet TEXT, dir TEXT, amount REAL, party TEXT, balance REAL, '
    "sub_id INTEGER, note TEXT NOT NULL DEFAULT '', body TEXT)";
const _v2more = [
  'CREATE TABLE accounts(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, wallet TEXT, number TEXT, sub_id INTEGER)',
  'CREATE TABLE openings(account_id INTEGER, day TEXT, amount REAL, PRIMARY KEY(account_id, day))',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);
  late Directory dir;
  late String path;
  setUp(() async {
    await TxDb.close();
    dir = await Directory.systemTemp.createTemp('wallet-mig-');
    await databaseFactory.setDatabasesPath(dir.path);
    path = join(dir.path, 'wallet.db');
  });
  tearDown(() async {
    await TxDb.close();
    await dir.delete(recursive: true);
  });

  Future<Database> seed(int version, List<String> ddl,
      Future<void> Function(Database) fill) async {
    final d =
        await openDatabase(path, version: version, onCreate: (db, _) async {
      for (final s in ddl) {
        await db.execute(s);
      }
    });
    await fill(d);
    await d.close();
    return d;
  }

  Future<Database> raw() => openDatabase(path, singleInstance: false);

  test('v1 rows survive: kept verbatim in a legacy table and copied with ids',
      () async {
    await seed(1, [_v1], (d) async {
      await d.insert('tx', {
        'id': 1,
        'k': 'a',
        'ts': 1000,
        'wallet': 'Vodafone Cash',
        'dir': 'in',
        'amount': 1250.5,
        'party': '0101',
        'balance': 3000.0,
        'body': 'one'
      });
      await d.insert('tx', {
        'id': 7,
        'k': 'b',
        'ts': 2000000,
        'wallet': 'Orange Cash',
        'dir': 'out',
        'amount': 20.0,
        'body': 'two'
      });
      // Same body in the same 5-minute bucket: collides on the current key.
      await d.insert('tx', {
        'id': 8,
        'k': 'c',
        'ts': 2000100,
        'wallet': 'Orange Cash',
        'dir': 'out',
        'amount': 20.0,
        'body': 'two'
      });
    });
    await TxDb.allTx(); // opens and upgrades
    await TxDb.close();

    final d = await raw();
    final legacy = await d.query('tx_legacy_v1', orderBy: 'id');
    expect(legacy.map((r) => r['id']), [1, 7, 8]); // nothing lost, verbatim
    expect(legacy.first['amount'], 1250.5);
    final tx = await d.query('tx', orderBy: 'id');
    expect(tx.map((r) => r['id']), [1, 7]); // 8 stays only in the legacy table
    expect(tx.first['amount_minor'], 125050);
    expect(tx.first['balance_minor'], 300000);
    expect(tx.first['wallet_account_id'], isNull);
    final log = await d.query('migration_log');
    expect(log.any((r) => (r['detail'] as String).contains('tx_legacy_v1')),
        isTrue);
    expect(await integrityProblems(d), isEmpty);
    expect(Sqflite_user_version(await d.rawQuery('PRAGMA user_version')),
        schemaVersion);
    await d.close();
    // A restorable pre-migration copy exists.
    expect(dir.listSync().any((f) => f.path.contains('.pre-v1-')), isTrue);
  });

  test('v2 rows survive; a key collision no longer aborts the upgrade',
      () async {
    await seed(2, [_v2tx, ..._v2more], (d) async {
      await d.insert('tx', {
        'id': 3,
        'k': 'old1',
        'ts': 1000,
        'wallet': 'Vodafone Cash',
        'dir': 'in',
        'amount': 100.0,
        'body': 'same',
        'note': 'keep me'
      });
      await d.insert('tx', {
        'id': 4,
        'k': 'old2',
        'ts': 1100,
        'wallet': 'Vodafone Cash',
        'dir': 'in',
        'amount': 100.0,
        'body': 'same'
      });
      await d.insert('tx', {
        'id': 9,
        'k': 'old3',
        'ts': 9000000,
        'wallet': 'InstaPay',
        'dir': 'out',
        'amount': 5.25,
        'body': 'other'
      });
    });
    await TxDb.allTx();
    await TxDb.close();
    final d = await raw();
    final tx = await d.query('tx', orderBy: 'id');
    expect(tx.map((r) => r['id']), [3, 4, 9]);
    expect(tx.first['note'], 'keep me');
    expect(tx.map((r) => r['amount']), [100.0, 100.0, 5.25]);
    expect(tx.last['amount_minor'], 525);
    expect(await integrityProblems(d), isEmpty);
    await d.close();
  });

  test('current (v5) rows survive; sub-piaster values are never rounded',
      () async {
    final v5 = [
      'CREATE TABLE tx(id INTEGER PRIMARY KEY AUTOINCREMENT, k TEXT UNIQUE, ts INTEGER, wallet TEXT, dir TEXT, '
          "type TEXT NOT NULL DEFAULT 'other', amount REAL, fee REAL NOT NULL DEFAULT 0, party TEXT, balance REAL, "
          'sub_id INTEGER, review INTEGER NOT NULL DEFAULT 0, manual INTEGER NOT NULL DEFAULT 0, ai INTEGER NOT NULL DEFAULT 0, '
          "ai_note TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '', body TEXT, "
          "disposition TEXT NOT NULL DEFAULT 'active', rule_exempt INTEGER NOT NULL DEFAULT 0)",
      'CREATE TABLE exclusion_rules(id INTEGER PRIMARY KEY AUTOINCREMENT, wallet TEXT NOT NULL, match_mode TEXT NOT NULL, pattern TEXT NOT NULL, UNIQUE(wallet, match_mode, pattern))',
      'CREATE TABLE accounts(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, wallet TEXT, number TEXT, sub_id INTEGER, slot INTEGER)',
      'CREATE TABLE openings(account_id INTEGER, day TEXT, amount REAL, PRIMARY KEY(account_id, day))',
      'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    ];
    await seed(5, v5, (d) async {
      await d.insert('tx', {
        'id': 11,
        'k': 'k1',
        'ts': 1,
        'wallet': 'Vodafone Cash',
        'dir': 'out',
        'type': 'topup',
        'amount': 100.0,
        'fee': 2.0,
        'balance': 898.0,
        'manual': 1,
        'note': 'n',
        'ai': 1,
        'ai_note': 'why',
        'review': 1
      });
      await d.insert('tx', {
        'id': 12,
        'k': 'k2',
        'ts': 2,
        'wallet': 'Orange Cash',
        'dir': 'in',
        'amount': 0.1 + 0.2,
        'fee': 0.0
      });
      await d.insert('tx', {
        'id': 13,
        'k': 'k3',
        'ts': 3,
        'wallet': 'Orange Cash',
        'dir': 'in',
        'amount': 12.345
      });
      await d.insert('tx', {
        'id': 14,
        'k': 'xlsx|5',
        'ts': 4,
        'wallet': 'X',
        'dir': 'in',
        'amount': 1.0
      });
      await d.insert('accounts', {
        'id': 1,
        'name': 'main',
        'wallet': 'Vodafone Cash',
        'number': '01012345678',
        'slot': 0
      });
      await d.insert('accounts', {
        'id': 2,
        'name': 'odd',
        'wallet': 'Unknown Wallet',
        'number': '01099999999'
      });
      await d.insert('settings', {'key': 'setup_done', 'value': '1'});
    });
    await TxDb.allTx();
    await TxDb.close();
    final d = await raw();
    final tx = await d.query('tx', orderBy: 'id');
    expect(tx.map((r) => r['id']), [11, 12, 13, 14]);
    expect(tx[0]['note'], 'n');
    expect(tx[0]['ai_note'], 'why');
    expect(tx[0]['amount'], 100.0); // REAL untouched
    expect([tx[0]['amount_minor'], tx[0]['fee_minor'], tx[0]['balance_minor']],
        [10000, 200, 89800]);
    expect(tx[1]['amount_minor'], 30); // float noise, exactly 30 piasters
    expect(tx[2]['amount'], 12.345);
    expect(tx[2]['amount_minor'], isNull); // not rounded
    expect(tx[3]['source'], 'excel');
    expect(tx[0]['source'], 'sms');
    final log = await d.query('migration_log', where: "note LIKE 'piaster%'");
    expect((log.single['detail'] as String), contains('13:'));
    // Linked only when exactly one wallet of that provider exists (the owner's
    // own account); an unknown provider is never guessed onto a wallet.
    for (final r in tx) {
      final known =
          r['wallet'] == 'Orange Cash' || r['wallet'] == 'Vodafone Cash';
      if (r['wallet'] == 'X') expect(r['wallet_account_id'], isNull);
      if (r['wallet_account_id'] != null) expect(known, isTrue);
    }
    final w = await d.query('wallet_accounts');
    expect(
        w, hasLength(1)); // known provider mirrored, unknown left in accounts
    expect(w.single['legacy_account_id'], 1);
    expect((await d.query('accounts')), hasLength(2));
    expect((await d.query('settings')).single['value'], '1');
    expect(await integrityProblems(d), isEmpty);
    await d.close();
    expect(dir.listSync().any((f) => f.path.contains('.pre-v5-')), isTrue);
  });

  test('a failing upgrade rolls back completely and keeps v5 data', () async {
    await seed(5, [
      "CREATE TABLE tx(id INTEGER PRIMARY KEY AUTOINCREMENT, k TEXT UNIQUE, ts INTEGER, wallet TEXT, dir TEXT, type TEXT NOT NULL DEFAULT 'other', amount REAL, fee REAL NOT NULL DEFAULT 0, party TEXT, balance REAL, sub_id INTEGER, review INTEGER NOT NULL DEFAULT 0, manual INTEGER NOT NULL DEFAULT 0, ai INTEGER NOT NULL DEFAULT 0, ai_note TEXT NOT NULL DEFAULT '', note TEXT NOT NULL DEFAULT '', body TEXT, disposition TEXT NOT NULL DEFAULT 'active', rule_exempt INTEGER NOT NULL DEFAULT 0)",
      'CREATE TABLE accounts(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, wallet TEXT, number TEXT, sub_id INTEGER, slot INTEGER)',
    ], (d) async {
      await d.insert('tx', {
        'id': 1,
        'k': 'k',
        'ts': 1,
        'wallet': 'W',
        'dir': 'in',
        'amount': 5.0
      });
      await d.execute(
          "CREATE TRIGGER boom BEFORE UPDATE ON tx BEGIN SELECT RAISE(ABORT, 'boom'); END");
    });
    await expectLater(TxDb.allTx(), throwsA(anything));
    await TxDb.close();
    final d = await raw();
    expect(Sqflite_user_version(await d.rawQuery('PRAGMA user_version')), 5);
    expect((await d.query('tx')).single['amount'], 5.0);
    expect(
        await d.rawQuery("SELECT name FROM sqlite_master WHERE name='owners'"),
        isEmpty);
    await d.close();
  });

  test('fresh install passes integrity and seeds configurable providers',
      () async {
    final store = await TxDb.wallets();
    final d = await raw();
    expect(await integrityProblems(d), isEmpty);
    expect(
        await d.query('wallet_providers'), hasLength(greaterThanOrEqualTo(10)));
    await d.close();
    expect(await store.providerId('we_pay'), isPositive);
  });

  test(
      'more than ten wallets, many owners/devices/SIMs, SIM moves keep history',
      () async {
    final s = await TxDb.wallets();
    final owners = [for (var i = 0; i < 4; i++) await s.addOwner('owner $i')];
    final devices = [for (var i = 0; i < 4; i++) await s.addDevice('phone $i')];
    final codes = [
      'vodafone_cash',
      'orange_cash',
      'etisalat_cash',
      'we_pay',
      'phone_cash',
      'halan_cash'
    ];
    final wallets = <int>[];
    final sims = <int>[];
    for (var i = 0; i < 14; i++) {
      // 3 SIMs per device on some devices: no 2-slot assumption.
      final sim = await s.addSim(
          phone: '010000000${i.toString().padLeft(2, '0')}',
          slot: i % 3,
          deviceId: devices[i % 4]);
      sims.add(sim);
      wallets.add(await s.addWallet(
          providerId: await s.providerId(codes[i % codes.length]),
          phone: '010000000${i.toString().padLeft(2, '0')}',
          ownerId: owners[i % 4],
          simId: sim,
          nickname: 'w$i'));
    }
    // Wallet with unknown device/SIM/owner.
    final loose = await s.addWallet(
        providerId: await s.providerId('bm_wallet'), phone: '01155555555');
    expect((await s.wallets()), hasLength(15));
    expect((await s.wallets(ownerId: owners[0])).length, 4);
    expect((await s.wallets(deviceId: devices[1])).length, 4);
    expect(
        (await s.wallets(providerId: await s.providerId('bm_wallet')))
            .single
            .id,
        loose);

    // A transaction explicitly linked to wallet 0, then its SIM changes device.
    final db = await openDatabase(path, singleInstance: false);
    await db.insert('tx', {
      'id': 100,
      'k': 'z',
      'ts': 5,
      'wallet': 'Vodafone Cash',
      'dir': 'in',
      'amount': 50.0,
      'amount_minor': 5000
    });
    await db.close();
    await s.linkTransactions([100], wallets[0]);
    await s.moveSim(sims[0], devices[3], slot: 1);
    final moved = (await s.wallets()).firstWhere((w) => w.id == wallets[0]);
    expect(moved.deviceId, devices[3]);
    expect(moved.providerCode, 'vodafone_cash'); // identity unchanged
    final hist = await s.simHistory(sims[0]);
    expect(hist, hasLength(2));
    expect(hist.first['to_ts'], isNotNull);
    expect(hist.last['to_ts'], isNull);
    final check = await openDatabase(path, singleInstance: false);
    expect(
        (await check.query('tx', where: 'id = 100'))
            .single['wallet_account_id'],
        wallets[0]);
    expect(await integrityProblems(check), isEmpty);

    // Wallets with history cannot be deleted, only archived and restored.
    await check.close();
    // The app's own connection enforces foreign keys.
    await expectLater(
        s.db.delete('wallet_accounts',
            where: 'id = ?', whereArgs: [wallets[0]]),
        throwsA(anything));
    await s.archiveWallet(wallets[0]);
    expect((await s.wallets()).length, 14);
    expect((await s.wallets(includeArchived: true)).length, 15);
    await s.restoreWallet(wallets[0]);

    // Duplicate active wallet (same provider + number) is rejected.
    await expectLater(
        s.addWallet(
            providerId: await s.providerId('vodafone_cash'),
            phone: '01000000000'),
        throwsA(isA<DuplicateWalletException>()));
    // After archiving, the number can be registered again.
    await s.archiveWallet(wallets[0]);
    await s.addWallet(
        providerId: await s.providerId('vodafone_cash'), phone: '01000000000');

    // Eligibility warnings, not blocks.
    expect(await s.eligibilityWarnings(phone: '01000000001'),
        ['number_already_has_wallet']);
    expect(await s.eligibilityWarnings(phone: '', ownerId: owners[1]),
        ['owner_exceeds_three_wallets']);
  });

  test('Excel rows never get a guessed wallet or silently inferred date',
      () async {
    final rows = [
      ImportRow(
          key: 'xlsx|1',
          ts: 1000,
          wallet: excelWalletFallback,
          type: TxType.cashOut,
          dir: Dir.outFlow,
          amount: 10,
          review: false),
      ImportRow(
          key: 'xlsx|2',
          ts: 2000,
          wallet: 'Orange Cash',
          type: TxType.cashOut,
          dir: Dir.outFlow,
          amount: 20,
          dateInferred: true),
      ImportRow(
          key: 'xlsx|3',
          ts: 3000,
          wallet: 'Orange Cash',
          type: TxType.cashOut,
          dir: Dir.outFlow,
          amount: 30),
    ];
    await TxDb.importRows(rows);
    await TxDb.close();
    final d = await raw();
    final tx = await d.query('tx', orderBy: 'ts');
    expect(tx.map((r) => r['review']), [1, 1, 0]);
    expect(tx.map((r) => r['date_inferred']), [0, 1, 0]);
    expect(tx.every((r) => r['source'] == 'excel'), isTrue);
    expect(tx[2]['amount_minor'], 3000);
    await d.close();
  });

  test('unknown-sender candidates are opt-in and strictly filtered', () async {
    final good =
        RawSms('NewBank', 'تم تحويل 500 جنيه من محفظة كاش', 1000000, null);
    final phoneSender = RawSms(
        '+201001234567', 'تم تحويل 500 جنيه من محفظة كاش', 2000000, null);
    final otp = RawSms(
        'NewBank', 'رمز التحقق لتحويل 500 جنيه من محفظة كاش', 3000000, null);
    final chat = RawSms('Shop', 'hello how are you', 4000000, null);

    await TxDb.importSms([good, phoneSender, otp, chat]);
    expect(await TxDb.candidates(), isEmpty); // default off: nothing stored

    await TxDb.setSetting(TxDb.settingsStoreCandidates, '1');
    await TxDb.importSms([good, phoneSender, otp, chat]);
    await TxDb.importSms([good]); // idempotent
    final c = await TxDb.candidates();
    expect(c, hasLength(1));
    expect(c.single['sender'], 'NewBank');
    final d = await raw();
    expect(await d.query('tx'), isEmpty); // never a transaction by itself
    await d.close();
  });

  test('exactMinor accepts whole piasters only', () {
    expect(exactMinor(1250.5), 125050);
    expect(exactMinor(0.1 + 0.2), 30);
    expect(exactMinor(12.345), isNull);
    expect(exactMinor(null), isNull);
    expect(exactMinor(double.nan), isNull);
  });
}

int? Sqflite_user_version(List<Map<String, Object?>> r) =>
    r.first.values.first as int?;
