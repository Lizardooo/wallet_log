/// Gemini output as suggestions the owner accepts or dismisses.
///
/// The model is never the source of truth: nothing it returns changes a
/// transaction until [AiSuggestionService.accept] runs, and that goes through
/// the audited [LedgerService.correct] path (source `ai_accept`). Identical
/// inputs are remembered by hash so repeated launches do not repeat API calls.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'evidence_service.dart';
import 'ledger_service.dart';
import 'parser.dart';
import 'schema.dart';

class AiKind {
  static const classify = 'classify';
  static const fee = 'fee';
  static const duplicate = 'duplicate';
  static const matchManual = 'match_manual';
  static const failed = 'failed';
  static const balanceGap = 'balance_gap';
  static const amount = 'amount';
  static const pending = 'pending_status';
  static const provider = 'provider';
  static const analyzed = 'analyzed'; // marker: nothing to suggest
}

/// Fingerprint of everything that can change the answer: the message, who it
/// is from, what the parser concluded, the model and the prompt version. Same
/// fingerprint = same question, so the stored answer is reused.
String aiInputHash(String body,
        {String model = '',
        String kind = AiKind.classify,
        String context = '',
        String promptVersion = ''}) =>
    sha256
        .convert(utf8.encode(
            '$kind|$model|$promptVersion|$context|${normalizeDigits(body).trim()}'))
        .toString();

class AiSuggestionService {
  final Database db;
  const AiSuggestionService(this.db);

  /// Stores a suggestion once per (input, kind, action). Returns its id, or
  /// null when the same suggestion already exists (decided or not).
  Future<int?> store({
    int? txId,
    int? relatedTxId,
    required String kind,
    required String action,
    String reason = '',
    Map<String, Object?> payload = const {},
    double? confidence,
    required String inputHash,
  }) =>
      storeOn(db,
          txId: txId,
          relatedTxId: relatedTxId,
          kind: kind,
          action: action,
          reason: reason,
          payload: payload,
          confidence: confidence,
          inputHash: inputHash);

  static Future<int?> storeOn(
    DatabaseExecutor db, {
    int? txId,
    int? relatedTxId,
    required String kind,
    required String action,
    String reason = '',
    Map<String, Object?> payload = const {},
    double? confidence,
    required String inputHash,
  }) async {
    final id = await db.insert(
        'ai_suggestions',
        {
          'tx_id': txId,
          'related_tx_id': relatedTxId,
          'kind': kind,
          'action': action,
          'reason': reason,
          'payload': jsonEncode(payload),
          'confidence': confidence,
          'input_hash': inputHash,
          'status': kind == AiKind.analyzed ? 'noop' : 'pending',
          'created_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return id == 0 ? null : id;
  }

  /// True when this exact input was already analysed (so no API call needed).
  Future<bool> alreadyAnalysed(String inputHash) async =>
      (await db.query('ai_suggestions',
              columns: ['id'],
              where: 'input_hash = ?',
              whereArgs: [inputHash],
              limit: 1))
          .isNotEmpty;

  Future<List<Map<String, Object?>>> pending() => db.query('ai_suggestions',
      where: "status = 'pending'", orderBy: 'confidence DESC, id');

  Future<void> dismiss(int id) => db.update(
      'ai_suggestions',
      {
        'status': 'dismissed',
        'decided_at': DateTime.now().millisecondsSinceEpoch
      },
      where: "id = ? AND status = 'pending'",
      whereArgs: [id]);

  /// Applies an accepted suggestion. Only `classify` (direction / category) and
  /// `fee` change data; the other kinds are advice, so accepting them just
  /// acknowledges them. Everything applied is audited with source ai_accept.
  Future<void> accept(int id) async {
    final r =
        await db.query('ai_suggestions', where: 'id = ?', whereArgs: [id]);
    if (r.isEmpty) throw LedgerException('suggestion $id not found');
    final s = r.first;
    if (s['status'] != 'pending')
      throw const LedgerException('already decided');
    final payload = jsonDecode(s['payload']! as String) as Map<String, dynamic>;
    final txId = s['tx_id'] as int?;
    final led = LedgerService(db);
    if (txId != null && s['kind'] == AiKind.classify) {
      final changes = <CorrectableField, Object?>{
        if (payload['dir'] is String) CorrectableField.dir: payload['dir'],
        if (payload['type'] is String) CorrectableField.type: payload['type'],
      };
      if (changes.isNotEmpty) {
        await led.correct(txId, changes,
            source: AuditSource.aiAccept,
            reason: (s['reason'] as String?) ?? '');
      }
      await db.update('tx', {'review': 0}, where: 'id = ?', whereArgs: [txId]);
    } else if (txId != null && s['kind'] == AiKind.fee) {
      final changes = <CorrectableField, Object?>{
        if (payload['fee_minor'] is int)
          CorrectableField.fee: payload['fee_minor'],
        if (payload['fee_owner'] is String)
          CorrectableField.feeOwner: payload['fee_owner'],
      };
      if (changes.isNotEmpty) {
        await led.correct(txId, changes,
            source: AuditSource.aiAccept,
            reason: (s['reason'] as String?) ?? '');
      }
    } else if (txId != null &&
        s['kind'] == AiKind.amount &&
        payload['amount_minor'] is int) {
      await led.correct(
          txId, {CorrectableField.amount: payload['amount_minor']},
          source: AuditSource.aiAccept, reason: (s['reason'] as String?) ?? '');
    } else if (txId != null && s['kind'] == AiKind.failed) {
      // Goes through the audited confirmation workflow, never a raw update.
      await ConfirmationService(db).setStatus(txId, Confirmation.failed,
          reason: 'accepted Gemini suggestion: ${s['reason'] ?? ''}');
    } else if (txId != null &&
        s['kind'] == AiKind.matchManual &&
        payload['manual_tx_id'] is int) {
      // Still not a merge: it only puts the pair in front of the match review,
      // which shows the conflicts and needs its own approval.
      await db.insert(
          'match_suggestions',
          {
            'manual_tx_id': payload['manual_tx_id'],
            'sms_tx_id': txId,
            'score': 40,
            'reasons': jsonEncode(['suggested by Gemini']),
            'conflicts': jsonEncode(<String>[]),
            'created_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await db.update(
        'ai_suggestions',
        {
          'status': 'accepted',
          'decided_at': DateTime.now().millisecondsSinceEpoch
        },
        where: 'id = ?',
        whereArgs: [id]);
  }
}
