import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'parser.dart';

class Tx {
  final int id;
  final int ts;
  final String wallet;
  final Dir dir;
  final double amount;
  final String? party;
  final double? balance;
  final int? subId;
  final String note;

  const Tx({
    required this.id,
    required this.ts,
    required this.wallet,
    required this.dir,
    required this.amount,
    this.party,
    this.balance,
    this.subId,
    this.note = '',
  });

  bool get isIn => dir == Dir.inFlow;
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

class TxDb {
  static Database? _db;

  static Future<void> _create(Database d) async {
    await d.execute(
      'CREATE TABLE IF NOT EXISTS tx('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'k TEXT UNIQUE, ts INTEGER, wallet TEXT, dir TEXT, '
      'amount REAL, party TEXT, balance REAL, sub_id INTEGER, '
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
      version: 2,
      onCreate: (d, v) => _create(d),
      onUpgrade: (d, oldV, newV) async {
        if (oldV < 2) {
          // v1 had no notes or SIM info; messages are re-read from the inbox.
          await d.execute('DROP TABLE IF EXISTS tx');
        }
        await _create(d);
      },
    );
  }

  /// Parses and stores one SMS. Non-transaction messages and duplicates are
  /// ignored, so it is safe to rescan the whole inbox repeatedly. Notes are
  /// kept because existing rows are never overwritten.
  static Future<void> addSms(
      String sender, String body, int ts, int? subId) async {
    final p = parseSms(sender, body);
    if (p == null) return;
    final db = await _database;
    await db.insert(
      'tx',
      {
        'k': '${body.trim().hashCode}|${ts ~/ 300000}',
        'ts': ts,
        'wallet': p.wallet,
        'dir': p.dir == Dir.inFlow ? 'in' : 'out',
        'amount': p.amount,
        'party': p.party,
        'balance': p.balance,
        'sub_id': subId,
        'body': body,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<List<Tx>> allTx() async {
    final db = await _database;
    final rows = await db.query('tx', orderBy: 'ts DESC');
    return rows
        .map((r) => Tx(
              id: r['id'] as int,
              ts: r['ts'] as int,
              wallet: r['wallet'] as String,
              dir: r['dir'] == 'in' ? Dir.inFlow : Dir.outFlow,
              amount: (r['amount'] as num).toDouble(),
              party: r['party'] as String?,
              balance: (r['balance'] as num?)?.toDouble(),
              subId: r['sub_id'] as int?,
              note: (r['note'] as String?) ?? '',
            ))
        .toList();
  }

  static Future<void> setNote(int id, String note) async {
    final db = await _database;
    await db.update('tx', {'note': note}, where: 'id = ?', whereArgs: [id]);
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
