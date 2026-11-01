import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'importer.dart';
import 'exclusions.dart';
import 'parser.dart';

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
bool smsBelongsToAccounts(
    String wallet, int? subId, List<Account> accounts) {
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

  static Future<void> _create(Database d) async {
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

  /// Adds a column when an older database does not have it yet.
  static Future<void> _addColumn(
      Database d, String table, String column, String decl) async {
    final cols = await d.rawQuery('PRAGMA table_info($table)');
    if (cols.any((c) => c['name'] == column)) return;
    await d.execute('ALTER TABLE $table ADD COLUMN $column $decl');
  }

  static Future<Database> get _database async {
    return _db ??= await openDatabase(
      join(await getDatabasesPath(), 'wallet.db'),
      version: 5,
      onCreate: (d, v) => _create(d),
      onUpgrade: (d, oldV, newV) async {
        if (oldV < 2) {
          // v1 had no notes or SIM info; messages are re-read from the inbox.
          await d.execute('DROP TABLE IF EXISTS tx');
        }
        await _create(d);
        if (oldV == 2) {
          await d.execute("ALTER TABLE tx ADD COLUMN type TEXT NOT NULL DEFAULT 'other'");
          await d.execute('ALTER TABLE tx ADD COLUMN fee REAL NOT NULL DEFAULT 0');
          await d.execute('ALTER TABLE tx ADD COLUMN review INTEGER NOT NULL DEFAULT 0');
          await d.execute('ALTER TABLE tx ADD COLUMN manual INTEGER NOT NULL DEFAULT 0');
          // Switch the duplicate-detection key to the stable hash; notes are kept.
          final rows = await d.query('tx', columns: ['id', 'ts', 'body']);
          for (final r in rows) {
            await d.update(
              'tx',
              {'k': smsKey((r['body'] as String?) ?? '', (r['ts'] as int?) ?? 0)},
              where: 'id = ?',
              whereArgs: [r['id']],
            );
          }
        }
        // v4: model classification and the setup wizard's SIM slot.
        await _addColumn(d, 'tx', 'ai', 'INTEGER NOT NULL DEFAULT 0');
        await _addColumn(d, 'tx', 'ai_note', "TEXT NOT NULL DEFAULT ''");
        await _addColumn(d, 'accounts', 'slot', 'INTEGER');
        await _addColumn(d, 'tx', 'disposition', "TEXT NOT NULL DEFAULT 'active'");
        await _addColumn(d, 'tx', 'rule_exempt', 'INTEGER NOT NULL DEFAULT 0');
      },
    );
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
    final chosen =
        accounts != null && accounts.isNotEmpty ? accounts : null;
    for (final m in msgs) {
      final p = parseSms(m.sender, m.body);
      final key = smsKey(m.body, m.ts);
      final wallet = p?.wallet ?? detectWallet(m.sender, m.body);
      final rule = wallet == null ? null
          : matchingExclusionRule(rules, wallet, m.body);
      if (p == null) {
        // Do not fabricate a transaction for a message the parser rejected.
        // Retain previously archived matches and deliberate owner decisions.
        if (rule == null) {
          batch.delete(
            'tx',
            where: "k = ? AND manual = 0 AND ai = 0 AND note = '' "
                "AND disposition = 'active' AND rule_exempt = 0",
            whereArgs: [key],
          );
        }
        continue;
      }
      if (chosen != null &&
          !smsBelongsToAccounts(wallet!, m.subId, chosen)) {
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
          'sub_id': m.subId,
          'review': (rule != null || p.review) ? 1 : 0,
          'body': m.body,
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
          'review': (rule != null || p.review) ? 1 : 0,
        },
        where: "k = ? AND manual = 0 AND ai = 0 AND disposition = 'active' AND rule_exempt = 0",
        whereArgs: [key],
      );
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Tx>> allTx() async {
    final db = await _database;
    final rows = await db.query('tx', orderBy: 'ts DESC, id DESC');
    final rules = await _rules(db);
    return rows.map((r) {
      final typeStr = r['type'] as String?;
      final stored = dispositionFromString(r['disposition'] as String?);
      final exempt = (r['rule_exempt'] as int?) == 1;
      final rule = stored == TxDisposition.active && !exempt
          ? matchingExclusionRule(rules, (r['wallet'] as String?) ?? '',
              (r['body'] as String?) ?? '') : null;
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
        disposition: rule == null ? stored : TxDisposition.ignored,
        exclusionRuleId: rule?.id,
        ruleExempt: exempt,
      );
    }).toList();
  }

  static Future<void> setNote(int id, String note) async {
    final db = await _database;
    await db.update('tx', {'note': note}, where: 'id = ?', whereArgs: [id]);
  }

  /// The owner's correction of type and direction; it is never overwritten.
  static Future<void> setClass(int id, TxType type, Dir dir) async {
    final db = await _database;
    await db.transaction((txn) async {
      final rows = await txn.query('tx', where: 'id = ?', whereArgs: [id]);
      final rules = await _rules(txn);
      if (rows.isEmpty || _excluded(rows.first, rules)) return;
      await txn.update('tx', {
        'type': type.name, 'dir': dirString(dir), 'review': 0, 'manual': 1,
      }, where: 'id = ?', whereArgs: [id]);
    });
  }

  /// AI responses already in flight cannot reactivate excluded messages.
  static Future<Set<int>> applyAiUpdates(List<AiUpdate> updates) async {
    if (updates.isEmpty) return {};
    final db = await _database;
    return db.transaction<Set<int>>((txn) async {
      final rules = await _rules(txn);
      final rows = await txn.query('tx');
      final allowed = {for (final r in rows)
        if (r['manual'] != 1 && !_excluded(r, rules)) r['id'] as int};
      final batch = txn.batch();
      for (final u in updates) {
        if (!allowed.contains(u.id)) continue;
        batch.update('tx', {
          'type': u.type.name, 'dir': dirString(u.dir),
          'review': u.confirm ? 0 : 1, 'ai': 1, 'ai_note': u.note,
        }, where: "id = ? AND manual = 0 AND disposition = 'active'",
          whereArgs: [u.id]);
      }
      await batch.commit(noResult: true);
      return {for (final u in updates) if (allowed.contains(u.id)) u.id};
    });
  }

  /// Re-read each batch, not only the initial queue, so a message excluded
  /// while another AI request runs is not sent in a later batch.
  static Future<List<Tx>> classificationBatch(Iterable<int> ids) async {
    final current = {for (final t in await allTx()) t.id: t};
    return [for (final id in ids)
      if (current[id] != null && !current[id]!.isExcluded) current[id]!];
  }

  static bool _excluded(Map<String, Object?> row, List<ExclusionRule> rules) =>
      dispositionFromString(row['disposition'] as String?) != TxDisposition.active ||
      (row['rule_exempt'] != 1 && matchingExclusionRule(rules,
        (row['wallet'] as String?) ?? '', (row['body'] as String?) ?? '') != null);

  static Future<List<ExclusionRule>> _rules(DatabaseExecutor db) async {
    final rows = await db.query('exclusion_rules', orderBy: 'id');
    return [for (final r in rows) ExclusionRule(
      id: r['id'] as int, wallet: r['wallet'] as String,
      match: r['match_mode'] == 'contains' ? ExclusionMatch.contains : ExclusionMatch.exact,
      text: r['pattern'] as String)];
  }

  static Future<List<ExclusionRule>> exclusionRules() async => _rules(await _database);

  /// Store a deliberate decision separately from parser/manual/AI provenance.
  /// A future rule applies retroactively and to new matching messages.
  static Future<void> exclude(int id, TxDisposition disposition, {
    ExclusionMatch? match, String? text,
  }) async {
    if (disposition == TxDisposition.active) {
      throw ArgumentError('Use restoreToReview to restore a message');
    }
    final pattern = normalizeExclusionText(text ?? '');
    if (match != null && (disposition != TxDisposition.ignored || pattern.isEmpty)) {
      throw ArgumentError('A non-empty rule requires the ignored state');
    }
    final db = await _database;
    await db.transaction((txn) async {
      final rows = await txn.query('tx', where: 'id = ?', whereArgs: [id]);
      if (rows.isEmpty) return;
      if (match != null) {
        final wallet = (rows.first['wallet'] as String?) ?? '';
        if (wallet.isEmpty) throw ArgumentError('A wallet is required');
        await txn.insert('exclusion_rules', {
          'wallet': wallet, 'match_mode': match.name, 'pattern': pattern,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await txn.update('tx', {'disposition': disposition.name, 'rule_exempt': 0},
        where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Restoring never silently counts an operation. This exact record is exempt
  /// from text rules until its owner explicitly excludes it again.
  static Future<void> restoreToReview(int id) async {
    final db = await _database;
    await db.update('tx', {
      'disposition': TxDisposition.active.name, 'review': 1, 'rule_exempt': 1,
    }, where: 'id = ?', whereArgs: [id]);
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
        if (selected.single.matches((row['wallet'] as String?) ?? '',
            (row['body'] as String?) ?? '')) {
          final another = matchingExclusionRule(rules.where((r) => r.id != id),
            (row['wallet'] as String?) ?? '', (row['body'] as String?) ?? '');
          batch.update('tx', {
            'review': 1,
            if (another == null) 'rule_exempt': 1,
          }, where: 'id = ?', whereArgs: [row['id']]);
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
      final wallet =
          fromFile ? row.wallet : (account?.wallet ?? row.wallet);
      final subId = fromFile ? null : account?.subId;
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
          'party': row.party,
          'balance': null,
          'sub_id': subId,
          'review': 0,
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
  }

  static Future<void> deleteAccount(int id) async {
    final db = await _database;
    await db.delete('accounts', where: 'id = ?', whereArgs: [id]);
    await db.delete('openings', where: 'account_id = ?', whereArgs: [id]);
  }

  /// Opening balances keyed by "<accountId>|<yyyy-mm-dd>".
  static Future<Map<String, double>> openings() async {
    final db = await _database;
    final rows = await db.query('openings');
    return {
      for (final r in rows)
        '${r['account_id']}|${r['day']}': ((r['amount'] as num?) ?? 0).toDouble(),
    };
  }

  static Future<void> setOpening(int accountId, String day, double amount) async {
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
