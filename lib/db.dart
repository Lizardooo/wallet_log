import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

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
  final int? subId;

  const Account({
    this.id,
    required this.name,
    required this.wallet,
    this.number = '',
    this.subId,
  });
}

class RawSms {
  final String sender;
  final String body;
  final int ts;
  final int? subId;

  const RawSms(this.sender, this.body, this.ts, this.subId);
}

/// Stable across app and Dart versions (String.hashCode is not guaranteed to be).
int stableHash(String s) {
  var h = 0x811c9dc5;
  for (final u in s.codeUnits) {
    h ^= u;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

String smsKey(String body, int ts) => '${stableHash(body.trim())}|${ts ~/ 300000}';

class TxDb {
  static Database? _db;

  static Future<void> _create(Database d) async {
    await d.execute(
      'CREATE TABLE IF NOT EXISTS tx('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'k TEXT UNIQUE, ts INTEGER, wallet TEXT, dir TEXT, '
      "type TEXT NOT NULL DEFAULT 'other', "
      'amount REAL, fee REAL NOT NULL DEFAULT 0, party TEXT, balance REAL, '
      'sub_id INTEGER, review INTEGER NOT NULL DEFAULT 0, '
      'manual INTEGER NOT NULL DEFAULT 0, '
      "note TEXT NOT NULL DEFAULT '', body TEXT)",
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS accounts('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'name TEXT, wallet TEXT, number TEXT, sub_id INTEGER)',
    );
    await d.execute(
      'CREATE TABLE IF NOT EXISTS openings('
      'account_id INTEGER, day TEXT, amount REAL, '
      'PRIMARY KEY(account_id, day))',
    );
  }

  static Future<Database> get _database async {
    return _db ??= await openDatabase(
      join(await getDatabasesPath(), 'wallet.db'),
      version: 3,
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
      },
    );
  }

  /// Parses and stores messages. Non-transactions and duplicates are ignored, so
  /// rescanning the whole inbox is safe. Rows the owner has corrected by hand
  /// (manual = 1) and their notes are never overwritten; other rows are
  /// re-classified so improvements to the parser apply to old messages too.
  static Future<void> importSms(List<RawSms> msgs) async {
    final db = await _database;
    final batch = db.batch();
    for (final m in msgs) {
      final p = parseSms(m.sender, m.body);
      if (p == null) continue;
      final key = smsKey(m.body, m.ts);
      final dirStr = switch (p.dir) {
        Dir.inFlow => 'in',
        Dir.outFlow => 'out',
        Dir.unknown => 'unknown',
      };
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
        where: 'k = ? AND manual = 0',
        whereArgs: [key],
      );
    }
    await batch.commit(noResult: true);
  }

  static Future<List<Tx>> allTx() async {
    final db = await _database;
    final rows = await db.query('tx', orderBy: 'ts DESC, id DESC');
    return rows.map((r) {
      final dirStr = r['dir'] as String?;
      final typeStr = r['type'] as String?;
      return Tx(
        id: r['id'] as int,
        ts: r['ts'] as int,
        wallet: r['wallet'] as String,
        type: TxType.values.firstWhere(
          (t) => t.name == typeStr,
          orElse: () => TxType.other,
        ),
        dir: dirStr == 'in'
            ? Dir.inFlow
            : dirStr == 'out'
                ? Dir.outFlow
                : Dir.unknown,
        amount: (r['amount'] as num).toDouble(),
        fee: ((r['fee'] as num?) ?? 0).toDouble(),
        party: r['party'] as String?,
        balance: (r['balance'] as num?)?.toDouble(),
        subId: r['sub_id'] as int?,
        note: (r['note'] as String?) ?? '',
        body: (r['body'] as String?) ?? '',
        review: (r['review'] as int?) == 1,
        manual: (r['manual'] as int?) == 1,
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
        'dir': switch (dir) {
          Dir.inFlow => 'in',
          Dir.outFlow => 'out',
          Dir.unknown => 'unknown',
        },
        'review': 0,
        'manual': 1,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
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
        '${r['account_id']}|${r['day']}': (r['amount'] as num).toDouble(),
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
}
