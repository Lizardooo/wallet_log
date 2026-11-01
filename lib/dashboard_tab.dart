import 'package:flutter/material.dart';

import 'add_tx_screen.dart';
import 'db.dart';
import 'money_engine.dart';
import 'review_strings.dart';
import 'summary_service.dart';
import 'suggestions_screen.dart';
import 'tx_detail_screen.dart';

String statusLabel(BuildContext c, String status, {bool reversed = false}) {
  if (reversed) return reviewText(c, 'معكوسة', 'Reversed');
  return switch (status) {
    'provider_confirmed' =>
      reviewText(c, 'مؤكدة من المحفظة', 'Provider-confirmed'),
    'balance_confirmed' => reviewText(c, 'مؤكدة بالرصيد', 'Balance-confirmed'),
    'mismatched' => reviewText(c, 'غير متطابقة', 'Mismatch'),
    'disputed' => reviewText(c, 'متنازع عليها', 'Disputed'),
    'failed' => reviewText(c, 'فاشلة', 'Failed'),
    'cancelled' => reviewText(c, 'ملغاة', 'Cancelled'),
    'reversed' => reviewText(c, 'معكوسة', 'Reversed'),
    _ => reviewText(c, 'بانتظار التأكيد', 'Awaiting confirmation'),
  };
}

Color statusColor(String status, {bool reversed = false}) {
  if (reversed) return Colors.blueGrey;
  return switch (status) {
    'provider_confirmed' || 'balance_confirmed' => Colors.green.shade700,
    'mismatched' || 'disputed' => Colors.deepOrange,
    'failed' || 'cancelled' => Colors.red.shade700,
    _ => Colors.amber.shade800,
  };
}

