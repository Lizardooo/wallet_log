import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'importer.dart';
import 'exclusions.dart';
import 'parser.dart';
import 'money_engine.dart';
import 'schema.dart';
import 'confirmation_rules.dart';
import 'wallet_store.dart';
import 'ledger_service.dart';
import 'evidence_service.dart';
import 'ai_suggestions.dart';
import 'match_service.dart';
import 'summary_service.dart';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

class Tx {
  final int id;
  final int ts;
  final String wallet;
  final TxType type;
  final Dir dir;
  final double amount;
  final double fee;
  final String? party;
  final double? balance;
  final int? subId;
  final String note;
  final String body;
  final bool review; // classification uncertain: needs the owner's check
  final bool manual; // the owner corrected it by hand
  final bool ai; // classified by the Gemini model
  final String aiNote; // the model's short reason
  final TxDisposition disposition;
  final int? exclusionRuleId;
  final bool ruleExempt;

  /// Set on a reversal record: the transaction it reverses.
  final int? reversalOf;

  /// true when a reversal record exists for this transaction.
  final bool reversed;
  final String source;

  const Tx({
    required this.id,
    required this.ts,
    required this.wallet,
    required this.type,
    required this.dir,
    required this.amount,
    this.fee = 0,
    this.party,
    this.balance,
    this.subId,
    this.note = '',
    this.body = '',
    this.review = false,
    this.manual = false,
    this.ai = false,
    this.aiNote = '',
    this.disposition = TxDisposition.active,
    this.exclusionRuleId,
    this.ruleExempt = false,
    this.reversalOf,
    this.reversed = false,
    this.source = 'sms',
  });

  bool get isExcluded => disposition != TxDisposition.active;

  bool get isIn => dir == Dir.inFlow;
  bool get isOut => dir == Dir.outFlow;
  bool get isUnknown => dir == Dir.unknown;
}

/// One of the trader's own wallet numbers (e.g. "Vodafone - phone 1").
class Account {
  final int? id;
  final String name;
  final String wallet;
  final String number;

  /// Android subscription id of the SIM that receives the messages. This is
  /// what SMS rows carry, so it is what matching compares.
  final int? subId;

  /// Physical SIM slot (0 = first SIM, 1 = second SIM) as the phone reports it.
  final int? slot;

  const Account({
    this.id,
    required this.name,
    required this.wallet,
    this.number = '',
    this.subId,
    this.slot,
  });
}

/// Whether an SMS for [wallet] received on [subId] belongs to one of the
/// numbers the owner chose. A message is rejected only when every selected
/// number of this wallet has a known SIM and none matches; when the receiving
/// SIM or an account's SIM is unknown, it is kept for that wallet type.
bool smsBelongsToAccounts(String wallet, int? subId, List<Account> accounts) {
  final sameWallet = accounts.where((a) => a.wallet == wallet).toList();
  if (sameWallet.isEmpty) return false;
  if (subId == null) return true;
  if (sameWallet.any((a) => a.subId == subId)) return true;
  return sameWallet.any((a) => a.subId == null);
}

class RawSms {
  final String sender;
  final String body;
  final int ts;
  final int? subId;

  const RawSms(this.sender, this.body, this.ts, this.subId);
}

/// A SIM the phone reports (needs the phone-state permission).
class SimSlot {
  final int? subId;
  final int slot;
  final String carrier;
  final String number;

  const SimSlot({
    required this.slot,
    this.subId,
    this.carrier = '',
    this.number = '',
  });

  /// "شريحة 1 · Vodafone" — used in the setup wizard and account rows.
  String get label {
    final parts = ['شريحة ${slot + 1}'];
    if (carrier.isNotEmpty) parts.add(carrier);
    if (number.isNotEmpty) parts.add(number);
    return parts.join(' · ');
  }
}

/// A classification coming back from the Gemini model.
class AiUpdate {
  final int id;
  final TxType type;
  final Dir dir;
  final bool confirm; // false keeps the message in the review list
  final String note;

  const AiUpdate({
    required this.id,
    required this.type,
    required this.dir,
    required this.confirm,
    this.note = '',
  });
}

String dirString(Dir d) => switch (d) {
      Dir.inFlow => 'in',
      Dir.outFlow => 'out',
      Dir.unknown => 'unknown',
    };

