/// Audited corrections, reversals and manual entries for transactions.
///
/// The `tx` row always holds the currently accepted values. Originals are never
/// copied or lost: every change appends events to `audit_events` (old and new
/// value, source, reason, time) and the first event for a field holds its
/// original value. The SMS / sheet text (`body`) is never editable. Money is
/// written as integer piasters; the legacy REAL column is only refreshed from
/// the piaster value (`minor / 100`) so the existing screens stay consistent.
library;

import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'money_engine.dart';
import 'parser.dart';
import 'schema.dart';

class LedgerException implements Exception {
  final String message;
  const LedgerException(this.message);
  @override
  String toString() => message;
}

class AlreadyReversedException extends LedgerException {
  const AlreadyReversedException(super.message);
}

/// Where a change came from.
class AuditSource {
  static const manual = 'manual';
  static const smsParse = 'sms_parse';
  static const excelImport = 'excel_import';
  static const aiAccept = 'ai_accept';
  static const reconciliation = 'reconciliation';
  static const reversal = 'reversal';
  static const all = {
    manual,
    smsParse,
    excelImport,
    aiAccept,
    reconciliation,
    reversal
  };
}

enum CorrectableField {
  amount('amount_minor'),
  fee('fee_minor'),
  dir('dir'),
  type('type'),
  walletAccount('wallet_account_id'),
  ts('ts'),
  balanceAfter('balance_minor'),
  balanceBefore('balance_before_minor'),
  feeOwner('fee_owner'),
  note('note');

  final String column;
  const CorrectableField(this.column);

  /// Whether a change can alter the running balance of a wallet.
  bool get affectsBalance => this != type && this != note;
}

/// Appends one audit group and returns its id.
Future<int> startAuditGroup(DatabaseExecutor t, String kind, int txId,
        String source, String reason) =>
    t.insert('audit_groups', {
      'kind': kind,
      'tx_id': txId,
      'source': source,
      'reason': reason,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });

Future<void> writeAudit(DatabaseExecutor t,
    {required int txId,
    required String event,
    String? field,
    Object? oldValue,
    Object? newValue,
    required String source,
    String reason = '',
    int? groupId}) async {
  if (!AuditSource.all.contains(source)) {
    throw LedgerException('unknown audit source $source');
  }
  await t.insert('audit_events', {
    'tx_id': txId,
    'event': event,
    'field': field,
    'old_value': oldValue?.toString(),
    'new_value': newValue?.toString(),
    'source': source,
    'reason': reason,
    'ts': DateTime.now().millisecondsSinceEpoch,
    'related_id': groupId,
  });
}

class BalanceResult {
  /// null when no opening balance exists: it is never invented.
  final int? balanceMinor;
  final int counted;

  /// Rows left out because they are pending review, excluded, directionless or
  /// lack an exact piaster amount.
  final int skipped;
  const BalanceResult(this.balanceMinor, this.counted, this.skipped);
}

class ReversalInfo {
  final int originalId, reversalId, originalImpactMinor, reversalImpactMinor;
  final String reason;
  const ReversalInfo(this.originalId, this.reversalId, this.originalImpactMinor,
      this.reversalImpactMinor, this.reason);
  int get netMinor => originalImpactMinor + reversalImpactMinor;
}

class LedgerService {
  final Database db;
  const LedgerService(this.db);

  static final _rng = Random();

  // ---- reading -----------------------------------------------------------

  Future<List<Map<String, Object?>>> history(int txId) =>
      db.query('audit_events',
          where: 'tx_id = ?', whereArgs: [txId], orderBy: 'id');

  /// Original value of [field]: the old value of its first change, or null if
  /// the field was never changed (then the current value is the original).
  Future<String?> originalValue(int txId, CorrectableField field) async {
    final r = await db.query('audit_events',
        columns: ['old_value'],
        where: "tx_id = ? AND field = ? AND event = 'correct'",
        whereArgs: [txId, field.column],
        orderBy: 'id',
        limit: 1);
    return r.isEmpty ? null : r.first['old_value'] as String?;
  }