/// Home: confirmed figures first, pending money clearly apart, then wallets,
/// what is waiting, and a compact summary. Nothing unconfirmed is added to a
/// confirmed number.
class DashboardTab extends StatefulWidget {
  final int refresh; // bump to reload
  const DashboardTab({super.key, this.refresh = 0});

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  DashboardData? _d;
  List<Map<String, Object?>> _latest = [], _awaiting = [];
  int _suggestions = 0;
  bool _month = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DashboardTab old) {
    super.didUpdateWidget(old);
    if (old.refresh != widget.refresh) _load();
  }

  Future<void> _load() async {
    final s = await TxDb.summary();
    final now = DateTime.now();
    final d =
        await s.dashboard(from: _month ? DateTime(now.year, now.month) : null);
    final latest = await s.latest(limit: 8);
    final awaiting = await s.awaiting(limit: 5);
    final n = (await (await TxDb.matches()).pending()).length +
        (await (await TxDb.aiSuggestions()).pending()).length;
    if (!mounted) return;
    setState(() {
      _d = d;
      _latest = latest;
      _awaiting = awaiting;
      _suggestions = n;
    });
  }

  Future<void> _open(int id) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => TxDetailScreen(txId: id)));
    await _load();
  }

  Widget _figure(BuildContext c, String label, int minor, Color color) =>
      Expanded(
        child: Column(children: [
          Text(label,
              style: Theme.of(c).textTheme.bodySmall,
              textAlign: TextAlign.center),
          FittedBox(
              child: Text(formatMinor(minor),
                  style: Theme.of(c)
                      .textTheme
                      .titleLarge
                      ?.copyWith(color: color, fontWeight: FontWeight.bold))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) return const Center(child: CircularProgressIndicator());
    final t = reviewText;
    final warnings = <String>[
      if (d.mismatchedCount > 0)
        t(context, '${d.mismatchedCount} معاملة غير متطابقة',
            '${d.mismatchedCount} mismatched transaction(s)'),
      if (d.gapCount > 0)
        t(
            context,
            'فجوات في سلسلة الرصيد (${d.gapCount}) — قد تكون هناك رسائل ناقصة',
            'Balance chain gaps (${d.gapCount}) — a message may be missing'),
      for (final w in d.wallets)
        if (w.discrepancyMinor != null && w.discrepancyMinor != 0)
          t(
              context,
              '${w.provider}: الفرق عن الرصيد الذي أكدته ${formatMinor(w.discrepancyMinor!)}',
              '${w.provider}: ${formatMinor(w.discrepancyMinor!)} off your last confirmed balance'),
      if (d.uncertainFeeMinor > 0)
        t(
            context,
            'رسوم غير معروفة الدافع: ${formatMinor(d.uncertainFeeMinor)}',
            'Fees with unknown payer: ${formatMinor(d.uncertainFeeMinor)}'),
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Wrap(spacing: 8, children: [
          for (final (value, label) in [
            (true, t(context, 'هذا الشهر', 'This month')),
            (false, t(context, 'الكل', 'All time')),
          ])
            ChoiceChip(
              label: Text(label),
              selected: _month == value,
              onSelected: (_) {
                setState(() => _month = value);
                _load();
              },
            ),
        ]),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t(context, 'مؤكد', 'Confirmed'),
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Row(children: [
                _figure(context, t(context, 'دخل', 'In'), d.incomeMinor,
                    Colors.green.shade700),
                _figure(context, t(context, 'خرج', 'Out'), d.spendMinor,
                    Colors.red.shade700),
                _figure(context, t(context, 'رسوم', 'Fees'), d.feesMinor,
                    Colors.blueGrey),
              ]),
              const Divider(height: 24),
              Text(
                  t(context, 'معلّق (غير مؤكد — غير محتسب في الأرصدة)',
                      'Pending (unconfirmed — not in balances)'),
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Row(children: [
                _figure(context, t(context, 'وارد معلّق', 'Pending in'),
                    d.pendingInMinor, Colors.amber.shade800),
                _figure(context, t(context, 'صادر معلّق', 'Pending out'),
                    d.pendingOutMinor, Colors.amber.shade800),
                Expanded(
                    child: Column(children: [
                  Text(t(context, 'العدد', 'Count'),
                      style: Theme.of(context).textTheme.bodySmall),
                  Text('${d.pendingCount}',
                      style: Theme.of(context).textTheme.titleLarge),
                ])),
              ]),
            ]),
          ),
        ),
        if (warnings.isNotEmpty)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t(context, 'تنبيهات', 'Needs attention'),
                        style: Theme.of(context).textTheme.titleSmall),
                    for (final w in warnings) Text('• $w'),
                  ]),
            ),
          ),
        if (_suggestions > 0)
          Card(
            child: ListTile(
              leading: const Icon(Icons.lightbulb_outline),
              title: Text(t(context, '$_suggestions اقتراح بانتظار مراجعتك',
                  '$_suggestions suggestion(s) to review')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const SuggestionsScreen()));
                await _load();
              },
            ),
          ),
        const SizedBox(height: 8),
        Text(t(context, 'المحافظ', 'Wallets'),
            style: Theme.of(context).textTheme.titleMedium),
        if (d.wallets.isEmpty)
          Text(t(context, 'لم تضف محفظة بعد.', 'No wallet yet.')),
        for (final w in d.wallets)
          Card(
            child: InkWell(
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => WalletScreen(summary: w))),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          '${w.provider}${w.nickname.isEmpty ? '' : ' · ${w.nickname}'}',
                          style: Theme.of(context).textTheme.titleSmall),
                      Text([
                        if (w.phone.isNotEmpty) w.phone,
                        if (w.totals.pendingCount > 0)
                          t(context, 'معلّق: ${w.totals.pendingCount}',
                              'Pending: ${w.totals.pendingCount}'),
                      ].join(' · ')),
                      Text(
                          '${t(context, 'الرصيد المؤكد', 'Confirmed balance')}: '
                          '${w.totals.confirmedBalanceMinor == null ? '—' : formatMinor(w.totals.confirmedBalanceMinor!)}',
                          style: Theme.of(context).textTheme.titleMedium),
                    ]),
              ),
            ),
          ),
        if (_awaiting.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(t(context, 'بانتظار التأكيد', 'Awaiting confirmation'),
              style: Theme.of(context).textTheme.titleMedium),
          for (final r in _awaiting)
            TxTile(row: r, onTap: () => _open(r['id']! as int)),
        ],
        const SizedBox(height: 8),
        Text(t(context, 'آخر المعاملات', 'Latest transactions'),
            style: Theme.of(context).textTheme.titleMedium),
        if (_latest.isEmpty)
          Text(t(context, 'لا توجد معاملات.', 'No transactions yet.')),
        for (final r in _latest)
          TxTile(row: r, onTap: () => _open(r['id']! as int)),
        const SizedBox(height: 12),
        _Report(d: d),
        const SizedBox(height: 72),
      ]),
    );
  }
}

class TxTile extends StatelessWidget {
  final Map<String, Object?> row;
  final VoidCallback onTap;
  final bool reversed;
  const TxTile(
      {super.key,
      required this.row,
      required this.onTap,
      this.reversed = false});

