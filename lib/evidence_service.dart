/// Evidence (proof) attached to transactions, and the confirmation status.
///
/// Evidence is a record that something was shown to the owner; it is never the
/// financial truth. Attaching it never changes the confirmation state or any
/// total: only [ConfirmationService] does that, on an explicit owner action.
/// Files are copied byte-for-byte into private storage and never replaced or
/// deleted; "removing" only hides them from the active list.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'confirmation_rules.dart';
import 'ledger_service.dart';
import 'money_engine.dart';
import 'schema.dart';

class EvidenceKind {
  static const sms = 'sms';
  static const walletApp = 'wallet_app';
  static const instantMessage = 'instant_message';
  static const receipt = 'receipt';
  static const other = 'other';
  static const all = {sms, walletApp, instantMessage, receipt, other};
}

/// Where the proof came from (separate from who uploaded it).
class EvidenceOrigin {
  static const providerSms = 'provider_sms';
  static const walletApp = 'wallet_app';
  static const senderWalletApp = 'sender_wallet_app';
  static const instantMessage = 'instant_message';
  static const receipt = 'receipt';
  static const other = 'other';
  static const all = {
    providerSms,
    walletApp,
    senderWalletApp,
    instantMessage,
    receipt,
    other
  };
}

class UploadedBy {
  static const owner = 'owner';
  static const sender = 'sender';
  static const other = 'other';
  static const all = {owner, sender, other};
}

String _mimeFor(String name) => switch (p.extension(name).toLowerCase()) {
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.heic' => 'image/heic',
      '.gif' => 'image/gif',
      '.pdf' => 'application/pdf',
      '.txt' => 'text/plain',
      _ => 'application/octet-stream',
    };

class EvidenceService {
  final Database db;

  /// Persistent private directory; evidence lives in `<root>/evidence`.
  final Directory root;
  EvidenceService(this.db, this.root);

  Directory get evidenceDir => Directory(p.join(root.path, 'evidence'));

  Future<void> _requireTx(DatabaseExecutor t, int txId) async {
    if ((await t.query('tx',
            columns: ['id'], where: 'id = ?', whereArgs: [txId]))
        .isEmpty) {
      throw LedgerException('transaction $txId not found');
    }
  }

  void _checkLabels(String kind, String origin, String uploadedBy) {
    if (!EvidenceKind.all.contains(kind))
      throw LedgerException('unknown evidence type $kind');
    if (!EvidenceOrigin.all.contains(origin))
      throw LedgerException('unknown evidence origin $origin');
    if (!UploadedBy.all.contains(uploadedBy))
      throw LedgerException('unknown uploader $uploadedBy');
  }

