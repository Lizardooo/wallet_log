/// Database schema steps shared by the app and the migration tests.
///
/// Rules every step follows: nothing is dropped, truncated or rebuilt in place;
/// legacy REAL money columns are kept untouched next to the new integer-piaster
/// columns; anything that cannot be converted exactly is left unconverted and
/// written to `migration_log` instead of being rounded or discarded.
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'confirmation_rules.dart';
import 'exclusions.dart';
import 'money_engine.dart';
import 'parser.dart';

const schemaVersion = 10;

/// Wallet-provider names used by the older `accounts` / `tx.wallet` columns,
/// mapped to the provider codes seeded below.
const legacyWalletProviderCodes = {
  'Vodafone Cash': 'vodafone_cash',
  'Orange Cash': 'orange_cash',
  'Etisalat Cash / Fawry': 'etisalat_cash',
  'InstaPay': 'instapay',
};

/// Providers seeded on first use. Everything is data and can be edited or
/// extended; sender patterns are only filled where the app already trusted
/// them, never invented for the others.
const _seedProviders = <(String, String, String, List<String>)>[
  ('vodafone_cash', 'Vodafone Cash', 'telecom', ['vodafone', 'vf', 'cash']),
  ('orange_cash', 'Orange Cash', 'telecom', ['orange', 'cash']),
  (
    'etisalat_cash',
    'e& money / Etisalat Cash',
    'telecom',
    ['etisalat', 'e&', 'fawry', 'cash']
  ),
  ('we_pay', 'WE Pay', 'telecom', []),
  ('instapay', 'InstaPay', 'payment_network', ['instapay']),
  ('bm_wallet', 'BM Wallet', 'bank', []),
  ('phone_cash', 'Phone Cash', 'bank', []),
  ('qnb_wallet', 'QNB Wallet', 'bank', []),
  ('alexbank_ma7fazty', 'ALEXBANK Ma7fazty', 'bank', []),
  ('halan_cash', 'Halan Cash', 'fintech', []),
];

Future<void> addColumn(
    DatabaseExecutor d, String table, String column, String decl) async {
  final cols = await d.rawQuery('PRAGMA table_info($table)');
  if (cols.any((c) => c['name'] == column)) return;
  await d.execute('ALTER TABLE $table ADD COLUMN $column $decl');
}

Future<void> logMigration(DatabaseExecutor d, int from, int to, String note,
    [String detail = '']) async {
  await d.execute('CREATE TABLE IF NOT EXISTS migration_log('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, '
      'from_version INTEGER, to_version INTEGER, note TEXT NOT NULL, '
      "detail TEXT NOT NULL DEFAULT '')");
  await d.insert('migration_log', {
    'ts': DateTime.now().millisecondsSinceEpoch,
    'from_version': from,
    'to_version': to,
    'note': note,
    'detail': detail,
  });
}

Future<int> _count(DatabaseExecutor d, String table) async =>
    Sqflite.firstIntValue(await d.rawQuery('SELECT COUNT(*) FROM $table')) ?? 0;

Future<bool> _tableExists(DatabaseExecutor d, String name) async =>
    (await d.rawQuery(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            [name]))
        .isNotEmpty;

/// Copies the database file (and its WAL) next to itself before an upgrade, so
/// a failed or unwanted migration can be undone by restoring the copy. Returns
/// the backup path, or null when there is nothing to back up or the file is
/// already at [targetVersion].
Future<String?> backupBeforeMigration(String path, int targetVersion) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final probe = await openDatabase(path, readOnly: true, singleInstance: false);
  final current =
      Sqflite.firstIntValue(await probe.rawQuery('PRAGMA user_version')) ?? 0;
  await probe.close();
  if (current >= targetVersion || current == 0) return null;
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final dest = '$path.pre-v$current-$stamp.bak';
  await file.copy(dest);
  final wal = File('$path-wal');
  if (await wal.exists()) await wal.copy('$dest-wal');
  return dest;
}