  @override
  Widget build(BuildContext context) {
    final out = row['dir'] == 'out';
    final amount = row['amount_minor'] as int?;
    final status = (row['confirmation'] as String?) ?? 'awaiting';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(out ? Icons.arrow_upward : Icons.arrow_downward,
              color: out ? Colors.red.shade700 : Colors.green.shade700),
          const SizedBox(width: 8),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  '${amount == null ? '?' : formatMinor(amount)}  ${row['type'] ?? ''}',
                  style: Theme.of(context).textTheme.titleSmall),
              Text(
                  '${DateTime.fromMillisecondsSinceEpoch(row['ts']! as int).toString().substring(0, 16)}'
                  '${row['source'] == 'manual' ? ' · ${reviewText(context, 'يدوي', 'manual')}' : ''}',
                  style: Theme.of(context).textTheme.bodySmall),
              Text(statusLabel(context, status, reversed: reversed),
                  style: TextStyle(
                      color: statusColor(status, reversed: reversed),
                      fontSize: 12)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Report extends StatelessWidget {
  final DashboardData d;
  const _Report({required this.d});

  @override
  Widget build(BuildContext context) {
    final t = reviewText;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t(context, 'ملخص', 'Summary'),
              style: Theme.of(context).textTheme.titleMedium),
          Text(t(context, 'الصافي المؤكد', 'Confirmed net') +
              ': ${formatMinor(d.netMinor)}'),
          Text(t(context, 'الرسوم المدفوعة', 'Fees paid') +
              ': ${formatMinor(d.feesMinor)}'),
          Text(
              t(context, 'التحويلات بين محافظك لا تُحسب دخلاً ولا إنفاقاً.',
                  'Moves between your own wallets are not counted as income or spending.'),
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          Text(t(context, 'الإنفاق حسب النوع', 'Spending by category'),
              style: Theme.of(context).textTheme.titleSmall),
          if (d.spendByType.isEmpty)
            Text(t(context, 'لا إنفاق مؤكد.', 'No confirmed spending.')),
          for (final e in d.spendByType.entries)
            Text('${e.key}: ${formatMinor(e.value)}'),
          const SizedBox(height: 8),
          Text(t(context, 'مقارنة المحافظ', 'Wallet comparison'),
              style: Theme.of(context).textTheme.titleSmall),
          for (final w in d.wallets)
            Text(
                '${w.provider}: ${t(context, 'دخل', 'in')} ${formatMinor(w.totals.confirmedInMinor)} · '
                '${t(context, 'خرج', 'out')} ${formatMinor(w.totals.confirmedOutMinor)} · '
                '${t(context, 'معلّق', 'pending')} ${formatMinor(w.totals.pendingInMinor + w.totals.pendingOutMinor)}'),
        ]),
      ),
    );
  }
}

/// One wallet: provider, number, nickname, confirmed balance, last activity
/// and its own history.
class WalletScreen extends StatefulWidget {
  final WalletSummary summary;
  const WalletScreen({super.key, required this.summary});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  List<Map<String, Object?>> _rows = [];

  @override
  void initState() {
    super.initState();
    () async {
      final r = await (await TxDb.summary())
          .latest(walletId: widget.summary.walletId, limit: 100);
      if (mounted) setState(() => _rows = r);
    }();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.summary;
    final t = reviewText;
    return Scaffold(
      appBar: AppBar(
          title: Text(
              '${w.provider}${w.nickname.isEmpty ? '' : ' · ${w.nickname}'}')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: Text(t(context, 'تسجيل معاملة', 'Add transaction')),
        onPressed: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AddTransactionScreen())),
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (w.phone.isNotEmpty) Text(w.phone),
        Text(
            '${t(context, 'الرصيد المؤكد', 'Confirmed balance')}: '
            '${w.totals.confirmedBalanceMinor == null ? '—' : formatMinor(w.totals.confirmedBalanceMinor!)}',
            style: Theme.of(context).textTheme.titleLarge),
        Text(
            '${t(context, 'معلّق وارد', 'Pending in')}: ${formatMinor(w.totals.pendingInMinor)}   '
            '${t(context, 'معلّق صادر', 'Pending out')}: ${formatMinor(w.totals.pendingOutMinor)}'),
        if (w.totals.lastTs != null)
          Text('${t(context, 'آخر نشاط', 'Last activity')}: '
              '${DateTime.fromMillisecondsSinceEpoch(w.totals.lastTs!).toString().substring(0, 16)}'),
        OutlinedButton.icon(
          icon: const Icon(Icons.account_balance_wallet_outlined),
          label:
              Text(t(context, 'ضبط الرصيد الابتدائي', 'Set starting balance')),
          onPressed: () async {
            final c = TextEditingController();
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(reviewText(ctx, 'الرصيد الفعلي للمحفظة الآن',
                    'Actual wallet balance today')),
                content: TextField(
                    controller: c,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                        labelText: reviewText(ctx, 'الرصيد', 'Balance'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(reviewText(ctx, 'إلغاء', 'Cancel'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(reviewText(ctx, 'حفظ', 'Save'))),
                ],
              ),
            );
            final minor = ok == true ? parseMinor(c.text) : null;
            if (minor == null) return;
            final now = DateTime.now();
            final day =
                '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
            await (await TxDb.wallets()).setOpening(w.walletId, minor, day);
            if (context.mounted) Navigator.pop(context);
          },
        ),
        const Divider(),
        for (final r in _rows)
          TxTile(
              row: r,
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => TxDetailScreen(txId: r['id']! as int)))),
      ]),
    );
  }
}
