/// Owners, devices, SIM lines, providers and wallet accounts.
///
/// These are separate entities: a wallet is identified by its own row, never by
/// the SIM or device it currently sits in, so moving a SIM changes only the
/// association history and leaves the wallet and its transactions alone.
library;

import 'package:sqflite/sqflite.dart';

class DuplicateWalletException implements Exception {
  final String message;
  const DuplicateWalletException(this.message);
  @override
  String toString() => message;
}

class WalletRow {
  final int id;
  final int providerId;
  final String providerCode;
  final String providerName;
  final String phone;
  final int? ownerId;
  final int? simId;
  final int?
      deviceId; // effective: the SIM's current device, else the stored one
  final String nickname;
  final int? openingMinor;
  final int? lastConfirmedMinor;
  final bool archived;

  const WalletRow({
    required this.id,
    required this.providerId,
    required this.providerCode,
    required this.providerName,
    required this.phone,
    this.ownerId,
    this.simId,
    this.deviceId,
    this.nickname = '',
    this.openingMinor,
    this.lastConfirmedMinor,
    this.archived = false,
  });
}

class WalletStore {
  final Database db;
  const WalletStore(this.db);

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<int> addOwner(String name, {String notes = ''}) =>
      db.insert('owners', {'name': name, 'notes': notes, 'created_at': _now()});

  Future<int> addDevice(String name, {String? identifier, String notes = ''}) =>
      db.insert('devices', {
        'name': name,
        'identifier': identifier,
        'notes': notes,
        'created_at': _now(),
      });

  /// Registers a SIM line, optionally already inside a device.
  Future<int> addSim({
    String? phone,
    String? carrier,
    int? slot,
    int? subId,
    int? deviceId,
  }) =>
      db.transaction((t) async {
        final id = await t.insert('sim_lines', {
          'phone': phone,
          'carrier': carrier,
          'slot': slot,
          'sub_id': subId,
          'device_id': deviceId,
          'created_at': _now(),
        });
        if (deviceId != null) {
          await t.insert('sim_device_history', {
            'sim_id': id,
            'device_id': deviceId,
            'slot': slot,
            'from_ts': _now(),
          });
        }
        return id;
      });

  /// Moves a SIM to another device (or to none), closing its open history row.
  /// Wallets and transactions are untouched.
  Future<void> moveSim(int simId, int? deviceId, {int? slot}) =>
      db.transaction((t) async {
        final now = _now();
        await t.update('sim_device_history', {'to_ts': now},
            where: 'sim_id = ? AND to_ts IS NULL', whereArgs: [simId]);
        await t.update('sim_lines', {'device_id': deviceId, 'slot': slot},
            where: 'id = ?', whereArgs: [simId]);
        if (deviceId != null) {
          await t.insert('sim_device_history', {
            'sim_id': simId,
            'device_id': deviceId,
            'slot': slot,
            'from_ts': now,
          });
        }
      });

  Future<List<Map<String, Object?>>> simHistory(int simId) =>
      db.query('sim_device_history',
          where: 'sim_id = ?', whereArgs: [simId], orderBy: 'from_ts, id');

  Future<int> providerId(String code) async {
    final r = await db.query('wallet_providers',
        columns: ['id'], where: 'code = ?', whereArgs: [code]);
    if (r.isEmpty) throw ArgumentError('unknown provider $code');
    return r.first['id']! as int;
  }

  Future<int> addProvider(String code, String name,
          {String category = 'other', String senderPatternsJson = '[]'}) =>
      db.insert('wallet_providers', {
        'code': code,
        'name': name,
        'category': category,
        'sender_patterns': senderPatternsJson,
      });

