import 'package:flutter/material.dart';

import 'dashboard_tab.dart';
import 'db.dart';
import 'evidence_section.dart';
import 'evidence_service.dart';
import 'ledger_service.dart';
import 'money_engine.dart';
import 'review_strings.dart';

/// Everything about one transaction: what it is, how sure we are, the proof,
/// any reversal or internal-transfer link, the actions the owner can take, and
/// the audit trail. Pops with `'edit'` when the owner asks for the classic
/// classification / note editor.
class TxDetailScreen extends StatefulWidget {
  final int txId;
  const TxDetailScreen({super.key, required this.txId});

  @override
  State<TxDetailScreen> createState() => _TxDetailScreenState();
}

class _TxDetailScreenState extends State<TxDetailScreen> {
  Map<String, Object?>? _tx;
  ReversalInfo? _rev;
  List<Map<String, Object?>> _history = [];
  EvidenceService? _ev;
  int? _linkCandidate;
  bool _reversed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await TxDb.database();
    final led = await TxDb.ledger();
    final ev = await TxDb.evidence();
    final r = await db.query('tx', where: 'id = ?', whereArgs: [widget.txId]);
    if (r.isEmpty) return;
    final rev = await led.reversalInfo(widget.txId);
    final cands = await led.internalTransferCandidates();
    int? link;
    for (final (o, i) in cands) {
      if (o == widget.txId) link = i;
      if (i == widget.txId) link = o;
    }
    final h = await led.history(widget.txId);
    if (!mounted) return;
    setState(() {
      _tx = r.first;
      _rev = rev;
      _reversed = rev != null && rev.originalId == widget.txId;
      _history = h;
      _ev = ev;
      _linkCandidate = link;
    });
  }

  Future<String?> _ask(String title, String label,
      {bool number = false}) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
            controller: c,
            autofocus: true,
            keyboardType: number
                ? const TextInputType.numberWithOptions(decimal: true)
                : null,
            decoration: InputDecoration(labelText: label)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(reviewText(ctx, 'إلغاء', 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(reviewText(ctx, 'حسناً', 'OK'))),
        ],
      ),
    );
    return ok == true && c.text.trim().isNotEmpty ? c.text.trim() : null;
  }

  Future<void> _do(Future<String?> Function() f) async {
    final msg = ScaffoldMessenger.of(context);
    try {
      final note = await f();
      if (note != null) msg.showSnackBar(SnackBar(content: Text(note)));
    } on LedgerException catch (e) {
      msg.showSnackBar(SnackBar(content: Text(e.message)));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tx = _tx;
    final t = reviewText;
    if (tx == null || _ev == null) {
      return Scaffold(
          appBar: AppBar(),
          body: const Center(child: CircularProgressIndicator()));
    }
    final status = (tx['confirmation'] as String?) ?? 'awaiting';
    final isReversal = tx['reverses_tx_id'] != null;
    final reversedLike = _reversed || isReversal;
    final amount = tx['amount_minor'] as int?;
    final fee = tx['fee_minor'] as int? ?? 0;
    final owner = (tx['fee_owner'] as String?) ?? 'owner';
    final impact =
        walletImpactMinor('${tx['dir']}', amount, fee, feeOwner: owner);
    final canAct = !reversedLike && tx['disposition'] == 'active';
    final ownerLabel = switch (owner) {
      'sender' => t(context, 'المرسل', 'sender'),
      'other' => t(context, 'طرف آخر', 'another party'),
      'unknown' => t(context, 'غير معروف', 'unknown'),
      _ => t(context, 'صاحب المحفظة', 'wallet owner'),
    };
    return Scaffold(
      appBar: AppBar(
          title: Text(t(context, 'تفاصيل المعاملة', 'Transaction')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, 'edit'),
                child: Text(t(context, 'تعديل', 'Edit'))),
          ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(amount == null ? '?' : formatMinor(amount),
                  style: Theme.of(context).textTheme.headlineMedium),
              Chip(
                  label: Text(
                      statusLabel(context, status, reversed: reversedLike)),
                  backgroundColor: statusColor(status, reversed: reversedLike)
                      .withValues(alpha: 0.15)),
            ]),
        Text(
            '${tx['dir'] == 'in' ? t(context, 'وارد', 'Incoming') : tx['dir'] == 'out' ? t(context, 'صادر', 'Outgoing') : '?'}'
            ' · ${tx['type']} · ${tx['wallet']}'),
        Text(DateTime.fromMillisecondsSinceEpoch(tx['ts']! as int)
            .toString()
            .substring(0, 16)),
        Text('${t(context, 'المصدر', 'Source')}: ${tx['source']}'
            '${tx['confirmation_method'] != null ? ' · ${t(context, 'طريقة التأكيد', 'confirmed via')}: ${tx['confirmation_method']}' : ''}'),
        if (status == 'awaiting' && tx['source'] == 'manual')
          Text(
              t(context, 'سُجّلت يدوياً ولم يتم التحقق منها بشكل مستقل.',
                  'Recorded by hand; not independently verified.'),
              style: TextStyle(color: Colors.amber.shade900)),
        if ((tx['party'] as String? ?? '').isNotEmpty)
          Text('${t(context, 'الطرف الآخر', 'Counterparty')}: ${tx['party']}'),
        if ((tx['reference'] as String? ?? '').isNotEmpty)
          Text('${t(context, 'المرجع', 'Reference')}: ${tx['reference']}'),
        if ((tx['note'] as String? ?? '').isNotEmpty) Text('${tx['note']}'),
        const Divider(),
        Text(
            '${t(context, 'الرسوم', 'Fee')}: ${formatMinor(fee)} (${t(context, 'يدفعها', 'paid by')} $ownerLabel)'),
        if (impact != null && !reversedLike)
          Text(
              '${t(context, 'الأثر على المحفظة', 'Wallet impact')}: ${impact >= 0 ? '+' : ''}${formatMinor(impact)}'),
        if (tx['balance_minor'] != null)
          Text(
              '${t(context, 'الرصيد بعد', 'Balance after')}: ${formatMinor(tx['balance_minor']! as int)}'),
        if (_rev != null)
          Card(
            color: Colors.blueGrey.shade50,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t(context, 'معاملة معكوسة', 'Reversed transaction'),
                        style: Theme.of(context).textTheme.titleSmall),
                    Text(
                        '${t(context, 'الأصل', 'Original')} #${_rev!.originalId}: ${formatMinor(_rev!.originalImpactMinor)}'),
                    Text(
                        '${t(context, 'العكس', 'Reversal')} #${_rev!.reversalId}: ${formatMinor(_rev!.reversalImpactMinor)}'),
                    Text(
                        '${t(context, 'الصافي', 'Net wallet impact')}: ${formatMinor(_rev!.netMinor)}'),
                    if (_rev!.reason.isNotEmpty) Text(_rev!.reason),
                    Text(
                        t(context, 'لا تُحتسب كإنفاق ولا كدخل.',
                            'Counted as neither spending nor income.'),
                        style: Theme.of(context).textTheme.bodySmall),
                  ]),
            ),
          ),
        if (tx['transfer_peer_id'] != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: Text(t(
                  context,
                  'تحويل بين محافظك #${tx['transfer_peer_id']}',
                  'Move between your wallets #${tx['transfer_peer_id']}')),
              subtitle: Text(t(
                  context,
                  'لا يُحتسب دخلاً ولا إنفاقاً في الإجمالي',
                  'Not counted as income or spending in totals')),
              trailing: TextButton(
                  onPressed: () => _do(() async {
                        await (await TxDb.ledger())
                            .unlinkInternalTransfer(widget.txId);
                        return null;
                      }),
                  child: Text(t(context, 'فك الربط', 'Unlink'))),
            ),
          ),
        if (_linkCandidate != null && canAct)
          Card(
            child: ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: Text(t(
                  context,
                  'هل هو تحويل بين محافظك؟ مقابل #$_linkCandidate',
                  'Move between your own wallets? Pair #$_linkCandidate')),
              trailing: FilledButton(
                  onPressed: () => _do(() async {
                        final led = await TxDb.ledger();
                        if (tx['dir'] == 'out') {
                          await led.linkInternalTransfer(
                              widget.txId, _linkCandidate!);
                        } else {
                          await led.linkInternalTransfer(
                              _linkCandidate!, widget.txId);
                        }
                        return null;
                      }),
                  child: Text(t(context, 'ربط', 'Link'))),
            ),
          ),
        const SizedBox(height: 8),
        if (canAct)
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (status != 'provider_confirmed' && status != 'balance_confirmed')
              FilledButton.tonal(
                  onPressed: () async {
                    final r = await _ask(
                        t(context, 'تأكيد من المحفظة', 'Confirm from wallet'),
                        t(context, 'ما الذي تحققت منه؟',
                            'What did you check?'));
                    if (r == null) return;
                    await _do(() async {
                      await (await TxDb.confirmations())
                          .confirmByProvider(widget.txId, reason: r);
                      return null;
                    });
                  },
                  child: Text(t(context, 'تأكيد (تحققت من المحفظة)',
                      'Confirm (checked wallet)'))),
            OutlinedButton(
                onPressed: () async {
                  final r = await _ask(
                      t(context, 'تأكيد بالرصيد', 'Confirm by balance'),
                      t(context, 'الرصيد الحالي الفعلي للمحفظة',
                          'Actual wallet balance now'),
                      number: true);
                  final minor = r == null ? null : parseMinor(r);
                  if (minor == null) return;
                  await _do(() async {
                    final diff = await (await TxDb.confirmations())
                        .confirmByBalance(widget.txId, minor);
                    return diff == 0
                        ? t(context, 'الرصيد مطابق.', 'Balance matches.')
                        : t(context, 'الفرق: ${formatMinor(diff)}',
                            'Difference: ${formatMinor(diff)}');
                  });
                },
                child: Text(t(context, 'تأكيد بالرصيد', 'Confirm by balance'))),
            PopupMenuButton<String>(
              child: Chip(
                  label: Text(t(context, 'تغيير الحالة', 'Change status'))),
              onSelected: (s) async {
                final r = await _ask(t(context, 'السبب', 'Reason'),
                    t(context, 'السبب', 'Reason'));
                if (r == null) return;
                await _do(() async {
                  await (await TxDb.confirmations())
                      .setStatus(widget.txId, s, reason: r);
                  return null;
                });
              },
              itemBuilder: (_) => [
                for (final s in ['awaiting', 'failed', 'cancelled', 'disputed'])
                  PopupMenuItem(value: s, child: Text(statusLabel(context, s))),
              ],
            ),
            OutlinedButton(
                onPressed: () async {
                  final r = await _ask(
                      t(context, 'عكس المعاملة', 'Reverse transaction'),
                      t(context, 'سبب العكس', 'Reason for reversal'));
                  if (r == null) return;
                  await _do(() async {
                    await (await TxDb.ledger()).reverse(widget.txId, reason: r);
                    return null;
                  });
                },
                child: Text(t(context, 'عكس', 'Reverse'))),
          ]),
        const Divider(),
        EvidenceSection(service: _ev!, txId: widget.txId),
        const Divider(),
        Text(t(context, 'السجل', 'History'),
            style: Theme.of(context).textTheme.titleMedium),
        if (_history.isEmpty) Text(t(context, 'لا تغييرات.', 'No changes.')),
        for (final e in _history)
          ListTile(
            dense: true,
            title: Text(
                '${e['event']}${e['field'] != null ? ' · ${e['field']}' : ''}'),
            subtitle: Text(
                '${e['old_value'] ?? ''} → ${e['new_value'] ?? ''}'
                '${(e['reason'] as String? ?? '').isNotEmpty ? '\n${e['reason']}' : ''}',
                textDirection: TextDirection.ltr),
            trailing: Text('${e['source']}',
                style: Theme.of(context).textTheme.labelSmall),
          ),
      ]),
    );
  }
}