  /// Copies [source] into private storage and links it to [txId]. Returns the
  /// evidence id. The same file (by content) cannot be attached twice to one
  /// transaction.
  Future<int> attachFile(
    int txId,
    File source, {
    String kind = EvidenceKind.other,
    String origin = EvidenceOrigin.other,
    String uploadedBy = UploadedBy.owner,
    String note = '',
    String? reference,
  }) async {
    _checkLabels(kind, origin, uploadedBy);
    await _requireTx(db, txId);
    if (!await source.exists()) throw const LedgerException('file not found');
    final bytes = await source.readAsBytes();
    if (bytes.isEmpty) throw const LedgerException('file is empty');
    final hash = sha256.convert(bytes).toString();
    final dup = await db.query('evidence',
        columns: ['id'],
        where: 'tx_id = ? AND sha256 = ? AND removed_at IS NULL',
        whereArgs: [txId, hash]);
    if (dup.isNotEmpty)
      throw const LedgerException('this file is already attached');

    final name = p.basename(source.path);
    final rel = p.join('evidence', '$txId', '${hash.substring(0, 16)}_$name');
    final dest = File(p.join(root.path, rel));
    await dest.parent.create(recursive: true);
    if (!await dest.exists()) await dest.writeAsBytes(bytes, flush: true);
    return db.transaction((t) async {
      final id = await t.insert('evidence', {
        'tx_id': txId,
        'kind': kind,
        'origin': origin,
        'uploaded_by': uploadedBy,
        'file_path': rel,
        'file_name': name,
        'mime': _mimeFor(name),
        'size': bytes.length,
        'sha256': hash,
        'reference': reference,
        'note': note,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      await writeAudit(t,
          txId: txId,
          event: 'evidence_added',
          field: kind,
          newValue: '$id:$origin:$uploadedBy:$hash',
          source: AuditSource.manual);
      return id;
    });
  }

  /// Stores the original wallet SMS as evidence for [txId].
  Future<int> attachSms(
    int txId, {
    required String sender,
    required String body,
    required int ts,
    int? subId,
    String? reference,
    DatabaseExecutor? exec,
  }) async {
    final t = exec ?? db;
    await _requireTx(t, txId);
    final id = await t.insert('evidence', {
      'tx_id': txId,
      'kind': EvidenceKind.sms,
      'origin': EvidenceOrigin.providerSms,
      'uploaded_by': UploadedBy.owner,
      'sms_sender': sender,
      'sms_body': body,
      'sms_ts': ts,
      'sms_sub_id': subId,
      'reference': reference,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    await writeAudit(t,
        txId: txId,
        event: 'evidence_added',
        field: EvidenceKind.sms,
        newValue: '$id:${EvidenceOrigin.providerSms}',
        source: AuditSource.manual);
    return id;
  }

  Future<List<Map<String, Object?>>> list(int txId,
          {bool includeRemoved = false}) =>
      db.query('evidence',
          where:
              includeRemoved ? 'tx_id = ?' : 'tx_id = ? AND removed_at IS NULL',
          whereArgs: [txId],
          orderBy: 'id');

  Future<int> activeCount(int txId) async =>
      Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM evidence WHERE tx_id = ? AND removed_at IS NULL',
          [txId])) ??
      0;

  File? fileOf(Map<String, Object?> evidence) {
    final rel = evidence['file_path'] as String?;
    return rel == null ? null : File(p.join(root.path, rel));
  }

  /// Hides the item from the active list. The row and the file are kept and
  /// the removal is audited with its reason.
  Future<void> remove(int evidenceId, {required String reason}) async {
    if (reason.trim().isEmpty)
      throw const LedgerException('a reason is required');
    await db.transaction((t) async {
      final r =
          await t.query('evidence', where: 'id = ?', whereArgs: [evidenceId]);
      if (r.isEmpty) throw LedgerException('evidence $evidenceId not found');
      if (r.first['removed_at'] != null) return;
      await t.update(
          'evidence',
          {
            'removed_at': DateTime.now().millisecondsSinceEpoch,
            'removed_reason': reason
          },
          where: 'id = ?',
          whereArgs: [evidenceId]);
      await writeAudit(t,
          txId: r.first['tx_id']! as int,
          event: 'evidence_removed',
          field: 'evidence',
          oldValue: evidenceId,
          source: AuditSource.manual,
          reason: reason);
    });
  }

  /// Re-hashes the stored file; false when it is missing or altered.
  Future<bool> verify(int evidenceId) async {
    final r =
        await db.query('evidence', where: 'id = ?', whereArgs: [evidenceId]);
    if (r.isEmpty) throw LedgerException('evidence $evidenceId not found');
    final f = fileOf(r.first);
    if (f == null) return true; // SMS evidence has no file
    if (!await f.exists()) return false;
    return sha256.convert(await f.readAsBytes()).toString() ==
        r.first['sha256'];
  }
}

/// Moves a transaction between confirmation states. Evidence never does it.
class ConfirmationService {
  final Database db;
  const ConfirmationService(this.db);

  /// Owner decision with a reason. Reversed transactions are final, and the
  /// two confirmed states are reached through [confirmByProvider] /
  /// [confirmByBalance] so they always carry what justified them.
  Future<void> setStatus(int txId, String status, {String reason = ''}) async {
    if (!Confirmation.all.contains(status))
      throw LedgerException('unknown status $status');
    if (status == Confirmation.reversed) {
      throw const LedgerException('use reverse() to reverse a transaction');
    }
    if (Confirmation.counted.contains(status)) {
      throw const LedgerException(
          'confirm through the provider message or a wallet balance check');
    }
    await _set(txId, status, reason, AuditSource.manual, null);
  }

  /// The owner has seen a reliable provider confirmation for this record.
  Future<void> confirmByProvider(int txId, {required String reason}) async {
    if (reason.trim().isEmpty)
      throw const LedgerException('say what was checked');
    await _set(txId, Confirmation.providerConfirmed, reason, AuditSource.manual,
        ConfirmMethod.providerCheck);
  }

  /// The owner read the real wallet balance after this transaction. It is
  /// compared with opening balance + confirmed history + this transaction;
  /// equal -> balance_confirmed, different -> mismatched (difference recorded).
  /// Returns the difference in piasters (0 when it agrees).
  Future<int> confirmByBalance(int txId, int observedBalanceMinor) async {
    final rows = await db.query('tx', where: 'id = ?', whereArgs: [txId]);
    if (rows.isEmpty) throw LedgerException('transaction $txId not found');
    final r = rows.first;
    final wid = r['wallet_account_id'] as int?;
    if (wid == null)
      throw const LedgerException('link the transaction to a wallet first');
    final sum = await ConfirmedTotals(db).forWallet(wid, include: txId);
    if (sum.confirmedBalanceMinor == null) {
      throw const LedgerException('the wallet has no opening balance');
    }
    final diff = observedBalanceMinor - sum.confirmedBalanceMinor!;
    await _set(
        txId,
        diff == 0 ? Confirmation.balanceConfirmed : Confirmation.mismatched,
        'observed ${observedBalanceMinor}, expected ${sum.confirmedBalanceMinor}, difference $diff',
        AuditSource.reconciliation,
        diff == 0 ? ConfirmMethod.balanceCheck : null);
    return diff;
  }

  Future<void> _set(int txId, String status, String reason, String source,
          String? method) =>
      db.transaction((t) async {
        final rows = await t.query('tx', where: 'id = ?', whereArgs: [txId]);
        if (rows.isEmpty) throw LedgerException('transaction $txId not found');
        final old =
            rows.first['confirmation'] as String? ?? Confirmation.awaiting;
        final isReversed = old == Confirmation.reversed ||
            (await t.query('tx',
                    columns: ['id'],
                    where: 'reverses_tx_id = ?',
                    whereArgs: [txId]))
                .isNotEmpty;
        if (isReversed) {
          throw const LedgerException(
              'a reversed transaction cannot change status');
        }
        if (old == status) return;
        await t.update(
            'tx',
            {
              'confirmation': status,
              'confirmation_method':
                  Confirmation.counted.contains(status) ? method : null,
              'confirmed_at': Confirmation.counted.contains(status)
                  ? DateTime.now().millisecondsSinceEpoch
                  : null,
            },
            where: 'id = ?',
            whereArgs: [txId]);
        final g =
            await startAuditGroup(t, 'confirmation', txId, source, reason);
        await writeAudit(t,
            txId: txId,
            event: 'confirmation',
            field: 'confirmation',
            oldValue: old,
            newValue: status,
            source: source,
            reason: reason,
            groupId: g);
        // Counted money changed, so later balance checks must be redone.
        await t.insert('revalidation_marks', {
          'tx_id': txId,
          'wallet_account_id': rows.first['wallet_account_id'],
          'caused_by': g,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      });
}

class WalletTotals {
  final int? confirmedBalanceMinor;

  /// Per-wallet movement of confirmed rows, internal transfers included.
  final int confirmedInMinor, confirmedOutMinor;

  /// The part of in/out that is a move between the owner's own wallets.
  final int internalInMinor, internalOutMinor;

  /// Fees the owner paid on confirmed rows, and fees whose payer is unknown.
  final int feesMinor, uncertainFeeMinor;
  final int pendingInMinor, pendingOutMinor, pendingCount;
  final int? lastTs;
  const WalletTotals(
      {this.confirmedBalanceMinor,
      this.confirmedInMinor = 0,
      this.confirmedOutMinor = 0,
      this.internalInMinor = 0,
      this.internalOutMinor = 0,
      this.feesMinor = 0,
      this.uncertainFeeMinor = 0,
      this.pendingInMinor = 0,
      this.pendingOutMinor = 0,
      this.pendingCount = 0,
      this.lastTs});
}

/// Exact confirmed vs. pending totals. Only provider/balance-confirmed,
/// active rows count; everything else is shown separately and never mixed in.
/// In/out are base amounts, fees are reported on their own, and a fee only
/// moves the balance when the owner pays it.
class ConfirmedTotals {
  final Database db;
  const ConfirmedTotals(this.db);

  /// [include] counts one extra transaction as confirmed (used to check a
  /// balance reading before that transaction is marked confirmed).
  Future<WalletTotals> forWallet(int walletId, {int? include}) async {
    final w = await db
        .query('wallet_accounts', where: 'id = ?', whereArgs: [walletId]);
    if (w.isEmpty) throw LedgerException('unknown wallet $walletId');
    final opening = w.first['opening_minor'] as int?;
    final from = DateTime.tryParse((w.first['opening_date'] as String?) ?? '')
        ?.millisecondsSinceEpoch;
    final rows = await db
        .query('tx', where: 'wallet_account_id = ?', whereArgs: [walletId]);
    final reversed = {
      for (final r in await db.query('tx',
          columns: ['reverses_tx_id'], where: 'reverses_tx_id IS NOT NULL'))
        r['reverses_tx_id'] as int
    };
    var inM = 0, outM = 0, intIn = 0, intOut = 0, fees = 0, uncertain = 0;
    var pIn = 0, pOut = 0, pCount = 0, impactSum = 0;
    int? last;
    for (final r in rows) {
      if (from != null && (r['ts'] as int) < from) continue;
      if ((r['disposition'] ?? 'active') != 'active' || r['review'] == 1)
        continue;
      if (reversed.contains(r['id'])) continue;
      final amount = r['amount_minor'] as int?;
      final fee = r['fee_minor'] as int? ?? 0;
      final dir = r['dir'] as String?;
      if (amount == null || (dir != 'in' && dir != 'out')) continue;
      final owner = (r['fee_owner'] as String?) ?? FeeOwner.owner;
      final impact = walletImpactMinor(dir!, amount, fee, feeOwner: owner)!;
      final status = (r['confirmation'] as String?) ?? Confirmation.awaiting;
      final counts =
          Confirmation.counted.contains(status) || r['id'] == include;
      if (last == null || (r['ts'] as int) > last) last = r['ts'] as int;
      if (counts) {
        final internal = r['transfer_peer_id'] != null;
        impactSum += impact;
        if (dir == 'in') {
          inM += amount;
          if (internal) intIn += amount;
        } else {
          outM += amount;
          if (internal) intOut += amount;
        }
        if (owner == FeeOwner.owner) fees += fee;
        if (owner == FeeOwner.unknown) uncertain += fee;
      } else if (status == Confirmation.awaiting ||
          status == Confirmation.mismatched ||
          status == Confirmation.disputed) {
        pCount++;
        if (dir == 'in') {
          pIn += impact;
        } else {
          pOut += -impact;
        }
      }
    }
    return WalletTotals(
        confirmedBalanceMinor: opening == null ? null : opening + impactSum,
        confirmedInMinor: inM,
        confirmedOutMinor: outM,
        internalInMinor: intIn,
        internalOutMinor: intOut,
        feesMinor: fees,
        uncertainFeeMinor: uncertain,
        pendingInMinor: pIn,
        pendingOutMinor: pOut,
        pendingCount: pCount,
        lastTs: last);
  }
}