  /// Adds a wallet account. There is no per-device or per-owner cap; an active
  /// wallet with the same provider and number is rejected as a duplicate.
  Future<int> addWallet({
    required int providerId,
    String phone = '',
    int? ownerId,
    int? simId,
    int? deviceId,
    String nickname = '',
    int? openingMinor,
    String? openingDate,
    String notes = '',
  }) async {
    try {
      return await db.insert('wallet_accounts', {
        'provider_id': providerId,
        'phone': phone,
        'owner_id': ownerId,
        'sim_id': simId,
        'device_id': deviceId,
        'nickname': nickname,
        'opening_minor': openingMinor,
        'opening_date': openingDate,
        'notes': notes,
        'created_at': _now(),
      });
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        throw DuplicateWalletException(
            'an active wallet already exists for this provider and number');
      }
      rethrow;
    }
  }

  Future<void> confirmBalance(int walletId, int balanceMinor) => db.update(
      'wallet_accounts',
      {'last_confirmed_minor': balanceMinor, 'last_confirmed_ts': _now()},
      where: 'id = ?',
      whereArgs: [walletId]);

  /// The balance the wallet held on [date] (yyyy-mm-dd). Confirmed balances
  /// are this plus the exact impact of confirmed transactions from that day on.
  Future<void> setOpening(int walletId, int openingMinor, String date) =>
      db.update('wallet_accounts',
          {'opening_minor': openingMinor, 'opening_date': date},
          where: 'id = ?', whereArgs: [walletId]);

  Future<void> setWalletSim(int walletId, int? simId) =>
      db.update('wallet_accounts', {'sim_id': simId},
          where: 'id = ?', whereArgs: [walletId]);

  Future<void> setWalletDevice(int walletId, int? deviceId) =>
      db.update('wallet_accounts', {'device_id': deviceId},
          where: 'id = ?', whereArgs: [walletId]);

  /// Wallets with history are archived, never deleted (the tx foreign key
  /// refuses a delete while transactions point at the wallet).
  Future<void> archiveWallet(int id) =>
      db.update('wallet_accounts', {'archived': 1},
          where: 'id = ?', whereArgs: [id]);

  Future<void> restoreWallet(int id) async {
    try {
      await db.update('wallet_accounts', {'archived': 0},
          where: 'id = ?', whereArgs: [id]);
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) {
        throw const DuplicateWalletException(
            'another active wallet already uses this provider and number');
      }
      rethrow;
    }
  }

  Future<List<WalletRow>> wallets({
    int? providerId,
    int? ownerId,
    int? deviceId,
    bool includeArchived = false,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (!includeArchived) where.add('w.archived = 0');
    if (providerId != null) {
      where.add('w.provider_id = ?');
      args.add(providerId);
    }
    if (ownerId != null) {
      where.add('w.owner_id = ?');
      args.add(ownerId);
    }
    if (deviceId != null) {
      where.add('COALESCE(s.device_id, w.device_id) = ?');
      args.add(deviceId);
    }
    final rows = await db.rawQuery(
        'SELECT w.*, p.code AS pcode, p.name AS pname, '
        'COALESCE(s.device_id, w.device_id) AS eff_device '
        'FROM wallet_accounts w '
        'JOIN wallet_providers p ON p.id = w.provider_id '
        'LEFT JOIN sim_lines s ON s.id = w.sim_id '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
        'ORDER BY w.id',
        args);
    return rows
        .map((r) => WalletRow(
              id: r['id']! as int,
              providerId: r['provider_id']! as int,
              providerCode: r['pcode']! as String,
              providerName: r['pname']! as String,
              phone: (r['phone'] as String?) ?? '',
              ownerId: r['owner_id'] as int?,
              simId: r['sim_id'] as int?,
              deviceId: r['eff_device'] as int?,
              nickname: (r['nickname'] as String?) ?? '',
              openingMinor: r['opening_minor'] as int?,
              lastConfirmedMinor: r['last_confirmed_minor'] as int?,
              archived: (r['archived'] as int?) == 1,
            ))
        .toList();
  }

  /// Registration-rule reminders (warnings, never blocks): one wallet per
  /// mobile number and at most three wallets per person.
  Future<List<String>> eligibilityWarnings(
      {required String phone, int? ownerId}) async {
    final out = <String>[];
    if (phone.isNotEmpty) {
      final n = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM wallet_accounts WHERE phone = ? AND archived = 0',
          [phone]));
      if ((n ?? 0) >= 1) out.add('number_already_has_wallet');
    }
    if (ownerId != null) {
      final n = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM wallet_accounts WHERE owner_id = ? AND archived = 0',
          [ownerId]));
      if ((n ?? 0) >= 3) out.add('owner_exceeds_three_wallets');
    }
    return out;
  }

  /// Links transactions to a wallet. Only ever called on the owner's explicit
  /// choice; nothing links by guessed number or provider.
  Future<int> linkTransactions(Iterable<int> txIds, int walletId) async {
    final ids = txIds.toList();
    if (ids.isEmpty) return 0;
    return db.update('tx', {'wallet_account_id': walletId},
        where: 'id IN (${List.filled(ids.length, '?').join(',')})',
        whereArgs: ids);
  }
}
