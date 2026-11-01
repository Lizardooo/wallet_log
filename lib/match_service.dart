/// Delayed-SMS matching, duplicate and gap detection.
///
/// Nothing here merges anything by itself: it only writes suggestions the owner
/// accepts or rejects. Amount alone is never enough; a provider reference
/// outranks everything else.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'evidence_service.dart';
import 'ledger_service.dart';
import 'schema.dart';

/// Pure scoring so it can be tested without a database.
class MatchScore {
  final int score;
  final List<String> reasons, conflicts;
  final bool candidate;
  const MatchScore(this.score, this.reasons, this.conflicts, this.candidate);

  String get confidence =>
      score >= 80 ? 'high' : (score >= 45 ? 'medium' : 'low');
}

String _digits(String? s) => (s ?? '').replaceAll(RegExp(r'\D'), '');

bool _samePhone(String? a, String? b) {
  final x = _digits(a), y = _digits(b);
  if (x.length < 7 || y.length < 7) return false;
  return x.substring(x.length - 8 > 0 ? x.length - 8 : 0) ==
      y.substring(y.length - 8 > 0 ? y.length - 8 : 0);
}

MatchScore scoreMatch(Map<String, Object?> manual, Map<String, Object?> sms) {
  final reasons = <String>[], conflicts = <String>[];
  var score = 0;
  var refMatch = false;
  final mr = (manual['reference'] as String?)?.trim() ?? '';
  final sr = (sms['reference'] as String?)?.trim() ?? '';
  if (mr.isNotEmpty && sr.isNotEmpty) {
    if (mr == sr) {
      score += 60;
      refMatch = true;
      reasons.add('same provider reference');
    } else {
      conflicts.add('different provider reference');
      score -= 40;
    }
  }
  if (manual['dir'] != sms['dir']) {
    conflicts.add('different direction');
    score -= 50;
  } else {
    score += 10;
    reasons.add('same direction');
  }
  final ma = manual['amount_minor'] as int?, sa = sms['amount_minor'] as int?;
  var amountEqual = false;
  if (ma != null && sa != null) {
    if (ma == sa) {
      amountEqual = true;
      score += 25;
      reasons.add('same amount');
    } else {
      conflicts.add('amount differs');
      score -= 30;
    }
  }
  final mf = manual['fee_minor'] as int?, sf = sms['fee_minor'] as int?;
  if (mf != null && sf != null && (mf != 0 || sf != 0)) {
    if (mf == sf) {
      score += 5;
      reasons.add('same fee');
    } else {
      conflicts.add('fee differs');
    }
  }
  final dt = ((manual['ts'] as int) - (sms['ts'] as int)).abs();
  var timeNear = false;
  if (dt <= 6 * 3600 * 1000) {
    score += 15;
    timeNear = true;
    reasons.add('within 6 hours');
  } else if (dt <= 24 * 3600 * 1000) {
    score += 5;
    timeNear = true;
    reasons.add('within 24 hours');
  } else {
    conflicts.add('more than 24 hours apart');
    score -= 20;
  }
  final mp = manual['party'] as String?, sp = sms['party'] as String?;
  if ((mp ?? '').isNotEmpty && (sp ?? '').isNotEmpty) {
    if (_samePhone(mp, sp) ||
        mp!.trim().toLowerCase() == sp!.trim().toLowerCase()) {
      score += 10;
      reasons.add('same counterparty');
    } else if (_digits(mp).length >= 7 && _digits(sp).length >= 7) {
      conflicts.add('different counterparty number');
      score -= 10;
    }
  }
  // Equal amounts alone never qualify: need a reference, or amount + time.
  final candidate = manual['dir'] == sms['dir'] &&
      (refMatch || (amountEqual && timeNear)) &&
      score >= 35;
  return MatchScore(score, reasons, conflicts, candidate);
}

class MatchService {
  final Database db;
  const MatchService(this.db);