Dir dirFromString(String? s) => s == 'in'
    ? Dir.inFlow
    : s == 'out'
        ? Dir.outFlow
        : Dir.unknown;

class TxDb {
  static Database? _db;

  static const settingsSetupDone = 'setup_done';
  static const settingsApiKey = 'gemini_api_key';
  static const settingsModel = 'gemini_model';
  static const settingsOwnerPhone = 'owner_phone';

  /// '1' = keep SMS from unknown senders that look like wallet messages in a
  /// review inbox (off by default).
  static const settingsStoreCandidates = 'store_unknown_candidates';

  static Future<Database> get _database async {
    if (_db != null) return _db!;
    final path = join(await getDatabasesPath(), 'wallet.db');
    // A restorable copy of the file is taken before any schema upgrade.
    await backupBeforeMigration(path, schemaVersion);
    final opened = await openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      onCreate: (d, v) async {
        await createCore(d);
        await applyV6(d, 0);
        await applyV7(d);
        await applyV8(d);
        await applyV9(d);
      },
      onUpgrade: migrate,
    );
    // Wallets made by the setup wizard exist only as legacy accounts until now.
    await syncLegacyAccounts(opened);
    await autoLinkTransactions(opened);
    return _db = opened;
  }

  /// Parses and stores messages. Non-transactions and duplicates are ignored, so
  /// rescanning the whole inbox is safe. Rows the owner has corrected by hand
  /// (manual = 1), rows the model classified (ai = 1) and their notes are never
  /// overwritten; other rows are re-classified so improvements to the parser
  /// apply to old messages too. When [accounts] is not empty, new messages that
  /// do not belong to one of the owner's chosen numbers are skipped; rows that
  /// are already stored are left untouched.
  static Future<void> importSms(List<RawSms> msgs,
      {List<Account>? accounts}) async {
    final db = await _database;
    final batch = db.batch();
    final rules = await _rules(db);
    final chosen = accounts != null && accounts.isNotEmpty ? accounts : null;
    final keepCandidates = (await setting(settingsStoreCandidates)) == '1';
    for (final m in msgs) {
      final p = parseSms(m.sender, m.body);
      final key = smsKey(m.body, m.ts);
      final wallet = p?.wallet ?? detectWallet(m.sender, m.body);
      if (wallet == null &&
          keepCandidates &&
          isWalletCandidate(m.sender, m.body)) {
        // Opt-in only, and never turned into a transaction automatically.
        batch.insert(
          'sms_candidates',
          {
            'k': key,
            'sender': m.sender,
            'body': m.body,
            'ts': m.ts,
            'sub_id': m.subId,
            'created_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      final rule =
          wallet == null ? null : matchingExclusionRule(rules, wallet, m.body);
      if (p == null) {
        // Do not fabricate a transaction for a message the parser rejected.
        // Retain previously archived matches and deliberate owner decisions.
        if (rule == null) {
          batch.delete(
            'tx',
            where: "k = ? AND manual = 0 AND ai = 0 AND note = '' "
                "AND disposition = 'active' AND rule_exempt = 0"
                " AND id NOT IN (SELECT tx_id FROM audit_events)",
            whereArgs: [key],
          );
        }
        continue;
      }
      if (chosen != null && !smsBelongsToAccounts(wallet!, m.subId, chosen)) {
        continue;
      }
      final dirStr = dirString(p.dir);
      batch.insert(
        'tx',
        {
          'k': key,
          'ts': m.ts,
          'wallet': wallet,
          'dir': dirStr,
          'type': p.type.name,
          'amount': p.amount,
          'fee': p.fee,
          'party': p.party,
          'balance': p.balance,
          'amount_minor': exactMinor(p.amount),
          'fee_minor': exactMinor(p.fee),
          'balance_minor': exactMinor(p.balance),
          'sub_id': m.subId,
          'review': (rule != null || p.review) ? 1 : 0,
          'body': m.body,
          'reference': extractReference(m.body),
          // Only a message that reports a completed transaction counts.
          'confirmation': switch (classifySmsCompletion(m.body)) {
            SmsOutcome.completed => Confirmation.providerConfirmed,
            SmsOutcome.failed => Confirmation.failed,
            _ => Confirmation.awaiting,
          },
          'confirmation_method':
              classifySmsCompletion(m.body) == SmsOutcome.completed
                  ? ConfirmMethod.smsContent
                  : null,
          'confirmed_at': classifySmsCompletion(m.body) == SmsOutcome.completed
              ? m.ts
              : null,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      batch.update(
        'tx',
        {
          'wallet': wallet,
          'dir': dirStr,
          'type': p.type.name,
          'amount': p.amount,
          'fee': p.fee,
          'party': p.party,
          'balance': p.balance,
          'amount_minor': exactMinor(p.amount),
          'fee_minor': exactMinor(p.fee),
          'balance_minor': exactMinor(p.balance),
          'review': (rule != null || p.review) ? 1 : 0,
        },
        where:
            "k = ? AND manual = 0 AND ai = 0 AND disposition = 'active' AND rule_exempt = 0"
            " AND id NOT IN (SELECT tx_id FROM audit_events)",
        whereArgs: [key],
      );
    }
    await batch.commit(noResult: true);
    // A delayed SMS may belong to a record typed in by hand: only suggest.
    await autoLinkTransactions(db);
    await MatchService(db).suggestAll();
  }

  static Future<List<Tx>> allTx() async {
    final db = await _database;
    final rows = await db.query('tx', orderBy: 'ts DESC, id DESC');
    final rules = await _rules(db);
    final reversedIds = {
      for (final r in rows)
        if (r['reverses_tx_id'] != null) r['reverses_tx_id'] as int
    };
    return rows.map((r) {
      final typeStr = r['type'] as String?;
      final stored = dispositionFromString(r['disposition'] as String?);
      final exempt = (r['rule_exempt'] as int?) == 1;
      final rule = stored == TxDisposition.active && !exempt
          ? matchingExclusionRule(rules, (r['wallet'] as String?) ?? '',
              (r['body'] as String?) ?? '')
          : null;
      return Tx(
        id: r['id'] as int,
        ts: r['ts'] as int,
        wallet: (r['wallet'] as String?) ?? '',
        type: TxType.values.firstWhere(
          (t) => t.name == typeStr,
          orElse: () => TxType.other,
        ),
        dir: dirFromString(r['dir'] as String?),
        amount: ((r['amount'] as num?) ?? 0).toDouble(),
        fee: ((r['fee'] as num?) ?? 0).toDouble(),
        party: r['party'] as String?,
        balance: (r['balance'] as num?)?.toDouble(),
        subId: r['sub_id'] as int?,
        note: (r['note'] as String?) ?? '',
        body: (r['body'] as String?) ?? '',
        review: (r['review'] as int?) == 1,
        manual: (r['manual'] as int?) == 1,
        ai: (r['ai'] as int?) == 1,
        aiNote: (r['ai_note'] as String?) ?? '',
        // A reversed transaction and its reversal record net to zero: both
        // stay visible but are kept out of every total.
        disposition: (rule != null ||
                r['reverses_tx_id'] != null ||
                reversedIds.contains(r['id']))
            ? TxDisposition.ignored
            : stored,
        reversalOf: r['reverses_tx_id'] as int?,
        reversed: reversedIds.contains(r['id']),
        source: (r['source'] as String?) ?? 'sms',
        exclusionRuleId: rule?.id,
        ruleExempt: exempt,
      );
    }).toList();
  }

  static Future<void> setNote(int id, String note) async {
    final db = await _database;
    await db.transaction((txn) async {
      final rows = await txn.query('tx',
          columns: ['note'], where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) return;
      if (rows.first['note'] != note) {
        final g = await startAuditGroup(
            txn, 'correction', id, AuditSource.manual, '');
        await writeAudit(txn,
            txId: id,
            event: 'correct',
            field: 'note',
            oldValue: rows.first['note'],
            newValue: note,
            source: AuditSource.manual,
            groupId: g);
      }
      await txn.update('tx', {'note': note}, where: 'id = ?', whereArgs: [id]);
    });
  }

  /// The owner's correction of type and direction; it is never overwritten.
  static Future<void> setClass(int id, TxType type, Dir dir) async {
    final db = await _database;
    await db.transaction((txn) async {
      final rows = await txn.query('tx', where: 'id = ?', whereArgs: [id]);
      final rules = await _rules(txn);
      if (rows.isEmpty || _excluded(rows.first, rules)) return;
      final old = rows.first;
      final changed = {
        if (old['type'] != type.name) 'type': (old['type'], type.name),
        if (old['dir'] != dirString(dir)) 'dir': (old['dir'], dirString(dir)),
      };
      if (changed.isNotEmpty) {
        final g = await startAuditGroup(
            txn, 'correction', id, AuditSource.manual, '');
        for (final e in changed.entries) {
          await writeAudit(txn,
              txId: id,
              event: 'correct',
              field: e.key,
              oldValue: e.value.$1,
              newValue: e.value.$2,
              source: AuditSource.manual,
              groupId: g);
        }
      }
      await txn.update(
          'tx',
          {
            'type': type.name,
            'dir': dirString(dir),
            'review': 0,
            'manual': 1,
          },
          where: 'id = ?',
          whereArgs: [id]);
    });
  }

  /// AI responses already in flight cannot reactivate excluded messages.
  static Future<Set<int>> applyAiUpdates(List<AiUpdate> updates) async {
    if (updates.isEmpty) return {};
    final db = await _database;
    return db.transaction<Set<int>>((txn) async {
      final rules = await _rules(txn);
      final rows = await txn.query('tx');
      final byId = {for (final r in rows) r['id'] as int: r};
      final allowed = {
        for (final r in rows)
          if (r['manual'] != 1 && !_excluded(r, rules)) r['id'] as int
      };
      final saved = <int>{};
      for (final u in updates) {
        if (!allowed.contains(u.id)) continue;
        final row = byId[u.id]!;
        // The model only suggests: the row keeps its parsed values and stays
        // in review until the owner accepts the stored suggestion.
        await txn.update('tx', {'ai_note': u.note, 'review': 1},
            where: "id = ? AND manual = 0 AND disposition = 'active'",
            whereArgs: [u.id]);
        await AiSuggestionService.storeOn(txn,
            txId: u.id,
            kind: AiKind.classify,
            action: 'classify',
            reason: u.note,
            payload: {
              'type': u.type.name,
              'dir': dirString(u.dir),
              'confident': u.confirm
            },
            confidence: u.confirm ? 0.9 : 0.4,
            inputHash:
                aiInputHash((row['body'] as String?) ?? '', kind: '${u.id}'));
        saved.add(u.id);
      }
      return saved;
    });
  }

  /// Re-read each batch, not only the initial queue, so a message excluded
  /// while another AI request runs is not sent in a later batch.
  static Future<List<Tx>> classificationBatch(Iterable<int> ids) async {
    final current = {for (final t in await allTx()) t.id: t};
    return [
      for (final id in ids)
        if (current[id] != null && !current[id]!.isExcluded) current[id]!
    ];
  }

  static bool _excluded(Map<String, Object?> row, List<ExclusionRule> rules) =>
      dispositionFromString(row['disposition'] as String?) !=
          TxDisposition.active ||
      (row['rule_exempt'] != 1 &&
          matchingExclusionRule(rules, (row['wallet'] as String?) ?? '',
                  (row['body'] as String?) ?? '') !=
              null);

  static Future<List<ExclusionRule>> _rules(DatabaseExecutor db) async {
    final rows = await db.query('exclusion_rules', orderBy: 'id');
    return [
      for (final r in rows)
        ExclusionRule(
            id: r['id'] as int,
            wallet: r['wallet'] as String,
            match: r['match_mode'] == 'contains'
                ? ExclusionMatch.contains
                : ExclusionMatch.exact,
            text: r['pattern'] as String)
    ];
  }

  static Future<List<ExclusionRule>> exclusionRules() async =>
      _rules(await _database);

  /// Store a deliberate decision separately from parser/manual/AI provenance.
  /// A future rule applies retroactively and to new matching messages.
  static Future<void> exclude(
    int id,
    TxDisposition disposition, {
    ExclusionMatch? match,
    String? text,
  }) async {
    if (disposition == TxDisposition.active) {
      throw ArgumentError('Use restoreToReview to restore a message');
    }
    final pattern = normalizeExclusionText(text ?? '');
    if (match != null &&
        (disposition != TxDisposition.ignored || pattern.isEmpty)) {
      throw ArgumentError('A non-empty rule requires the ignored state');
    }
    final db = await _database;
    await db.transaction((txn) async {
      final rows = await txn.query('tx', where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) return;
      if (match != null) {
        final wallet = (rows.first['wallet'] as String?) ?? '';
        if (wallet.isEmpty) throw ArgumentError('A wallet is required');
        await txn.insert(
            'exclusion_rules',
            {
              'wallet': wallet,
              'match_mode': match.name,
              'pattern': pattern,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await txn.update(
          'tx', {'disposition': disposition.name, 'rule_exempt': 0},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Restoring never silently counts an operation. This exact record is exempt
  /// from text rules until its owner explicitly excludes it again.
  static Future<void> restoreToReview(int id) async {
    final db = await _database;
    await db.update(
        'tx',
        {
          'disposition': TxDisposition.active.name,
          'review': 1,
          'rule_exempt': 1,
        },
        where: 'id = ?',
        whereArgs: [id]);
  }

  static Future<void> deleteExclusionRule(int id) async {
    final db = await _database;
    await db.transaction((txn) async {
      final rules = await _rules(txn);
      final selected = rules.where((r) => r.id == id).toList();
      if (selected.isEmpty) return;
      final rows = await txn.query('tx',
          where: "disposition = 'active' AND rule_exempt = 0");
      final batch = txn.batch();
      for (final row in rows) {
        if (selected.single.matches(
            (row['wallet'] as String?) ?? '', (row['body'] as String?) ?? '')) {
          final another = matchingExclusionRule(rules.where((r) => r.id != id),
              (row['wallet'] as String?) ?? '', (row['body'] as String?) ?? '');
          batch.update(
              'tx',
              {
                'review': 1,
                if (another == null) 'rule_exempt': 1,
              },
              where: 'id = ?',
              whereArgs: [row['id']]);
        }
      }
      batch.delete('exclusion_rules', where: 'id = ?', whereArgs: [id]);
      await batch.commit(noResult: true);
    });
  }

  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Inserts rows read from an Excel report. Rows already present (same key) are
  /// skipped, so importing the same file twice changes nothing. Imported rows
  /// are marked manual so the SMS scan never re-classifies them.
  static Future<int> importRows(List<ImportRow> rows,
      {Account? account}) async {
    if (rows.isEmpty) return 0;
    final db = await _database;
    final keys = await db.query('tx', columns: ['k']);
    final present = <String>{
      for (final r in keys) (r['k'] as String?) ?? '',
    };
    final batch = db.batch();
    var added = 0;
    for (final row in rows) {
      if (present.contains(row.key)) continue;
      present.add(row.key);
      final fromFile =
          row.wallet.isNotEmpty && row.wallet != excelWalletFallback;
      final wallet = fromFile ? row.wallet : (account?.wallet ?? row.wallet);
      final subId = fromFile ? null : account?.subId;
      final hasWallet = fromFile || account != null;
      batch.insert(
        'tx',
        {
          'k': row.key,
          'ts': row.ts,
          'wallet': wallet,
          'dir': dirString(row.dir),
          'type': row.type.name,
          'amount': row.amount,
          'fee': row.fee,
          'amount_minor': exactMinor(row.amount),
          'fee_minor': exactMinor(row.fee),
          'party': row.party,
          'balance': null,
          'sub_id': subId,
          'source': 'excel',
          'date_inferred': row.dateInferred ? 1 : 0,
          // No wallet chosen: keep the row but never guess one.
          'review': (row.review || row.dateInferred || !hasWallet) ? 1 : 0,
          'manual': 1,
          'ai': 0,
          'ai_note': '',
          'note': row.note,
          'body': row.body,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      added++;
    }
    await batch.commit(noResult: true);
    return added;
  }

  /// Wallet model access (owners, devices, SIMs, providers, wallet accounts).
  static Future<WalletStore> wallets() async => WalletStore(await _database);

  /// Audited corrections, reversals and manual entries.
  static Future<LedgerService> ledger() async => LedgerService(await _database);

  /// Private, persistent app storage (not gallery/cache) for evidence files.
  static Future<String> dbPath() async =>
      join(await getDatabasesPath(), 'wallet.db');

  static Future<Directory> storageRoot() => getApplicationSupportDirectory();

  static Future<EvidenceService> evidence() async =>
      EvidenceService(await _database, await storageRoot());

  static Future<ConfirmationService> confirmations() async =>
      ConfirmationService(await _database);

  static Future<MatchService> matches() async => MatchService(await _database);

  static Future<SummaryService> summary() async =>
      SummaryService(await _database);

  static Future<Database> database() => _database;

  static Future<AiSuggestionService> aiSuggestions() async =>
      AiSuggestionService(await _database);

  static Future<ConfirmedTotals> totals() async =>
      ConfirmedTotals(await _database);

  /// Pending unknown-sender candidates for the owner to look at.
  static Future<List<Map<String, Object?>>> candidates() async =>
      (await _database).query('sms_candidates',
          where: "status = 'pending'", orderBy: 'ts DESC');

  static Future<List<Account>> accounts() async {
    final db = await _database;
    final rows = await db.query('accounts', orderBy: 'id');
    return rows
        .map((r) => Account(
              id: r['id'] as int,
              name: (r['name'] as String?) ?? '',
              wallet: (r['wallet'] as String?) ?? '',
              number: (r['number'] as String?) ?? '',
              subId: r['sub_id'] as int?,
              slot: r['slot'] as int?,
            ))
        .toList();
  }

  static Future<void> saveAccount(Account a) async {
    final db = await _database;
    final values = {
      'name': a.name,
      'wallet': a.wallet,
      'number': a.number,
      'sub_id': a.subId,
      'slot': a.slot,
    };
    if (a.id == null) {
      await db.insert('accounts', values);
    } else {
      await db.update('accounts', values, where: 'id = ?', whereArgs: [a.id]);
    }
    await syncLegacyAccounts(db);
    await autoLinkTransactions(db);
  }

  static Future<void> deleteAccount(int id) async {
    final db = await _database;
    await db.delete('accounts', where: 'id = ?', whereArgs: [id]);
    await db.delete('openings', where: 'account_id = ?', whereArgs: [id]);
    await syncLegacyAccounts(db); // archives the mirrored wallet; history stays
  }

  /// Opening balances keyed by "<accountId>|<yyyy-mm-dd>".
  static Future<Map<String, double>> openings() async {
    final db = await _database;
    final rows = await db.query('openings');
    return {
      for (final r in rows)
        '${r['account_id']}|${r['day']}':
            ((r['amount'] as num?) ?? 0).toDouble(),
    };
  }

  static Future<void> setOpening(
      int accountId, String day, double amount) async {
    final db = await _database;
    await db.insert(
      'openings',
      {'account_id': accountId, 'day': day, 'amount': amount},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, String>> allSettings() async {
    final db = await _database;
    final rows = await db.query('settings');
    return {
      for (final r in rows) (r['key'] as String): (r['value'] as String?) ?? '',
    };
  }

  /// The Gemini key lives in the platform keystore, not in the database (so it
  /// is not in backups or file copies). Falls back to the settings table only
  /// where no keystore exists (tests); an older key there is moved on first read.
  static Future<String> apiKey() async {
    const store = FlutterSecureStorage();
    try {
      final v = await store.read(key: settingsApiKey);
      if (v != null && v.isNotEmpty) return v;
      final old = await setting(settingsApiKey);
      if (old != null && old.isNotEmpty) {
        await store.write(key: settingsApiKey, value: old);
        // Only drop the old copy once the keystore really returns the same key.
        if (await store.read(key: settingsApiKey) == old) {
          await deleteSetting(settingsApiKey);
        }
        return old;
      }
      return '';
    } catch (_) {
      return await setting(settingsApiKey) ?? '';
    }
  }

  static Future<void> setApiKey(String key) async {
    const store = FlutterSecureStorage();
    try {
      await store.write(key: settingsApiKey, value: key);
      if (await store.read(key: settingsApiKey) == key) {
        await deleteSetting(settingsApiKey);
      } else {
        throw StateError('keystore did not keep the key');
      }
    } catch (_) {
      await setSetting(settingsApiKey, key);
    }
  }

  static Future<String?> setting(String key) async {
    final db = await _database;
    final rows = await db.query('settings',
        columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  static Future<void> setSetting(String key, String value) async {
    final db = await _database;
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> deleteSetting(String key) async {
    final db = await _database;
    await db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }
}