  Future<bool> needsRevalidation(int txId) async =>
      (await db.query('revalidation_marks',
              where: 'tx_id = ? AND cleared_at IS NULL',
              whereArgs: [txId],
              limit: 1))
          .isNotEmpty;

  Future<List<int>> openRevalidation() async => [
        for (final r in await db.rawQuery(
            'SELECT DISTINCT tx_id FROM revalidation_marks WHERE cleared_at IS NULL ORDER BY tx_id'))
          r['tx_id']! as int
      ];

  /// Called once the owner has re-checked these transactions.
  Future<void> clearRevalidation(Iterable<int> txIds) async {
    for (final id in txIds) {
      await db.update('revalidation_marks',
          {'cleared_at': DateTime.now().millisecondsSinceEpoch},
          where: 'tx_id = ? AND cleared_at IS NULL', whereArgs: [id]);
    }
  }

  /// Opening balance plus the exact impact of every usable transaction linked
  /// to [walletId]. The stored confirmed balance is never touched.
  Future<BalanceResult> calculatedBalance(int walletId) async {
    final w = await db
        .query('wallet_accounts', where: 'id = ?', whereArgs: [walletId]);
    if (w.isEmpty) throw LedgerException('unknown wallet $walletId');
    final opening = w.first['opening_minor'] as int?;
    final from = DateTime.tryParse((w.first['opening_date'] as String?) ?? '')
        ?.millisecondsSinceEpoch;
    final rows = await db
        .query('tx', where: 'wallet_account_id = ?', whereArgs: [walletId]);
    var sum = 0, counted = 0, skipped = 0;
    for (final r in rows) {
      if (from != null && (r['ts'] as int) < from) continue;
      final impact = walletImpactMinor((r['dir'] as String?) ?? '',
          r['amount_minor'] as int?, r['fee_minor'] as int?,
          feeOwner: (r['fee_owner'] as String?) ?? 'owner');
      if (impact == null ||
          r['review'] == 1 ||
          (r['disposition'] ?? 'active') != 'active') {
        skipped++;
        continue;
      }
      sum += impact;
      counted++;
    }
    return BalanceResult(
        opening == null ? null : opening + sum, counted, skipped);
  }

  // ---- corrections -------------------------------------------------------

  static String _legacyWalletName(Map<String, Object?> provider) {
    for (final e in legacyWalletProviderCodes.entries) {
      if (e.value == provider['code']) return e.key;
    }
    return provider['name']! as String;
  }