  /// Writes a pending suggestion for every plausible (manual record, provider
  /// SMS row) pair that has none yet. Idempotent. Returns new suggestions.
  Future<int> suggestAll() async {
    final manuals = await db.query('tx',
        where: "source = 'manual' AND confirmation = 'awaiting' AND "
            "disposition = 'active' AND linked_to_tx_id IS NULL AND wallet_account_id IS NOT NULL");
    final smsRows = await db.query('tx',
        where: "source = 'sms' AND manual = 0 AND disposition = 'active' AND "
            'linked_to_tx_id IS NULL AND reverses_tx_id IS NULL');
    var added = 0;
    for (final m in manuals) {
      for (final s in smsRows) {
        final sameWallet = s['wallet_account_id'] == m['wallet_account_id'] ||
            (s['wallet_account_id'] == null && s['wallet'] == m['wallet']);
        if (!sameWallet) continue;
        final r = scoreMatch(m, s);
        if (!r.candidate) continue;
        final n = await db.insert(
            'match_suggestions',
            {
              'manual_tx_id': m['id'],
              'sms_tx_id': s['id'],
              'score': r.score,
              'reasons': jsonEncode(r.reasons),
              'conflicts': jsonEncode(r.conflicts),
              'created_at': DateTime.now().millisecondsSinceEpoch,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
        if (n > 0) added++;
      }
    }
    return added;
  }

  Future<List<Map<String, Object?>>> pending() => db.query('match_suggestions',
      where: "status = 'pending'", orderBy: 'score DESC, id');

  /// Owner approved the match. The manual record stays canonical; the SMS
  /// becomes its evidence and its own row is kept but marked as a duplicate
  /// so it is not counted twice. If amount or fee conflict the owner must say
  /// whether to adopt the provider's values; otherwise the record is marked
  /// mismatched instead of confirmed.
  Future<void> accept(int suggestionId,
      {bool adoptProviderValues = false}) async {
    final s = await db
        .query('match_suggestions', where: 'id = ?', whereArgs: [suggestionId]);
    if (s.isEmpty) throw LedgerException('suggestion $suggestionId not found');
    if (s.first['status'] != 'pending')
      throw const LedgerException('already decided');
    final mid = s.first['manual_tx_id']! as int,
        sid = s.first['sms_tx_id']! as int;
    final conflicts =
        (jsonDecode(s.first['conflicts']! as String) as List).cast<String>();
    final moneyConflict =
        conflicts.any((c) => c == 'amount differs' || c == 'fee differs');
    await db.transaction((t) async {
      final m = (await t.query('tx', where: 'id = ?', whereArgs: [mid])).first;
      final sms =
          (await t.query('tx', where: 'id = ?', whereArgs: [sid])).first;
      if (m['linked_to_tx_id'] != null ||
          sms['linked_to_tx_id'] != null ||
          sms['disposition'] != 'active' ||
          m['confirmation'] != 'awaiting') {
        throw const LedgerException('one of the records changed; review again');
      }
      final ref = (sms['reference'] as String?) ?? (m['reference'] as String?);
      // The original SMS text lives on the provider row; copy it as evidence.
      await t.insert('evidence', {
        'tx_id': mid,
        'kind': EvidenceKind.sms,
        'origin': EvidenceOrigin.providerSms,
        'uploaded_by': UploadedBy.owner,
        'sms_body': sms['body'],
        'sms_ts': sms['ts'],
        'sms_sub_id': sms['sub_id'],
        'reference': sms['reference'],
        'note': 'linked from transaction $sid',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      final updates = <String, Object?>{
        'reference': ref,
        'balance_minor': m['balance_minor'] ?? sms['balance_minor'],
        'balance': m['balance'] ?? sms['balance'],
      };
      var status = Confirmation.providerConfirmed;
      if (moneyConflict && !adoptProviderValues) {
        status = Confirmation.mismatched;
      } else if (moneyConflict) {
        updates['amount_minor'] = sms['amount_minor'];
        updates['amount'] = sms['amount'];
        updates['fee_minor'] = sms['fee_minor'];
        updates['fee'] = sms['fee'];
      }
      updates['confirmation'] = status;
      updates['confirmation_method'] =
          Confirmation.counted.contains(status) ? 'sms_match' : null;
      updates['confirmed_at'] = Confirmation.counted.contains(status)
          ? DateTime.now().millisecondsSinceEpoch
          : null;
      await t.update('tx', updates, where: 'id = ?', whereArgs: [mid]);
      await t.update('tx', {'disposition': 'duplicate', 'linked_to_tx_id': mid},
          where: 'id = ?', whereArgs: [sid]);
      await t.update(
          'match_suggestions',
          {
            'status': 'accepted',
            'decided_at': DateTime.now().millisecondsSinceEpoch
          },
          where: 'id = ?',
          whereArgs: [suggestionId]);
      await t.update(
          'match_suggestions',
          {
            'status': 'superseded',
            'decided_at': DateTime.now().millisecondsSinceEpoch
          },
          where:
              "status = 'pending' AND id <> ? AND (manual_tx_id IN (?, ?) OR sms_tx_id IN (?, ?))",
          whereArgs: [suggestionId, mid, sid, mid, sid]);
      final g = await startAuditGroup(t, 'match', mid, AuditSource.manual,
          'accepted delayed SMS match with transaction $sid');
      await writeAudit(t,
          txId: mid,
          event: 'match_accepted',
          field: 'confirmation',
          oldValue: Confirmation.awaiting,
          newValue: status,
          source: AuditSource.manual,
          reason:
              'sms row $sid linked${adoptProviderValues && moneyConflict ? ', provider values adopted' : ''}',
          groupId: g);
      await writeAudit(t,
          txId: sid,
          event: 'linked_as_duplicate',
          field: 'linked_to_tx_id',
          newValue: mid,
          source: AuditSource.manual,
          groupId: g);
    });
  }

  /// Owner says these are different transactions. Both stay as they are.
  Future<void> reject(int suggestionId) => db.update(
      'match_suggestions',
      {
        'status': 'rejected',
        'decided_at': DateTime.now().millisecondsSinceEpoch
      },
      where: "id = ? AND status = 'pending'",
      whereArgs: [suggestionId]);

  // ---- detectors ---------------------------------------------------------

  /// Records the owner sees as "recorded but the wallet never confirmed":
  /// manual rows still awaiting after [olderThan], split by whether proof exists.
  Future<List<Map<String, Object?>>> awaitingNotification(
      {Duration olderThan = const Duration(hours: 1), int? nowMs}) {
    final cutoff = (nowMs ?? DateTime.now().millisecondsSinceEpoch) -
        olderThan.inMilliseconds;
    return db.rawQuery(
        "SELECT t.*, (SELECT COUNT(*) FROM evidence e WHERE e.tx_id = t.id AND e.removed_at IS NULL) AS evidence_count "
        "FROM tx t WHERE t.confirmation = 'awaiting' AND t.disposition = 'active' "
        'AND t.reverses_tx_id IS NULL AND t.ts <= ? ORDER BY t.ts',
        [cutoff]);
  }

  /// Possible duplicate provider messages: same wallet, direction, amount and
  /// reference (or, without a reference, within two minutes). Equal amounts at
  /// different times are legitimate and never reported.
  Future<List<List<int>>> possibleDuplicates() async {
    final rows = await db.query('tx',
        where:
            "source = 'sms' AND disposition = 'active' AND amount_minor IS NOT NULL",
        orderBy: 'ts, id');
    final out = <List<int>>[];
    for (var i = 0; i < rows.length; i++) {
      for (var j = i + 1; j < rows.length; j++) {
        final a = rows[i], b = rows[j];
        if ((b['ts'] as int) - (a['ts'] as int) > 10 * 60 * 1000) break;
        if (a['wallet'] != b['wallet'] ||
            a['dir'] != b['dir'] ||
            a['amount_minor'] != b['amount_minor']) continue;
        final ra = (a['reference'] as String?) ?? '',
            rb = (b['reference'] as String?) ?? '';
        final same = ra.isNotEmpty && rb.isNotEmpty
            ? ra == rb
            : ra.isEmpty &&
                rb.isEmpty &&
                (b['ts'] as int) - (a['ts'] as int) <= 2 * 60 * 1000;
        if (same) out.add([a['id']! as int, b['id']! as int]);
      }
    }
    return out;
  }

  /// Balance-chain gaps per wallet, in transaction-time order (so messages that
  /// arrived out of order do not create false gaps): a row whose balance before
  /// it differs from the previous row's balance after hints at a missing
  /// message. Returns {tx_id, gap_minor} for the row after the gap.
  Future<List<Map<String, int>>> balanceGaps() async {
    final rows = await db.query('tx',
        where:
            "disposition = 'active' AND balance_minor IS NOT NULL AND amount_minor IS NOT NULL "
            "AND dir IN ('in','out') AND source = 'sms'",
        orderBy: 'wallet, ts, id');
    final gaps = <Map<String, int>>[];
    Map<String, Object?>? prev;
    for (final r in rows) {
      if (prev != null && prev['wallet'] == r['wallet']) {
        final impact = r['dir'] == 'in'
            ? (r['amount_minor']! as int) - (r['fee_minor'] as int? ?? 0)
            : -((r['amount_minor']! as int) + (r['fee_minor'] as int? ?? 0));
        final before = r['balance_before_minor'] as int? ??
            (r['balance_minor']! as int) - impact;
        final gap = before - (prev['balance_minor']! as int);
        if (gap != 0) gaps.add({'tx_id': r['id']! as int, 'gap_minor': gap});
      }
      prev = r;
    }
    return gaps;
  }
}