/// v1 -> v2. v1 stored only direction, amount, party, balance and the body; the
/// original upgrade dropped the table. Here the v1 table is renamed (kept
/// verbatim) and its rows are copied into the current layout with their ids,
/// timestamps, amounts and bodies unchanged. Rows that cannot be copied (e.g. a
/// key collision) stay available in the legacy table and are logged.
Future<void> preserveLegacyV1(DatabaseExecutor d) async {
  if (!await _tableExists(d, 'tx')) return;
  var legacy = 'tx_legacy_v1';
  for (var i = 2; await _tableExists(d, legacy); i++) {
    legacy = 'tx_legacy_v1_$i';
  }
  await d.execute('ALTER TABLE tx RENAME TO $legacy');
  await createCore(d);
  final rows = await d.query(legacy);
  var copied = 0;
  for (final r in rows) {
    final id = await d.insert(
        'tx',
        {
          'id': r['id'],
          'k': smsKey((r['body'] as String?) ?? '', (r['ts'] as int?) ?? 0),
          'ts': r['ts'],
          'wallet': r['wallet'],
          'dir': r['dir'],
          'type': 'other',
          'amount': r['amount'],
          'party': r['party'],
          'balance': r['balance'],
          'body': r['body'],
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    if (id > 0) copied++;
  }
  final skipped = rows.length - copied;
  await logMigration(
      d,
      1,
      2,
      'v1 transactions preserved in $legacy and copied: $copied of ${rows.length}',
      skipped == 0 ? '' : '$skipped rows stay only in $legacy (key collision)');
}

/// v2 -> v3 duplicate key switch that can no longer abort the upgrade: a row
/// whose new key already exists keeps its old key.
Future<void> rekeyV2(DatabaseExecutor d) async {
  final rows = await d.query('tx', columns: ['id', 'ts', 'body']);
  var kept = 0;
  for (final r in rows) {
    final n = await d.update(
      'tx',
      {'k': smsKey((r['body'] as String?) ?? '', (r['ts'] as int?) ?? 0)},
      where: 'id = ?',
      whereArgs: [r['id']],
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (n == 0) kept++;
  }
  if (kept > 0) {
    await logMigration(
        d, 2, 3, 'rows kept their old key on collision', '$kept');
  }
}

/// The tables that existed before the multi-wallet foundation.
Future<void> createCore(DatabaseExecutor d) async {
  await d.execute(
    'CREATE TABLE IF NOT EXISTS tx('
    'id INTEGER PRIMARY KEY AUTOINCREMENT, '
    'k TEXT UNIQUE, ts INTEGER, wallet TEXT, dir TEXT, '
    "type TEXT NOT NULL DEFAULT 'other', "
    'amount REAL, fee REAL NOT NULL DEFAULT 0, party TEXT, balance REAL, '
    'sub_id INTEGER, review INTEGER NOT NULL DEFAULT 0, '
    'manual INTEGER NOT NULL DEFAULT 0, '
    'ai INTEGER NOT NULL DEFAULT 0, '
    "ai_note TEXT NOT NULL DEFAULT '', "
    "note TEXT NOT NULL DEFAULT '', body TEXT, "
    "disposition TEXT NOT NULL DEFAULT 'active', "
    'rule_exempt INTEGER NOT NULL DEFAULT 0)',
  );
  await d.execute(
    'CREATE TABLE IF NOT EXISTS exclusion_rules('
    'id INTEGER PRIMARY KEY AUTOINCREMENT, wallet TEXT NOT NULL, '
    'match_mode TEXT NOT NULL, pattern TEXT NOT NULL, '
    'UNIQUE(wallet, match_mode, pattern))',
  );
  await d.execute(
    'CREATE TABLE IF NOT EXISTS accounts('
    'id INTEGER PRIMARY KEY AUTOINCREMENT, '
    'name TEXT, wallet TEXT, number TEXT, sub_id INTEGER, slot INTEGER)',
  );
  await d.execute(
    'CREATE TABLE IF NOT EXISTS openings('
    'account_id INTEGER, day TEXT, amount REAL, '
    'PRIMARY KEY(account_id, day))',
  );
  await d.execute(
    'CREATE TABLE IF NOT EXISTS settings('
    'key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
}

/// v5 -> v6: additive multi-wallet model, integer-piaster columns and the
/// opt-in candidate inbox. Safe to run again.
Future<void> applyV6(DatabaseExecutor d, int fromVersion) async {
  await d.execute('CREATE TABLE IF NOT EXISTS owners('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
      "notes TEXT NOT NULL DEFAULT '', active INTEGER NOT NULL DEFAULT 1, "
      'created_at INTEGER NOT NULL)');
  await d.execute('CREATE TABLE IF NOT EXISTS devices('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
      "identifier TEXT, notes TEXT NOT NULL DEFAULT '', "
      'active INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL)');
  await d.execute('CREATE TABLE IF NOT EXISTS sim_lines('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, phone TEXT, carrier TEXT, '
      'slot INTEGER, sub_id INTEGER, '
      'device_id INTEGER REFERENCES devices(id) ON DELETE RESTRICT, '
      "notes TEXT NOT NULL DEFAULT '', active INTEGER NOT NULL DEFAULT 1, "
      'created_at INTEGER NOT NULL)');
  await d.execute('CREATE TABLE IF NOT EXISTS sim_device_history('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'sim_id INTEGER NOT NULL REFERENCES sim_lines(id) ON DELETE RESTRICT, '
      'device_id INTEGER REFERENCES devices(id) ON DELETE RESTRICT, '
      'slot INTEGER, from_ts INTEGER NOT NULL, to_ts INTEGER)');
  await d.execute('CREATE TABLE IF NOT EXISTS wallet_providers('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL UNIQUE, '
      "name TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'other', "
      "icon TEXT NOT NULL DEFAULT '', services TEXT NOT NULL DEFAULT '[]', "
      "sender_patterns TEXT NOT NULL DEFAULT '[]', "
      'active INTEGER NOT NULL DEFAULT 1)');
  await d.execute('CREATE TABLE IF NOT EXISTS wallet_accounts('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'provider_id INTEGER NOT NULL REFERENCES wallet_providers(id) ON DELETE RESTRICT, '
      "phone TEXT NOT NULL DEFAULT '', "
      'owner_id INTEGER REFERENCES owners(id) ON DELETE RESTRICT, '
      'sim_id INTEGER REFERENCES sim_lines(id) ON DELETE RESTRICT, '
      'device_id INTEGER REFERENCES devices(id) ON DELETE RESTRICT, '
      "nickname TEXT NOT NULL DEFAULT '', "
      'opening_minor INTEGER, opening_date TEXT, '
      'last_confirmed_minor INTEGER, last_confirmed_ts INTEGER, '
      "archived INTEGER NOT NULL DEFAULT 0, notes TEXT NOT NULL DEFAULT '', "
      'legacy_account_id INTEGER UNIQUE, created_at INTEGER NOT NULL)');
  // One active wallet per provider and number; archived wallets are exempt so
  // a number can be re-registered after archiving.
  await d.execute('CREATE UNIQUE INDEX IF NOT EXISTS ux_wallet_active_phone '
      "ON wallet_accounts(provider_id, phone) WHERE archived = 0 AND phone <> ''");
  await d.execute(
      'CREATE INDEX IF NOT EXISTS ix_wallet_owner ON wallet_accounts(owner_id)');
  await d.execute(
      'CREATE INDEX IF NOT EXISTS ix_wallet_sim ON wallet_accounts(sim_id)');
  await d.execute(
      'CREATE INDEX IF NOT EXISTS ix_sim_history ON sim_device_history(sim_id, to_ts)');
  await d.execute('CREATE TABLE IF NOT EXISTS sms_candidates('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, k TEXT NOT NULL UNIQUE, '
      'sender TEXT NOT NULL, body TEXT NOT NULL, ts INTEGER NOT NULL, '
      "sub_id INTEGER, status TEXT NOT NULL DEFAULT 'pending', "
      'created_at INTEGER NOT NULL)');
  await d.execute('CREATE TABLE IF NOT EXISTS migration_log('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, '
      'from_version INTEGER, to_version INTEGER, note TEXT NOT NULL, '
      "detail TEXT NOT NULL DEFAULT '')");

  // Transactions: a wallet link that is never guessed (NULL until the owner
  // links it), piaster columns beside the untouched REAL ones, provenance.
  await addColumn(d, 'tx', 'wallet_account_id',
      'INTEGER REFERENCES wallet_accounts(id) ON DELETE RESTRICT');
  await addColumn(d, 'tx', 'amount_minor', 'INTEGER');
  await addColumn(d, 'tx', 'fee_minor', 'INTEGER');
  await addColumn(d, 'tx', 'balance_minor', 'INTEGER');
  await addColumn(d, 'tx', 'source', "TEXT NOT NULL DEFAULT 'sms'");
  await addColumn(d, 'tx', 'date_inferred', 'INTEGER NOT NULL DEFAULT 0');
  await d.execute(
      'CREATE INDEX IF NOT EXISTS ix_tx_wallet_account ON tx(wallet_account_id)');
  await d.execute('CREATE INDEX IF NOT EXISTS ix_tx_ts ON tx(ts)');
  await d.execute(
      "UPDATE tx SET source = 'excel' WHERE k LIKE 'xlsx|%' AND source = 'sms'");

  for (final p in _seedProviders) {
    await d.insert(
        'wallet_providers',
        {
          'code': p.$1,
          'name': p.$2,
          'category': p.$3,
          'sender_patterns': jsonEncode(p.$4),
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  await _backfillMinor(d, fromVersion);
  await _mirrorLegacyAccounts(d, fromVersion);
}

/// Fills the integer-piaster columns from the REAL ones, only where the value
/// is exactly representable; everything else is listed in migration_log.
Future<void> _backfillMinor(DatabaseExecutor d, int fromVersion) async {
  final rows = await d.query('tx',
      columns: ['id', 'amount', 'fee', 'balance'],
      where:
          'amount_minor IS NULL AND fee_minor IS NULL AND balance_minor IS NULL');
  final inexact = <String>[];
  var converted = 0;
  for (final r in rows) {
    final a = r['amount'] as num?;
    final f = r['fee'] as num?;
    final b = r['balance'] as num?;
    final am = exactMinor(a), fm = exactMinor(f), bm = exactMinor(b);
    if ((a != null && am == null) ||
        (f != null && fm == null) ||
        (b != null && bm == null)) {
      inexact.add('${r['id']}:$a/$f/$b');
    }
    if (am == null && fm == null && bm == null) continue;
    await d.update(
        'tx', {'amount_minor': am, 'fee_minor': fm, 'balance_minor': bm},
        where: 'id = ?', whereArgs: [r['id']]);
    converted++;
  }
  await logMigration(
      d,
      fromVersion,
      6,
      'piaster backfill: $converted rows converted, ${inexact.length} with sub-piaster precision left unconverted',
      inexact.join(';'));
}

/// The owner's own wallet numbers become wallet accounts. Transactions are NOT
/// linked to them: that stays an explicit owner action.
Future<void> _mirrorLegacyAccounts(DatabaseExecutor d, int fromVersion) async {
  if (!await _tableExists(d, 'accounts')) return;
  final accounts = await d.query('accounts');
  var mirrored = 0;
  final skipped = <String>[];
  for (final a in accounts) {
    final code = legacyWalletProviderCodes[a['wallet']];
    if (code == null) {
      skipped.add('${a['id']}:${a['wallet']}');
      continue;
    }
    final prov = await d.query('wallet_providers',
        columns: ['id'], where: 'code = ?', whereArgs: [code]);
    final exists = await d.query('wallet_accounts',
        columns: ['id'], where: 'legacy_account_id = ?', whereArgs: [a['id']]);
    if (exists.isNotEmpty) continue;
    final n = await d.insert(
        'wallet_accounts',
        {
          'provider_id': prov.first['id'],
          'phone': (a['number'] as String?) ?? '',
          'nickname': (a['name'] as String?) ?? '',
          'legacy_account_id': a['id'],
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    if (n > 0) mirrored++;
  }
  if (accounts.isNotEmpty) {
    await logMigration(
        d,
        fromVersion,
        6,
        'legacy accounts mirrored to wallet_accounts: $mirrored of ${accounts.length}',
        skipped.join(';'));
  }
}

/// Keeps `wallet_accounts` in step with the legacy `accounts` table that the
/// setup wizard and the older screens still write: every legacy account gets
/// one wallet (matched by `legacy_account_id`), number and nickname follow
/// later edits, and an account the owner removed archives its wallet (history
/// is never deleted). Idempotent, and it never guesses a provider: accounts
/// whose wallet name is not a known provider are skipped.
Future<int> syncLegacyAccounts(DatabaseExecutor d) async {
  var created = 0;
  final accounts = await d.query('accounts');
  final liveIds = <int>{};
  for (final a in accounts) {
    final id = a['id']! as int;
    liveIds.add(id);
    final code = legacyWalletProviderCodes[a['wallet']];
    if (code == null) continue;
    final existing = await d.query('wallet_accounts',
        where: 'legacy_account_id = ?', whereArgs: [id]);
    final phone = (a['number'] as String?) ?? '';
    final nick = (a['name'] as String?) ?? '';
    if (existing.isEmpty) {
      final prov = await d.query('wallet_providers',
          columns: ['id'], where: 'code = ?', whereArgs: [code]);
      if (prov.isEmpty) continue;
      final n = await d.insert(
          'wallet_accounts',
          {
            'provider_id': prov.first['id'],
            'phone': phone,
            'nickname': nick,
            'legacy_account_id': id,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      if (n > 0) created++;
    } else if (existing.first['phone'] != phone ||
        existing.first['nickname'] != nick) {
      await d.update('wallet_accounts', {'phone': phone, 'nickname': nick},
          where: 'id = ?',
          whereArgs: [existing.first['id']],
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }
  for (final w in await d.query('wallet_accounts',
      where: 'legacy_account_id IS NOT NULL AND archived = 0')) {
    if (!liveIds.contains(w['legacy_account_id'])) {
      await d.update('wallet_accounts', {'archived': 1},
          where: 'id = ?', whereArgs: [w['id']]);
    }
  }
  return created;
}

/// Attributes SMS / sheet rows that have no wallet yet, only when exactly one
/// wallet can own them: same provider and, when the row carries a SIM, the
/// wallet whose account was set up for that SIM. Anything ambiguous stays
/// unlinked for the owner to place; nothing is guessed between two wallets.
Future<int> autoLinkTransactions(DatabaseExecutor d) async {
  final wallets = await d
      .rawQuery('SELECT w.id, p.code, a.sub_id AS sub FROM wallet_accounts w '
          'JOIN wallet_providers p ON p.id = w.provider_id '
          'LEFT JOIN accounts a ON a.id = w.legacy_account_id '
          'WHERE w.archived = 0');
  if (wallets.isEmpty) return 0;
  final rows = await d.query('tx',
      columns: ['id', 'wallet', 'sub_id'],
      where:
          "wallet_account_id IS NULL AND source IN ('sms','excel') AND disposition = 'active'");
  var linked = 0;
  for (final r in rows) {
    final code = legacyWalletProviderCodes[r['wallet']];
    if (code == null) continue;
    var cands = wallets.where((w) => w['code'] == code).toList();
    final sub = r['sub_id'] as int?;
    if (sub != null && cands.length > 1) {
      final bySim = cands.where((w) => w['sub'] == sub).toList();
      if (bySim.isNotEmpty) cands = bySim;
    }
    if (cands.length != 1) continue;
    await d.update('tx', {'wallet_account_id': cands.first['id']},
        where: 'id = ?', whereArgs: [r['id']]);
    linked++;
  }
  return linked;
}

/// v6 -> v7: append-only audit trail, reversal link and revalidation marks.
/// Purely additive; safe to run again.
Future<void> applyV7(DatabaseExecutor d) async {
  // One row per correction / reversal / creation; events point back to it.
  await d.execute('CREATE TABLE IF NOT EXISTS audit_groups('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, '
      'tx_id INTEGER NOT NULL, source TEXT NOT NULL, '
      "reason TEXT NOT NULL DEFAULT '', ts INTEGER NOT NULL)");
  // One row per changed field. Values are stored as text (piasters as integers).
  await d.execute('CREATE TABLE IF NOT EXISTS audit_events('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, tx_id INTEGER NOT NULL, '
      'event TEXT NOT NULL, field TEXT, old_value TEXT, new_value TEXT, '
      'source TEXT NOT NULL, reason TEXT NOT NULL DEFAULT \'\', '
      'ts INTEGER NOT NULL, related_id INTEGER REFERENCES audit_groups(id))');
  await d.execute(
      'CREATE INDEX IF NOT EXISTS ix_audit_tx ON audit_events(tx_id, id)');
  // Transactions whose reconciliation must be re-checked after a change.
  await d.execute('CREATE TABLE IF NOT EXISTS revalidation_marks('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, tx_id INTEGER NOT NULL, '
      'wallet_account_id INTEGER, caused_by INTEGER REFERENCES audit_groups(id), '
      'created_at INTEGER NOT NULL, cleared_at INTEGER)');
  await d.execute(
      'CREATE INDEX IF NOT EXISTS ix_reval_open ON revalidation_marks(tx_id) WHERE cleared_at IS NULL');

  await addColumn(d, 'tx', 'balance_before_minor', 'INTEGER');
  await addColumn(d, 'tx', 'reverses_tx_id',
      'INTEGER REFERENCES tx(id) ON DELETE RESTRICT');
  // A transaction can have at most one full reversal.
  await d.execute('CREATE UNIQUE INDEX IF NOT EXISTS ux_tx_reverses '
      'ON tx(reverses_tx_id) WHERE reverses_tx_id IS NOT NULL');

  for (final t in ['audit_events', 'audit_groups']) {
    await d.execute(
        'CREATE TRIGGER IF NOT EXISTS ${t}_no_update BEFORE UPDATE ON $t '
        "BEGIN SELECT RAISE(ABORT, 'audit history is append-only'); END");
    await d.execute(
        'CREATE TRIGGER IF NOT EXISTS ${t}_no_delete BEFORE DELETE ON $t '
        "BEGIN SELECT RAISE(ABORT, 'audit history is append-only'); END");
  }
  // Rows with history cannot be removed, and original SMS / sheet text cannot
  // be replaced once stored.
  await d.execute(
      'CREATE TRIGGER IF NOT EXISTS tx_keep_audited BEFORE DELETE ON tx '
      'WHEN EXISTS (SELECT 1 FROM audit_events WHERE tx_id = OLD.id) '
      'OR OLD.reverses_tx_id IS NOT NULL '
      'OR EXISTS (SELECT 1 FROM tx WHERE reverses_tx_id = OLD.id) '
      "BEGIN SELECT RAISE(ABORT, 'transaction has audit history'); END");
  await d.execute(
      'CREATE TRIGGER IF NOT EXISTS tx_keep_evidence BEFORE UPDATE OF body ON tx '
      "WHEN OLD.body IS NOT NULL AND OLD.body <> '' AND NEW.body IS NOT OLD.body "
      "BEGIN SELECT RAISE(ABORT, 'original message text is immutable'); END");
}

/// Confirmation states of a transaction. `awaiting` covers both "recorded by
/// hand" and "waiting for the wallet notification"; whether proof exists is
/// derived from the evidence table, not stored, so there is one source of truth.
class Confirmation {
  static const awaiting = 'awaiting';
  static const providerConfirmed = 'provider_confirmed';
  static const balanceConfirmed = 'balance_confirmed';
  static const mismatched = 'mismatched';
  static const disputed = 'disputed';
  static const failed = 'failed';
  static const cancelled = 'cancelled';
  static const reversed = 'reversed';
  static const all = {
    awaiting,
    providerConfirmed,
    balanceConfirmed,
    mismatched,
    disputed,
    failed,
    cancelled,
    reversed
  };

  /// States whose money counts toward confirmed totals and balances.
  static const counted = {providerConfirmed, balanceConfirmed};
}

/// v7 -> v8: confirmation status, evidence attachments, delayed-SMS match
/// suggestions and stored AI suggestions. Purely additive; safe to run again.
Future<void> applyV8(DatabaseExecutor d) async {
  await addColumn(d, 'tx', 'confirmation', "TEXT NOT NULL DEFAULT 'awaiting'");
  await addColumn(d, 'tx', 'confirmed_at', 'INTEGER');
  await addColumn(d, 'tx', 'reference', 'TEXT');
  await addColumn(d, 'tx', 'fee_owner', "TEXT NOT NULL DEFAULT 'owner'");
  await addColumn(d, 'tx', 'transfer_peer_id',
      'INTEGER REFERENCES tx(id) ON DELETE RESTRICT');
  await addColumn(d, 'tx', 'linked_to_tx_id',
      'INTEGER REFERENCES tx(id) ON DELETE RESTRICT');
  // No blanket back-fill of 'confirmed': v9 decides row by row from content.
  // A reversed original is not rewritten: it is 'reversed' because another row
  // points at it through reverses_tx_id (see ConfirmedTotals).
  await d
      .execute('CREATE INDEX IF NOT EXISTS ix_tx_reference ON tx(reference)');
  await d.execute(
      'CREATE INDEX IF NOT EXISTS ix_tx_confirmation ON tx(confirmation)');

  // Append-only: files are copied into private storage and never replaced.
  // Removing from the active view only stamps removed_at / removed_reason.
  await d.execute('CREATE TABLE IF NOT EXISTS evidence('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'tx_id INTEGER NOT NULL REFERENCES tx(id) ON DELETE RESTRICT, '
      'kind TEXT NOT NULL, origin TEXT NOT NULL, '
      "uploaded_by TEXT NOT NULL DEFAULT 'owner', "
      'file_path TEXT, file_name TEXT, mime TEXT, size INTEGER, sha256 TEXT, '
      'sms_sender TEXT, sms_body TEXT, sms_ts INTEGER, sms_sub_id INTEGER, '
      'reference TEXT, '
      "note TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL, "
      'removed_at INTEGER, removed_reason TEXT)');
  await d
      .execute('CREATE INDEX IF NOT EXISTS ix_evidence_tx ON evidence(tx_id)');
  await d.execute('CREATE UNIQUE INDEX IF NOT EXISTS ux_evidence_hash '
      'ON evidence(tx_id, sha256) WHERE sha256 IS NOT NULL AND removed_at IS NULL');
  await d.execute(
      'CREATE TRIGGER IF NOT EXISTS evidence_no_delete BEFORE DELETE ON evidence '
      "BEGIN SELECT RAISE(ABORT, 'evidence is never deleted'); END");
  await d.execute(
      'CREATE TRIGGER IF NOT EXISTS evidence_immutable BEFORE UPDATE ON evidence '
      'WHEN NEW.tx_id IS NOT OLD.tx_id OR NEW.kind IS NOT OLD.kind '
      'OR NEW.origin IS NOT OLD.origin OR NEW.uploaded_by IS NOT OLD.uploaded_by '
      'OR NEW.file_path IS NOT OLD.file_path OR NEW.sha256 IS NOT OLD.sha256 '
      'OR NEW.sms_body IS NOT OLD.sms_body OR NEW.created_at IS NOT OLD.created_at '
      'OR (OLD.removed_at IS NOT NULL AND NEW.removed_at IS NOT OLD.removed_at) '
      "BEGIN SELECT RAISE(ABORT, 'evidence content is immutable'); END");

  // A delayed SMS (sms_tx_id) that probably refers to a hand-typed record.
  await d.execute('CREATE TABLE IF NOT EXISTS match_suggestions('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'manual_tx_id INTEGER NOT NULL REFERENCES tx(id) ON DELETE RESTRICT, '
      'sms_tx_id INTEGER NOT NULL REFERENCES tx(id) ON DELETE RESTRICT, '
      "score INTEGER NOT NULL, reasons TEXT NOT NULL DEFAULT '[]', "
      "conflicts TEXT NOT NULL DEFAULT '[]', "
      "status TEXT NOT NULL DEFAULT 'pending', "
      'created_at INTEGER NOT NULL, decided_at INTEGER, '
      'UNIQUE(manual_tx_id, sms_tx_id))');

  // AI output is stored, never applied: the owner accepts or dismisses it.
  await d.execute('CREATE TABLE IF NOT EXISTS ai_suggestions('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'tx_id INTEGER REFERENCES tx(id) ON DELETE RESTRICT, '
      'related_tx_id INTEGER REFERENCES tx(id) ON DELETE RESTRICT, '
      'kind TEXT NOT NULL, action TEXT NOT NULL, '
      "reason TEXT NOT NULL DEFAULT '', payload TEXT NOT NULL DEFAULT '{}', "
      'confidence REAL, input_hash TEXT NOT NULL, '
      "status TEXT NOT NULL DEFAULT 'pending', "
      'created_at INTEGER NOT NULL, decided_at INTEGER, '
      'UNIQUE(input_hash, kind, action))');
  await d.execute(
      'CREATE INDEX IF NOT EXISTS ix_ai_sugg_status ON ai_suggestions(status)');
  await logMigration(
      d, 7, 8, 'confirmation status, evidence, match and AI suggestions added');
}

/// v8 -> v9: records *how* a row was confirmed, and re-judges legacy rows.
/// Additive and safe to run again. A row is provider-confirmed only when its
/// own text reports a completed transaction; imported sheet rows are never
/// confirmed by import. Rows the owner already decided on are left alone.
Future<void> applyV9(DatabaseExecutor d) async {
  await addColumn(d, 'tx', 'confirmation_method', 'TEXT');
  final rows = await d.rawQuery(
      "SELECT id, source, body, ts, confirmation FROM tx WHERE confirmation_method IS NULL "
      "AND source IN ('sms','excel') "
      "AND id NOT IN (SELECT tx_id FROM audit_events WHERE event = 'confirmation')");
  var confirmed = 0, failed = 0, unverified = 0;
  for (final r in rows) {
    final id = r['id']! as int;
    final old = r['confirmation'] as String? ?? 'awaiting';
    String status;
    String? method;
    if (r['source'] == 'excel') {
      status = Confirmation.awaiting;
    } else {
      switch (classifySmsCompletion((r['body'] as String?) ?? '')) {
        case SmsOutcome.completed:
          status = Confirmation.providerConfirmed;
          method = ConfirmMethod.smsContent;
        case SmsOutcome.failed:
          status = Confirmation.failed;
        case SmsOutcome.pending:
        case SmsOutcome.unclear:
          status = Confirmation.awaiting;
      }
    }
    if (status == Confirmation.providerConfirmed) {
      confirmed++;
    } else if (status == Confirmation.failed) {
      failed++;
    } else {
      unverified++;
    }
    await d.update(
        'tx',
        {
          'confirmation': status,
          'confirmation_method': method,
          'confirmed_at': method == null ? null : r['ts'],
        },
        where: 'id = ?',
        whereArgs: [id]);
    if (old != status) {
      await d.insert('audit_events', {
        'tx_id': id,
        'event': 'confirmation',
        'field': 'confirmation',
        'old_value': old,
        'new_value': status,
        'source': 'reconciliation',
        'reason': 'migration v9: judged from the message text, not the sender',
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }
  await logMigration(d, 8, 9,
      'legacy confirmation re-judged: $confirmed completed, $failed failed, $unverified unverified');
}

/// v9 -> v10: remembers which "same text" rule excluded a message, so
/// deleting the rule brings exactly those messages back. Additive.
///
/// Messages the owner already chose to ignore become "same text" rules, so
/// waiting messages like them are excluded too (on the next read). Messages
/// marked as duplicates are left alone: a duplicate has the same text as the
/// real one.
Future<void> applyV10(DatabaseExecutor d) async {
  await addColumn(d, 'tx', 'excluded_by_rule', 'INTEGER');
  final ignored = await d.rawQuery(
      "SELECT body FROM tx WHERE disposition = 'ignored' "
      "AND reverses_tx_id IS NULL AND body IS NOT NULL AND body <> ''");
  final templates = {
    for (final r in ignored) messageTemplate(r['body']! as String)
  }..remove('');
  for (final t in templates) {
    await d.insert(
        'exclusion_rules', {'wallet': '', 'match_mode': 'template', 'pattern': t},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  await logMigration(d, 9, 10, 'same-text exclusion rules',
      '${templates.length} from messages already ignored');
}

/// Runs the whole upgrade and refuses (by throwing, which rolls the migration
/// back) if any existing transaction row would be lost.
Future<void> migrate(Database d, int oldV, int newV) async {
  final before =
      oldV >= 2 && await _tableExists(d, 'tx') ? await _count(d, 'tx') : null;
  if (oldV < 2) {
    await preserveLegacyV1(d);
  }
  await createCore(d);
  if (oldV == 2) {
    await addColumn(d, 'tx', 'type', "TEXT NOT NULL DEFAULT 'other'");
    await addColumn(d, 'tx', 'fee', 'REAL NOT NULL DEFAULT 0');
    await addColumn(d, 'tx', 'review', 'INTEGER NOT NULL DEFAULT 0');
    await addColumn(d, 'tx', 'manual', 'INTEGER NOT NULL DEFAULT 0');
    await rekeyV2(d);
  }
  await addColumn(d, 'tx', 'ai', 'INTEGER NOT NULL DEFAULT 0');
  await addColumn(d, 'tx', 'ai_note', "TEXT NOT NULL DEFAULT ''");
  await addColumn(d, 'accounts', 'slot', 'INTEGER');
  await addColumn(d, 'tx', 'disposition', "TEXT NOT NULL DEFAULT 'active'");
  await addColumn(d, 'tx', 'rule_exempt', 'INTEGER NOT NULL DEFAULT 0');
  if (oldV < 6) await applyV6(d, oldV);
  if (oldV < 7) await applyV7(d);
  if (oldV < 8) await applyV8(d);
  if (oldV < 9) await applyV9(d);
  if (oldV < 10) await applyV10(d);
  if (before != null && await _count(d, 'tx') != before) {
    throw StateError('migration would change the transaction count; aborted');
  }
}

/// Post-migration checks. Empty list = healthy.
Future<List<String>> integrityProblems(DatabaseExecutor d) async {
  final problems = <String>[];
  final ic = await d.rawQuery('PRAGMA integrity_check');
  if (ic.length != 1 || ic.first.values.first != 'ok') {
    problems.add('integrity_check: ${ic.map((r) => r.values.first).join(',')}');
  }
  for (final r in await d.rawQuery('PRAGMA foreign_key_check')) {
    problems.add('foreign_key_check: ${r['table']} row ${r['rowid']}');
  }
  final orphan = Sqflite.firstIntValue(await d.rawQuery(
      'SELECT COUNT(*) FROM tx WHERE wallet_account_id IS NOT NULL AND '
      'wallet_account_id NOT IN (SELECT id FROM wallet_accounts)'));
  if ((orphan ?? 0) > 0) problems.add('tx linked to a missing wallet: $orphan');
  final bad = Sqflite.firstIntValue(await d
      .rawQuery('SELECT COUNT(*) FROM tx WHERE amount_minor IS NOT NULL AND '
          'ABS(amount * 100 - amount_minor) > 0.000001'));
  if ((bad ?? 0) > 0) problems.add('piaster value differs from REAL: $bad');
  return problems;
}
