/// Runs Gemini analysis over stored messages: skips what was already analysed,
/// never sends excluded or hand-typed records, turns answers into stored
/// suggestions and changes nothing else.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

import 'ai_suggestions.dart';
import 'gemini.dart';
import 'money_engine.dart';

/// Version of the local parser's logic as far as the cache is concerned.
const parserVersion = 'p1';

/// What the owner is told is sent. Shown next to the on/off switch.
const aiDisclosureAr =
    'يُرسل إلى Gemini نص الرسالة فقط (أرقام الهواتف والحسابات الطويلة مُقنّعة)، '
    'واسم المحفظة، وملخص ما فهمه التطبيق، وأسطر مختصرة عن السجلات اليدوية '
    'المعلقة (المبلغ والاتجاه والوقت). لا تُرسل الصور ولا الإيصالات ولا السجلات '
    'المستبعدة أو اليدوية ولا مفتاح الـ API.';
const aiDisclosureEn =
    'Sent to Gemini: the message text (phone numbers and long account numbers '
    'masked), the wallet name, a short summary of what the app understood, and '
    'brief lines about pending manual records (amount, direction, time). Never '
    'sent: images, receipts, excluded or manual records, or your API key.';

class AiRunResult {
  final int analysed, skippedCached, suggestions;
  const AiRunResult(this.analysed, this.skippedCached, this.suggestions);
}

class AiDisabledException implements Exception {
  const AiDisabledException();
  @override
  String toString() => 'AI analysis is turned off';
}

class AiRunner {
  /// Fingerprints currently being analysed, so two taps (or two screens) never
  /// send the same message twice at once.
  static final Set<String> _inFlight = {};

  static const settingEnabled = 'ai_enabled';

  static Future<bool> isEnabled(Database db) async => (await db
          .query('settings', where: 'key = ?', whereArgs: [settingEnabled]))
      .any((r) => r['value'] == '1');

  static String fingerprint(Map<String, Object?> tx, String model) =>
      aiInputHash(
        (tx['body'] as String?) ?? '',
        model: model,
        kind: 'analysis',
        promptVersion: '$analysisPromptVersion/$parserVersion',
        context:
            '${tx['wallet']}|${tx['dir']}|${tx['type']}|${tx['amount_minor']}|${tx['fee_minor']}',
      );

  /// Analyses up to [limit] eligible rows. [force] ignores the cache for the
  /// given [onlyIds] (the explicit "analyse again" action).
  static Future<AiRunResult> run(
    Database db, {
    required String apiKey,
    required String model,
    Iterable<int>? onlyIds,
    bool force = false,
    int batch = 10,
    int limit = 200,
    http.Client? client,
    Duration retryDelay = const Duration(seconds: 2),
    void Function(int done, int total)? onProgress,
  }) async {
    if (!await isEnabled(db)) throw const AiDisabledException();
    final svc = AiSuggestionService(db);
    final ids = onlyIds?.toSet();
    final rows = await db.query('tx',
        where: "manual = 0 AND source = 'sms' AND disposition = 'active' "
            "AND body IS NOT NULL AND body <> '' AND reverses_tx_id IS NULL",
        orderBy: 'ts DESC');
    final candidates = await db.query('tx',
        where:
            "source = 'manual' AND confirmation = 'awaiting' AND disposition = 'active'");
    var skipped = 0;
    final todo = <(Map<String, Object?>, String)>[];
    for (final r in rows) {
      if (ids != null && !ids.contains(r['id'])) continue;
      final fp = fingerprint(r, model);
      if (!force && await svc.alreadyAnalysed(fp)) {
        skipped++;
        continue;
      }
      if (_inFlight.contains(fp)) {
        skipped++;
        continue;
      }
      todo.add((r, fp));
      if (todo.length >= limit) break;
    }
    var analysed = 0, made = 0;
    for (var i = 0; i < todo.length; i += batch) {
      final chunk = todo.skip(i).take(batch).toList();
      final fps = chunk.map((c) => c.$2).toList();
      _inFlight.addAll(fps);
      try {
        final items = [
          for (final (r, _) in chunk)
            AnalysisItem(
              id: r['id']! as int,
              wallet: '${r['wallet']}',
              body: (r['body'] as String?) ?? '',
              parsed:
                  '${r['type']}/${r['dir']} amount ${_fmt(r['amount_minor'] as int?)} '
                  'fee ${_fmt(r['fee_minor'] as int?)}',
              candidates: [
                for (final m in candidates)
                  if (m['wallet'] == r['wallet'] &&
                      ((m['ts'] as int) - (r['ts'] as int)).abs() <=
                          48 * 3600 * 1000)
                    '#${m['id']} ${m['dir']} ${_fmt(m['amount_minor'] as int?)} '
                        'at ${DateTime.fromMillisecondsSinceEpoch(m['ts'] as int).toIso8601String()}'
              ],
            ),
        ];
        final findings = await analyzeMessages(
            apiKey: apiKey,
            model: model,
            items: items,
            client: client,
            retryDelay: retryDelay);
        final byId = {for (final f in findings) f.id: f};
        for (final (r, fp) in chunk) {
          final f = byId[r['id']];
          if (f == null)
            continue; // unanswered: leave uncached so it can be retried
          made += await _store(svc, r, f, fp);
          await svc.store(
              txId: r['id'] as int,
              kind: AiKind.analyzed,
              action: 'none',
              inputHash: fp);
          analysed++;
        }
      } finally {
        _inFlight.removeAll(fps);
      }
      onProgress?.call(i + chunk.length, todo.length);
    }
    return AiRunResult(analysed, skipped, made);
  }

