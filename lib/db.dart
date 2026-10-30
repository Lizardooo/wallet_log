import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import 'parser.dart';

class Tx {
  final int ts;
  final String wallet;
  final Dir dir;
  final double amount;
  final String? party;
  final double? balance;

  Tx(this.ts, this.wallet, this.dir, this.amount, this.party, this.balance);

  bool get isIn => dir == Dir.inFlow;
}

class TxDb {
  static Database? _db;

  static Future<Database> get _database async {
    return _db ??= await openDatabase(
      join(await getDatabasesPath(), 'wallet.db'),
      version: 1,
      onCreate: (d, v) => d.execute(
        'CREATE TABLE tx('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'k TEXT UNIQUE, ts INTEGER, wallet TEXT, dir TEXT, '
        'amount REAL, party TEXT, balance REAL, body TEXT)',
      ),
    );
  }

  /// Parses and stores one SMS. Non-transaction messages and duplicates are
  /// ignored, so it is safe to rescan the whole inbox repeatedly.
  static Future<void> addSms(String sender, String body, int ts) async {
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
        'body': body,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<List<Tx>> all({String? wallet}) async {
    final db = await _database;
    final rows = await db.query(
      'tx',
      where: wallet == null ? null : 'wallet = ?',
      whereArgs: wallet == null ? null : [wallet],
      orderBy: 'ts DESC',
    );
    return rows
        .map((r) => Tx(
              r['ts'] as int,
              r['wallet'] as String,
              r['dir'] == 'in' ? Dir.inFlow : Dir.outFlow,
              (r['amount'] as num).toDouble(),
              r['party'] as String?,
              (r['balance'] as num?)?.toDouble(),
            ))
        .toList();
  }
}
