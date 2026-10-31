import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'importer.dart';
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
  });

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
      "note TEXT NOT NULL DEFAULT '', body TEXT)",
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
      version: 4,
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
      },
    );
  }

  /// Parses and stores messages. Non-transactions and duplicates are ignored, so
  /// rescanning the whole inbox is safe. Rows the owner has corrected by hand
  /// (manual = 1), rows the model classified (ai = 1) and their notes are never
  /// overwritten; other rows are re-classified so improvements to the parser
  /// apply to old messages too.
  static Future<void> importSms(List<RawSms> msgs) async {
    final db = await _database;
    final batch = db.batch();
    for (final m in msgs) {
      final p = parseSms(m.sender, m.body);
      if (p == null) continue;
      final key = smsKey(m.body, m.ts);
      final dirStr = dirString(p.dir);
      batch.insert(
        'tx',
        {
          'k': key,
          'ts': m.ts,
          'wallet': p.wallet,
          'dir': dirStr,
          'type': p.type.name,
          'amount': p.amount,
          'fee': p.fee,
          'party': p.party,
          'balance': p.balance,
          'sub_id': m.subId,
          'review': p.review ? 1 : 0,
          'body': m.body,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      batch.update(
        'tx',
        {
          'wallet': p.wallet,
          'dir': dirStr,
          'type': p.type.name,
          'amount': p.amount,
          'fee': p.fee,
          'party': p.party,
          'balance': p.balance,
          'review': p.review ? 1 : 0,
        },
        where: 'k = ? AND manual = 0 AND ai = 0',
        whereArgs: [key],
      );
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Tx>> allTx() async {
    final db = await _database;
    final rows = await db.query('tx', orderBy: 'ts DESC, id DESC');
    return rows.map((r) {
      final typeStr = r['type'] as String?;
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
    await db.update(
      'tx',
      {
        'type': type.name,
        'dir': dirString(dir),
        'review': 0,
        'manual': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Stores the model's classification. The owner's own corrections win, so
  /// rows with manual = 1 are left alone.
  static Future<void> applyAiUpdates(List<AiUpdate> updates) async {
    if (updates.isEmpty) return;
    final db = await _database;
    final batch = db.batch();
    for (final u in updates) {
      batch.update(
        'tx',
        {
          'type': u.type.name,
          'dir': dirString(u.dir),
          'review': u.confirm ? 0 : 1,
          'ai': 1,
          'ai_note': u.note,
        },
        where: 'id = ? AND manual = 0',
        whereArgs: [u.id],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Inserts rows read from an Excel report. Rows already present (same key) are
  /// skipped, so importing the same file twice changes nothing. Imported rows
  /// are marked manual so the SMS scan never re-classifies them.
  static Future<int> importRows(List<ImportRow> rows) async {
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
      batch.insert(
        'tx',
        {
          'k': row.key,
          'ts': row.ts,
          'wallet': row.wallet,
          'dir': dirString(row.dir),
          'type': row.type.name,
          'amount': row.amount,
          'fee': row.fee,
          'party': row.party,
          'balance': null,
          'sub_id': null,
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