  /// Marks the transaction and every later one in the same wallet as needing
  /// re-validation. Nothing is recalculated into stored confirmed balances.
  Future<void> _markAffected(DatabaseExecutor t, Map<String, Object?> row,
      int fromTs, int groupId) async {
    final accountId = row['wallet_account_id'] as int?;
    final ids = await t.query('tx',
        columns: ['id'],
        where: accountId != null
            ? 'wallet_account_id = ? AND ts >= ?'
            : 'wallet_account_id IS NULL AND wallet = ? AND ts >= ?',
        whereArgs: [accountId ?? row['wallet'], fromTs]);
    for (final r in ids) {
      final id = r['id']! as int;
      final open = await t.query('revalidation_marks',
          where: 'tx_id = ? AND cleared_at IS NULL', whereArgs: [id], limit: 1);
      if (open.isNotEmpty) continue;
      await t.insert('revalidation_marks', {
        'tx_id': id,
        'wallet_account_id': accountId,
        'caused_by': groupId,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  void _validate(CorrectableField f, Object? v) {
    switch (f) {
      case CorrectableField.amount:
        if (v is! int || v <= 0)
          throw const LedgerException('amount must be positive piasters');
      case CorrectableField.fee:
        if (v is! int || v < 0)
          throw const LedgerException('fee must be non-negative piasters');
      case CorrectableField.dir:
        if (v is! String || !const {'in', 'out', 'unknown'}.contains(v)) {
          throw const LedgerException('direction must be in, out or unknown');
        }
      case CorrectableField.type:
        if (v is! String || !TxType.values.any((t) => t.name == v)) {
          throw const LedgerException('unknown category');
        }
      case CorrectableField.walletAccount:
        if (v != null && v is! int)
          throw const LedgerException('wallet id must be an integer');
      case CorrectableField.ts:
        if (v is! int || v <= 0) throw const LedgerException('invalid date');
      case CorrectableField.balanceAfter:
      case CorrectableField.balanceBefore:
        if (v != null && v is! int)
          throw const LedgerException('balance must be integer piasters');
      case CorrectableField.feeOwner:
        if (v is! String || !FeeOwner.all.contains(v)) {
          throw const LedgerException('unknown fee owner');
        }
      case CorrectableField.note:
        if (v is! String)
          throw const LedgerException('description must be text');
    }
  }

  /// Applies [changes] atomically. Each changed field appends an audit event
  /// with its previous and new value; unchanged fields are ignored. Returns the
  /// number of fields that actually changed. Any failure rolls everything back.
  Future<int> correct(
    int txId,
    Map<CorrectableField, Object?> changes, {
    String source = AuditSource.manual,
    String reason = '',
  }) =>
      db.transaction((t) async {
        final rows = await t.query('tx', where: 'id = ?', whereArgs: [txId]);
        if (rows.isEmpty) throw LedgerException('transaction $txId not found');
        final row = rows.first;
        if (row['reverses_tx_id'] != null) {
          throw const LedgerException('a reversal record cannot be edited');
        }
        final reversed = (await t.query('tx',
                columns: ['id'],
                where: 'reverses_tx_id = ?',
                whereArgs: [txId]))
            .isNotEmpty;
        if (reversed && changes.keys.any((f) => f != CorrectableField.note)) {
          throw const LedgerException(
              'a reversed transaction can only change its description');
        }
        for (final e in changes.entries) {
          _validate(e.key, e.value);
        }

        final updates = <String, Object?>{};
        final events = <(String, Object?, Object?)>[];
        var balanceRelevant = false;
        int? oldTs;
        int? oldAccount = row['wallet_account_id'] as int?;
        for (final e in changes.entries) {
          final f = e.key;
          final current = row[f.column];
          if (current == e.value) continue;
          var oldAudit = current;
          if (current == null &&
              (f == CorrectableField.amount ||
                  f == CorrectableField.fee ||
                  f == CorrectableField.balanceAfter)) {
            // Unconverted legacy value: keep its REAL text as the previous value.
            final legacy = row[switch (f) {
              CorrectableField.amount => 'amount',
              CorrectableField.fee => 'fee',
              _ => 'balance',
            }];
            if (legacy != null) oldAudit = 'legacy_real:$legacy';
          }
          events.add((f.column, oldAudit, e.value));
          updates[f.column] = e.value;
          if (f.affectsBalance) balanceRelevant = true;
          if (f == CorrectableField.ts) oldTs = row['ts'] as int?;
          switch (f) {
            case CorrectableField.amount:
              updates['amount'] = (e.value as int) / 100.0;
            case CorrectableField.fee:
              updates['fee'] = (e.value as int) / 100.0;
            case CorrectableField.balanceAfter:
              updates['balance'] =
                  e.value == null ? null : (e.value as int) / 100.0;
            case CorrectableField.walletAccount:
              if (e.value != null) {
                final p = await t.rawQuery(
                    'SELECT p.code, p.name FROM wallet_accounts w JOIN wallet_providers p '
                    'ON p.id = w.provider_id WHERE w.id = ?',
                    [e.value]);
                if (p.isEmpty)
                  throw LedgerException('unknown wallet ${e.value}');
                final name = _legacyWalletName(p.first);
                if (name != row['wallet']) {
                  events.add(('wallet', row['wallet'], name));
                  updates['wallet'] = name;
                }
              }
            default:
          }
        }
        if (events.isEmpty) return 0;

        final group =
            await startAuditGroup(t, 'correction', txId, source, reason);
        for (final ev in events) {
          await writeAudit(t,
              txId: txId,
              event: 'correct',
              field: ev.$1,
              oldValue: ev.$2,
              newValue: ev.$3,
              source: source,
              reason: reason,
              groupId: group);
        }
        updates['manual'] = 1; // the owner's value is never re-parsed over
        if (updates.containsKey('dir') || updates.containsKey('type')) {
          updates['review'] = 0;
        }
        await t.update('tx', updates, where: 'id = ?', whereArgs: [txId]);

        if (balanceRelevant) {
          final newRow =
              (await t.query('tx', where: 'id = ?', whereArgs: [txId])).first;
          final newTs = newRow['ts'] as int;
          final from = oldTs == null ? newTs : min(oldTs, newTs);
          await _markAffected(t, newRow, from, group);
          if (oldAccount != newRow['wallet_account_id']) {
            // The wallet it left is affected from the same point on.
            await _markAffected(
                t, {...newRow, 'wallet_account_id': oldAccount}, from, group);
          }
        }
        return events.length;
      });

  // ---- reversal ----------------------------------------------------------

  /// Fully reverses a transaction with a linked, opposite record. The original
  /// is not changed or deleted. Returns the reversal record's id.
  Future<int> reverse(int txId,
          {required String reason, String source = AuditSource.manual}) =>
      db.transaction((t) async {
        final rows = await t.query('tx', where: 'id = ?', whereArgs: [txId]);
        if (rows.isEmpty) throw LedgerException('transaction $txId not found');
        final o = rows.first;
        if (o['reverses_tx_id'] != null) {
          throw const LedgerException('a reversal record cannot be reversed');
        }
        if ((await t.query('tx',
                columns: ['id'],
                where: 'reverses_tx_id = ?',
                whereArgs: [txId]))
            .isNotEmpty) {
          throw const AlreadyReversedException(
              'transaction is already reversed');
        }
        final impact = walletImpactMinor((o['dir'] as String?) ?? '',
            o['amount_minor'] as int?, o['fee_minor'] as int?,
            feeOwner: (o['fee_owner'] as String?) ?? 'owner');
        if (impact == null) {
          throw const LedgerException(
              'cannot reverse: direction or exact amount is unknown');
        }
        if (impact == 0) throw const LedgerException('nothing to reverse');
        final now = DateTime.now().millisecondsSinceEpoch;
        final revId = await t.insert('tx', {
          'k': 'rev|$txId',
          'ts': now,
          'wallet': o['wallet'],
          'wallet_account_id': o['wallet_account_id'],
          'dir': impact > 0 ? 'out' : 'in',
          'type': o['type'],
          'amount': impact.abs() / 100.0,
          'amount_minor': impact.abs(),
          'fee': 0.0,
          'fee_minor': 0,
          'manual': 1,
          'review': 0,
          'source': AuditSource.reversal,
          'confirmation': Confirmation.reversed,
          'reverses_tx_id': txId,
          'note': reason,
          'body': 'reversal of transaction $txId',
        });
        final group =
            await startAuditGroup(t, 'reversal', txId, source, reason);
        await writeAudit(t,
            txId: txId,
            event: 'reversed',
            field: 'reversal_tx_id',
            newValue: revId,
            source: source,
            reason: reason,
            groupId: group);
        await writeAudit(t,
            txId: revId,
            event: 'create',
            field: 'reverses_tx_id',
            newValue: txId,
            source: AuditSource.reversal,
            reason: reason,
            groupId: group);
        final rev =
            (await t.query('tx', where: 'id = ?', whereArgs: [revId])).first;
        await _markAffected(t, rev, min(o['ts'] as int, now), group);
        return revId;
      });

  // ---- internal transfers -------------------------------------------------

  /// Owner says these two rows are the two sides of one move between their own
  /// wallets. Both keep their own wallet movement; they just stop counting as
  /// consolidated income / spending. Never done automatically.
  Future<void> linkInternalTransfer(int outTxId, int inTxId) =>
      db.transaction((t) async {
        Future<Map<String, Object?>> load(int id) async {
          final r = await t.query('tx', where: 'id = ?', whereArgs: [id]);
          if (r.isEmpty) throw LedgerException('transaction $id not found');
          return r.first;
        }

        final o = await load(outTxId), i = await load(inTxId);
        if (o['dir'] != 'out' || i['dir'] != 'in') {
          throw const LedgerException(
              'link one outgoing and one incoming transaction');
        }
        final ow = o['wallet_account_id'], iw = i['wallet_account_id'];
        if (ow == null || iw == null || ow == iw) {
          throw const LedgerException(
              'the two sides must be in two different linked wallets');
        }
        if (o['amount_minor'] == null ||
            o['amount_minor'] != i['amount_minor']) {
          throw const LedgerException('the amounts differ');
        }
        for (final r in [o, i]) {
          if (r['transfer_peer_id'] != null)
            throw const LedgerException('already linked');
          if (r['reverses_tx_id'] != null || r['disposition'] != 'active') {
            throw const LedgerException('record is reversed or excluded');
          }
          if ((await t.query('tx',
                  columns: ['id'],
                  where: 'reverses_tx_id = ?',
                  whereArgs: [r['id']]))
              .isNotEmpty) {
            throw const LedgerException('record is reversed or excluded');
          }
        }
        await t.update('tx', {'transfer_peer_id': inTxId},
            where: 'id = ?', whereArgs: [outTxId]);
        await t.update('tx', {'transfer_peer_id': outTxId},
            where: 'id = ?', whereArgs: [inTxId]);
        final g = await startAuditGroup(
            t, 'internal_transfer', outTxId, AuditSource.manual, 'linked');
        for (final (a, b) in [(outTxId, inTxId), (inTxId, outTxId)]) {
          await writeAudit(t,
              txId: a,
              event: 'transfer_linked',
              field: 'transfer_peer_id',
              newValue: b,
              source: AuditSource.manual,
              groupId: g);
        }
      });

  Future<void> unlinkInternalTransfer(int txId) => db.transaction((t) async {
        final r = await t.query('tx', where: 'id = ?', whereArgs: [txId]);
        if (r.isEmpty || r.first['transfer_peer_id'] == null) return;
        final peer = r.first['transfer_peer_id']! as int;
        await t.update('tx', {'transfer_peer_id': null},
            where: 'id IN (?, ?)', whereArgs: [txId, peer]);
        final g = await startAuditGroup(
            t, 'internal_transfer', txId, AuditSource.manual, 'unlinked');
        for (final (a, b) in [(txId, peer), (peer, txId)]) {
          await writeAudit(t,
              txId: a,
              event: 'transfer_unlinked',
              field: 'transfer_peer_id',
              oldValue: b,
              source: AuditSource.manual,
              groupId: g);
        }
      });

  /// Pairs worth showing to the owner: an unlinked outgoing and incoming row
  /// of equal amount in two different wallets within [window]. Only a list for
  /// the owner to confirm; many equal pairs stay ambiguous on purpose.
  Future<List<(int, int)>> internalTransferCandidates(
      {Duration window = const Duration(hours: 1)}) async {
    final rows = await db.query('tx',
        where:
            "disposition = 'active' AND transfer_peer_id IS NULL AND reverses_tx_id IS NULL "
            "AND wallet_account_id IS NOT NULL AND amount_minor IS NOT NULL AND dir IN ('in','out') "
            'AND id NOT IN (SELECT reverses_tx_id FROM tx WHERE reverses_tx_id IS NOT NULL)',
        orderBy: 'ts');
    final out = <(int, int)>[];
    for (final o in rows.where((r) => r['dir'] == 'out')) {
      for (final i in rows.where((r) => r['dir'] == 'in')) {
        if (o['wallet_account_id'] != i['wallet_account_id'] &&
            o['amount_minor'] == i['amount_minor'] &&
            ((o['ts'] as int) - (i['ts'] as int)).abs() <=
                window.inMilliseconds) {
          out.add((o['id']! as int, i['id']! as int));
        }
      }
    }
    return out;
  }

  // ---- reversal display ---------------------------------------------------

  /// Everything the screen needs to explain a reversal: the original, its
  /// linked reversal, each impact and the net (zero for a full reversal).
  /// Works from either side. Null when [txId] is not part of a reversal.
  Future<ReversalInfo?> reversalInfo(int txId) async {
    final r = await db.query('tx', where: 'id = ?', whereArgs: [txId]);
    if (r.isEmpty) return null;
    final origId = (r.first['reverses_tx_id'] as int?) ?? txId;
    final rev =
        await db.query('tx', where: 'reverses_tx_id = ?', whereArgs: [origId]);
    if (rev.isEmpty) return null;
    final o =
        (await db.query('tx', where: 'id = ?', whereArgs: [origId])).first;
    int imp(Map<String, Object?> x) =>
        walletImpactMinor((x['dir'] as String?) ?? '',
            x['amount_minor'] as int?, x['fee_minor'] as int?,
            feeOwner: (x['fee_owner'] as String?) ?? 'owner') ??
        0;
    return ReversalInfo(origId, rev.first['id']! as int, imp(o), imp(rev.first),
        rev.first['note'] as String? ?? '');
  }

  // ---- manual creation ---------------------------------------------------

  /// Creates a transaction typed in by the owner. [balanceBeforeMinor] and
  /// [balanceAfterMinor] are stored only as given; if both are given and do not
  /// agree with the amount, the record is kept but flagged for review.
  Future<int> createManual({
    required int walletAccountId,
    required int amountMinor,
    required String dir,
    required String type,
    int feeMinor = 0,
    required int ts,
    String description = '',
    String? counterparty,
    String? reference,
    String feeOwner = 'owner',
    int? balanceBeforeMinor,
    int? balanceAfterMinor,
    String reason = '',
  }) =>
      db.transaction((t) async {
        _validate(CorrectableField.amount, amountMinor);
        _validate(CorrectableField.fee, feeMinor);
        _validate(CorrectableField.type, type);
        _validate(CorrectableField.ts, ts);
        if (!FeeOwner.all.contains(feeOwner)) {
          throw const LedgerException('unknown fee owner');
        }
        if (dir != 'in' && dir != 'out') {
          throw const LedgerException('a manual transaction needs a direction');
        }
        final p = await t.rawQuery(
            'SELECT p.code, p.name, w.archived FROM wallet_accounts w JOIN wallet_providers p '
            'ON p.id = w.provider_id WHERE w.id = ?',
            [walletAccountId]);
        if (p.isEmpty) throw LedgerException('unknown wallet $walletAccountId');
        if (p.first['archived'] == 1) {
          throw const LedgerException('wallet is archived');
        }
        var review = 0;
        if (balanceBeforeMinor != null && balanceAfterMinor != null) {
          final impact = walletImpactMinor(dir, amountMinor, feeMinor,
              feeOwner: feeOwner)!;
          if (balanceBeforeMinor + impact != balanceAfterMinor) review = 1;
        }
        final id = await t.insert('tx', {
          'k':
              'manual|${DateTime.now().microsecondsSinceEpoch}|${_rng.nextInt(1 << 30)}',
          'ts': ts,
          'wallet': _legacyWalletName(p.first),
          'wallet_account_id': walletAccountId,
          'dir': dir,
          'type': type,
          'amount': amountMinor / 100.0,
          'amount_minor': amountMinor,
          'fee': feeMinor / 100.0,
          'fee_minor': feeMinor,
          'balance':
              balanceAfterMinor == null ? null : balanceAfterMinor / 100.0,
          'balance_minor': balanceAfterMinor,
          'balance_before_minor': balanceBeforeMinor,
          'manual': 1,
          'review': review,
          'source': 'manual',
          'party': counterparty,
          'reference':
              (reference?.trim().isEmpty ?? true) ? null : reference!.trim(),
          'fee_owner': feeOwner,
          'confirmation': Confirmation.awaiting,
          'note': description,
          'body': '',
        });
        final group =
            await startAuditGroup(t, 'create', id, AuditSource.manual, reason);
        await writeAudit(t,
            txId: id,
            event: 'create',
            newValue: jsonEncode({
              'wallet_account_id': walletAccountId,
              'amount_minor': amountMinor,
              'fee_minor': feeMinor,
              'dir': dir,
              'type': type,
              'ts': ts,
              'balance_before_minor': balanceBeforeMinor,
              'balance_minor': balanceAfterMinor,
              'description': description,
            }),
            source: AuditSource.manual,
            reason: reason,
            groupId: group);
        final row =
            (await t.query('tx', where: 'id = ?', whereArgs: [id])).first;
        await _markAffected(t, row, ts, group);
        return id;
      });
}