  static String _fmt(int? m) => m == null ? '-' : formatMinor(m);

  /// Turns one finding into zero or more stored suggestions; returns how many
  /// new ones were created. Nothing here touches the transaction.
  static Future<int> _store(AiSuggestionService svc, Map<String, Object?> r,
      AiFinding f, String fp) async {
    final id = r['id']! as int;
    var n = 0;
    Future<void> add(String kind, String action, Map<String, Object?> payload,
        {int? related}) async {
      final made = await svc.store(
          txId: id,
          relatedTxId: related,
          kind: kind,
          action: action,
          reason: f.reason,
          payload: payload,
          confidence: f.confidence,
          inputHash: fp);
      if (made != null) n++;
    }

    final curType = r['type'], curDir = r['dir'];
    if ((f.dir != null && f.dir != 'unknown' && f.dir != curDir) ||
        (f.type != null && f.type != 'other' && f.type != curType)) {
      await add(AiKind.classify, 'classify', {
        if (f.type != null && f.type != 'other') 'type': f.type,
        if (f.dir != null && f.dir != 'unknown') 'dir': f.dir,
      });
    }
    if (f.amountMinor != null && f.amountMinor != r['amount_minor']) {
      await add(
          AiKind.amount, 'review_amount', {'amount_minor': f.amountMinor});
    }
    final feeChanged =
        f.feeMinor != null && f.feeMinor != (r['fee_minor'] ?? 0);
    final ownerChanged =
        f.feeOwner != null && f.feeOwner != (r['fee_owner'] ?? 'owner');
    if (feeChanged || ownerChanged) {
      await add(AiKind.fee, 'review_fee', {
        if (feeChanged) 'fee_minor': f.feeMinor,
        if (f.feeOwner != null) 'fee_owner': f.feeOwner,
      });
    }
    if (f.status == 'failed' && r['confirmation'] != 'failed') {
      await add(AiKind.failed, 'mark_failed', {});
    } else if (f.status == 'pending') {
      await add(AiKind.pending, 'keep_awaiting', {});
    }
    if (f.duplicateOf != null) {
      await add(
          AiKind.duplicate, 'review_duplicate', {'duplicate_of': f.duplicateOf},
          related: f.duplicateOf);
    }
    if (f.matchManualId != null) {
      await add(
          AiKind.matchManual, 'review_match', {'manual_tx_id': f.matchManualId},
          related: f.matchManualId);
    }
    if (f.warning != null)
      await add(AiKind.balanceGap, 'review_balance', {'warning': f.warning});
    if (f.provider != null && f.provider != 'other') {
      final code = f.provider!;
      final cur = '${r['wallet']}'.toLowerCase();
      final known = {
        'vodafone_cash': 'vodafone',
        'orange_cash': 'orange',
        'etisalat_cash': 'etisalat',
        'we_pay': 'we',
        'instapay': 'instapay'
      }[code];
      if (known != null && !cur.contains(known)) {
        await add(AiKind.provider, 'review_provider', {'provider': code});
      }
    }
    return n;
  }
}

String payloadText(String json) =>
    const JsonEncoder().convert(jsonDecode(json));
