import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'db.dart';
import 'logic.dart';
import 'parser.dart';

const smsChannel = MethodChannel('wallet_log/sms');

const walletTypes = [
  'Vodafone Cash',
  'InstaPay',
  'Orange Cash',
  'Etisalat Cash / Fawry',
];

const _weekdays = [
  'الاثنين',
  'الثلاثاء',
  'الأربعاء',
  'الخميس',
  'الجمعة',
  'السبت',
  'الأحد',
];

const _green = Color(0xFF2E7D32);
const _red = Color(0xFFC62828);
const _orange = Color(0xFFE65100);

DateTime parseDay(String key) {
  final p = key.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

String dayTitle(String key) => '${_weekdays[parseDay(key).weekday - 1]}  $key';

String timeOf(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  return '${two(d.hour)}:${two(d.minute)}';
}

double? parseAmount(String s) =>
    double.tryParse(normalizeDigits(s).replaceAll(',', '').trim());

IconData typeIcon(TxType t) => switch (t) {
      TxType.transfer => Icons.swap_horiz,
      TxType.cashIn => Icons.add_card,
      TxType.cashOut => Icons.payments,
      TxType.topup => Icons.phone_android,
      TxType.bill => Icons.receipt_long,
      TxType.payment => Icons.shopping_bag,
      TxType.refund => Icons.undo,
      TxType.fee => Icons.percent,
      TxType.other => Icons.help_outline,
    };

Color dirColor(Dir d) => switch (d) {
      Dir.inFlow => _green,
      Dir.outFlow => _red,
      Dir.unknown => Colors.grey,
    };

Widget statLine(String label, String value, Color? color, {bool bold = false}) {
  final style = TextStyle(
    color: color,
    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
  );
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [Text(label, style: style), Text(value, style: style)],
    ),
  );
}

// ---------------------------------------------------------------- dialogs

Future<double?> askAmount(BuildContext context, String title, double? initial) {
  final c = TextEditingController(text: initial == null ? '' : fmt(initial));
  return showDialog<double>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          suffixText: 'EGP',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () {
            final v = parseAmount(c.text);
            if (v != null) Navigator.pop(ctx, v);
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
}

class TxEdit {
  final String note;
  final TxType type;
  final Dir dir;

  const TxEdit(this.note, this.type, this.dir);
}

/// Shows the original SMS next to the parsed result so the owner can verify it,
/// correct the type / direction and add a remark.
Future<TxEdit?> showTxDialog(BuildContext context, Tx t, double? mismatch) {
  final c = TextEditingController(text: t.note);
  var type = t.type;
  var dir = t.dir;
  return showDialog<TxEdit>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text('${fmt(t.amount)} EGP'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (t.review)
                const Text(
                  '⚠ التطبيق غير متأكد من تصنيف هذه الرسالة. قارنها بنصها الأصلي ثم صحّح النوع والاتجاه.',
                  style: TextStyle(color: _orange, fontSize: 12),
                ),
              if (mismatch != null)
                Text(
                  '⚠ الرصيد المكتوب في الرسالة لا يطابق الحساب (فرق ${fmt(mismatch)}). قد تكون هناك رسالة ناقصة أو محذوفة.',
                  style: const TextStyle(color: _red, fontSize: 12),
                ),
              const SizedBox(height: 8),
              const Text('نص الرسالة',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  t.body,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              const Text('الاتجاه'),
              Wrap(
                spacing: 6,
                children: [
                  for (final d in Dir.values)
                    ChoiceChip(
                      label: Text(d.label),
                      selected: dir == d,
                      onSelected: (_) => setS(() => dir = d),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('النوع'),
              Wrap(
                spacing: 6,
                children: [
                  for (final ty in TxType.values)
                    ChoiceChip(
                      label: Text(ty.label),
                      selected: type == ty,
                      onSelected: (_) => setS(() => type = ty),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(
                  labelText: 'ملاحظة',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, TxEdit(c.text.trim(), type, dir)),
            child: const Text('حفظ'),
          ),
        ],
      ),
    ),
  );
}

/// Asks for today's opening balance of each account in [accounts].
/// Returns the amounts that were filled in, keyed by account id.
Future<Map<int, double>?> showOpeningDialog(
  BuildContext context,
  String day,
  List<Account> accounts,
  Map<int, double?> prefill,
) {
  final controllers = {
    for (final a in accounts)
      a.id!: TextEditingController(
        text: prefill[a.id] == null ? '' : fmt(prefill[a.id]!),
      ),
  };
  return showDialog<Map<int, double>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('رصيد بداية اليوم'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dayTitle(day)),
            const SizedBox(height: 4),
            const Text(
              'الأرقام المعبأة مقترحة من آخر رصيد وصل في الرسائل. عدّلها عند الحاجة.',
              style: TextStyle(fontSize: 12),
            ),
            for (final a in accounts) ...[
              const SizedBox(height: 12),
              TextField(
                controller: controllers[a.id!],
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: accountLabel(a),
                  border: const OutlineInputBorder(),
                  suffixText: 'EGP',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('لاحقاً'),
        ),
        FilledButton(
          onPressed: () {
            final out = <int, double>{};
            controllers.forEach((id, c) {
              final v = parseAmount(c.text);
              if (v != null) out[id] = v;
            });
            Navigator.pop(ctx, out);
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
}

Future<Account?> editAccount(
    BuildContext context, Account? existing, List<Tx> txs) {
  final name = TextEditingController(text: existing?.name ?? '');
  final number = TextEditingController(text: existing?.number ?? '');
  String wallet = existing?.wallet ?? walletTypes.first;
  int? sub = existing?.subId;
  return showDialog<Account>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        final counts = <int, int>{};
        for (final t in txs) {
          final s = t.subId;
          if (t.wallet == wallet && s != null) {
            counts[s] = (counts[s] ?? 0) + 1;
          }
        }
        return AlertDialog(
          title: Text(existing == null ? 'حساب جديد' : 'تعديل الحساب'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'اسم الحساب (مثال: فودافون - هاتف 1)',
                  ),
                ),
                const SizedBox(height: 12),
                const Text('نوع المحفظة'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final w in walletTypes)
                      ChoiceChip(
                        label: Text(w),
                        selected: wallet == w,
                        onSelected: (_) => setS(() {
                          wallet = w;
                          sub = null;
                        }),
                      ),
                  ],
                ),
                TextField(
                  controller: number,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'رقم المحفظة'),
                ),
                if (counts.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('الشريحة (لتمييز رقمين من نفس المحفظة)'),
                  Wrap(
                    spacing: 6,
                    children: [
                      ChoiceChip(
                        label: const Text('غير محدد'),
                        selected: sub == null,
                        onSelected: (_) => setS(() => sub = null),
                      ),
                      for (final e in counts.entries)
                        ChoiceChip(
                          label: Text('شريحة ${e.key} (${e.value} رسالة)'),
                          selected: sub == e.key,
                          onSelected: (_) => setS(() => sub = e.key),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                Navigator.pop(
                  ctx,
                  Account(
                    id: existing?.id,
                    name: name.text.trim(),
                    wallet: wallet,
                    number: normalizeDigits(number.text.trim()),
                    subId: sub,
                  ),
                );
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    ),
  );
}

// ------------------------------------------------------ transactions tab

class _DayHeader {
  final String day;
  final Totals totals;

  const _DayHeader(this.day, this.totals);
}

class TransactionsTab extends StatelessWidget {
  final List<Tx> txs;
  final List<Account> accounts;
  final TxFilter filter;
  final Map<int, double> mismatches;
  final VoidCallback onChanged;
  final void Function(Tx) onTap;
  final Future<void> Function() onRefresh;

  const TransactionsTab({
    super.key,
    required this.txs,
    required this.accounts,
    required this.filter,
    required this.mismatches,
    required this.onChanged,
    required this.onTap,
    required this.onRefresh,
  });

  void _setRange(DateTime? from, DateTime? to) {
    filter.from = from;
    filter.to = to;
    onChanged();
  }

  Future<void> _pickRange(BuildContext context) async {
    final now = DateTime.now();
    final f = filter.from;
    final e = filter.to;
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange:
          (f != null && e != null) ? DateTimeRange(start: f, end: e) : null,
    );
    if (r != null) _setRange(r.start, r.end);
  }

  @override
  Widget build(BuildContext context) {
    final shown = txs.where((t) => filter.matches(t, accounts)).toList();
    final totals = totalsOf(shown);
    final reviewCount = shown.where((t) => t.review).length;
    final mismatchCount = shown.where((t) => mismatches.containsKey(t.id)).length;
    final presentTypes =
        TxType.values.where((ty) => txs.any((t) => t.type == ty)).toList();

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = filter.from;
    final to = filter.to;

    final groups = <String, List<Tx>>{};
    for (final t in shown) {
      groups.putIfAbsent(dayKeyTs(t.ts), () => []).add(t);
    }
    final items = <Object>[];
    groups.forEach((day, list) {
      items.add(_DayHeader(day, totalsOf(list)));
      items.addAll(list);
    });

    Widget chipRow(List<Widget> chips) => SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              for (final c in chips)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: c,
                ),
            ],
          ),
        );

    return Column(
      children: [
        if (accounts.isNotEmpty)
          chipRow([
            ChoiceChip(
              label: const Text('كل الأرقام'),
              selected: filter.accountId == null,
              onSelected: (_) {
                filter.accountId = null;
                onChanged();
              },
            ),
            for (final a in accounts)
              ChoiceChip(
                label: Text(a.name),
                selected: filter.accountId == a.id,
                onSelected: (_) {
                  filter.accountId = a.id;
                  onChanged();
                },
              ),
          ]),
        if (presentTypes.isNotEmpty)
          chipRow([
            for (final ty in presentTypes)
              FilterChip(
                avatar: Icon(typeIcon(ty), size: 16),
                label: Text(ty.label),
                selected: filter.types.contains(ty),
                onSelected: (v) {
                  if (v) {
                    filter.types.add(ty);
                  } else {
                    filter.types.remove(ty);
                  }
                  onChanged();
                },
              ),
          ]),
        chipRow([
          if (from != null || to != null)
            InputChip(
              avatar: const Icon(Icons.date_range, size: 16),
              label: Text(
                from != null && to != null
                    ? '${dayKey(from)} ← ${dayKey(to)}'
                    : '${from != null ? dayKey(from) : '...'} ← ${to != null ? dayKey(to) : '...'}',
              ),
              onDeleted: () => _setRange(null, null),
            ),
          ActionChip(
            label: const Text('اليوم'),
            onPressed: () => _setRange(today, today),
          ),
          ActionChip(
            label: const Text('أمس'),
            onPressed: () {
              final y = DateTime(today.year, today.month, today.day - 1);
              _setRange(y, y);
            },
          ),
          ActionChip(
            label: const Text('7 أيام'),
            onPressed: () => _setRange(
                DateTime(today.year, today.month, today.day - 6), today),
          ),
          ActionChip(
            label: const Text('هذا الشهر'),
            onPressed: () => _setRange(DateTime(now.year, now.month), today),
          ),
          ActionChip(
            avatar: const Icon(Icons.edit_calendar, size: 16),
            label: const Text('نطاق محدد'),
            onPressed: () => _pickRange(context),
          ),
        ]),
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${totals.count} معاملة',
                      style: const TextStyle(fontSize: 12)),
                  Text('داخل ${fmt(totals.inSum)}',
                      style: const TextStyle(color: _green, fontSize: 12)),
                  Text('خارج ${fmt(totals.outSum)}',
                      style: const TextStyle(color: _red, fontSize: 12)),
                  Text('رسوم ${fmt(totals.fee)}',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
              if (reviewCount > 0 || totals.unknown > 0 || mismatchCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    [
                      if (reviewCount > 0) '$reviewCount تحتاج مراجعة',
                      if (totals.unknown > 0)
                        '${totals.unknown} بلا اتجاه (غير محسوبة)',
                      if (mismatchCount > 0) '$mismatchCount رصيدها لا يطابق',
                    ].join(' · '),
                    style: const TextStyle(color: _orange, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('لا توجد معاملات مطابقة'))
              : RefreshIndicator(
                  onRefresh: onRefresh,
                  child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (ctx, i) {
                      final it = items[i];
                      if (it is _DayHeader) return _header(context, it);
                      return _tile(it as Tx);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, _DayHeader h) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              dayTitle(h.day),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Text('داخل ${fmt(h.totals.inSum)}',
              style: const TextStyle(color: _green, fontSize: 12)),
          const SizedBox(width: 10),
          Text('خارج ${fmt(h.totals.outSum)}',
              style: const TextStyle(color: _red, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _tile(Tx t) {
    final color = dirColor(t.dir);
    final acc = accountFor(t, accounts);
    final sign = t.isIn ? '+' : (t.isOut ? '-' : '');
    final mm = mismatches[t.id];
    final lines = <String>[
      '${t.type.label} · ${acc == null ? t.wallet : accountLabel(acc)} · ${timeOf(t.ts)}',
      if (t.party != null) 'الطرف الآخر: ${t.party}',
      if (t.fee > 0) 'رسوم: ${fmt(t.fee)}',
      if (t.note.isNotEmpty) 'ملاحظة: ${t.note}',
      if (t.review) '⚠ راجع التصنيف (اضغط)',
      if (mm != null) '⚠ الرصيد لا يطابق (فرق ${fmt(mm)})',
    ];
    return Column(
      children: [
        ListTile(
          onTap: () => onTap(t),
          leading: Icon(typeIcon(t.type), color: color),
          title: Text(
            '$sign${fmt(t.amount)} EGP${t.isUnknown ? '  (الاتجاه غير محدد)' : ''}',
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
          subtitle: Text(lines.join('\n')),
          isThreeLine: lines.length > 2,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (t.balance != null)
                Text('رصيد ${fmt(t.balance!)}',
                    style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 6),
              Icon(
                t.note.isEmpty ? Icons.edit_note : Icons.sticky_note_2,
                size: 20,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

// -------------------------------------------------------------- daily tab

class DailyTab extends StatefulWidget {
  final List<Tx> txs;
  final List<Account> accounts;
  final Map<String, double> openings;
  final Future<void> Function(int accountId, String day, double amount)
      onSetOpening;

  const DailyTab({
    super.key,
    required this.txs,
    required this.accounts,
    required this.openings,
    required this.onSetOpening,
  });

  @override
  State<DailyTab> createState() => _DailyTabState();
}

class _DailyTabState extends State<DailyTab> {
  DateTime _day = DateTime.now();

  void _shift(int days) {
    setState(() => _day = DateTime(_day.year, _day.month, _day.day + days));
  }

  Future<void> _edit(DayRow r, String key) async {
    final v = await askAmount(context, 'رصيد بداية اليوم\n${r.label}', r.opening);
    if (v != null) await widget.onSetOpening(r.account!.id!, key, v);
  }

  @override
  Widget build(BuildContext context) {
    final key = dayKey(_day);
    final isToday = key == dayKey(DateTime.now());
    if (widget.accounts.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'أضف أرقام محافظك من تبويب "الحسابات" أولاً، ثم سيظهر هنا الداخل والخارج والمتبقي لكل يوم.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final rows = dailyRows(key, widget.txs, widget.accounts, widget.openings);
    double totalIn = 0;
    double totalOut = 0;
    double totalFee = 0;
    double totalLeft = 0;
    var missing = 0;
    for (final r in rows) {
      totalIn += r.inSum;
      totalOut += r.outSum;
      totalFee += r.feeSum;
      final e = r.expected;
      if (e != null) {
        totalLeft += e;
      } else if (r.account != null) {
        missing++;
      }
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: () => _shift(-1),
            ),
            Expanded(
              child: Text(
                dayTitle(key),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.chevron_left),
              onPressed: isToday ? null : () => _shift(1),
            ),
          ],
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                statLine('إجمالي الداخل', fmt(totalIn), _green),
                statLine('إجمالي الخارج', fmt(totalOut), _red),
                statLine('إجمالي الرسوم', fmt(totalFee), null),
                statLine('إجمالي المتبقي المتوقع', fmt(totalLeft), null,
                    bold: true),
                if (missing > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'ينقص الرصيد الافتتاحي لـ $missing حساب',
                      style: const TextStyle(fontSize: 12, color: _red),
                    ),
                  ),
              ],
            ),
          ),
        ),
        for (final r in rows) _card(r, key),
      ],
    );
  }

  Widget _card(DayRow r, String key) {
    final d = r.diff;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.label,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                Text('${r.count} معاملة', style: const TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 6),
            if (r.account != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    r.opening == null
                        ? 'الرصيد الافتتاحي: غير مُدخل'
                        : 'الرصيد الافتتاحي: ${fmt(r.opening!)}'
                            '${r.suggested ? ' (مقترح)' : ''}',
                  ),
                  TextButton(
                    onPressed: () => _edit(r, key),
                    child: Text(r.suggested ? 'تأكيد / تعديل' : 'تعديل'),
                  ),
                ],
              ),
            statLine('الداخل', fmt(r.inSum), _green),
            statLine('الخارج', fmt(r.outSum), _red),
            if (r.feeSum > 0) statLine('الرسوم', fmt(r.feeSum), null),
            if (r.expected != null)
              statLine('المتبقي المتوقع', fmt(r.expected!), null, bold: true),
            if (r.reported != null)
              statLine('آخر رصيد في الرسائل', fmt(r.reported!), null),
            if (d != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  d.abs() < 0.005 ? 'مطابق للرسائل ✓' : 'فرق عن الرسائل: ${fmt(d)}',
                  style: TextStyle(
                    color: d.abs() < 0.005 ? _green : _red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (r.unknown > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '⚠ ${r.unknown} معاملة بلا اتجاه لا تدخل في الحساب. صحّحها من تبويب المعاملات.',
                  style: const TextStyle(color: _orange, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ reports tab

class ReportsTab extends StatefulWidget {
  final List<Tx> txs;
  final List<Account> accounts;

  const ReportsTab({super.key, required this.txs, required this.accounts});

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  int _period = 3;
  DateTimeRange? _custom;
  static const _labels = ['اليوم', '7 أيام', '30 يوم', 'هذا الشهر', 'الكل'];
  static const _never = 253402300799000; // year 9999

  int _from() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_period) {
      case 0:
        return today.millisecondsSinceEpoch;
      case 1:
        return DateTime(today.year, today.month, today.day - 6)
            .millisecondsSinceEpoch;
      case 2:
        return DateTime(today.year, today.month, today.day - 29)
            .millisecondsSinceEpoch;
      case 3:
        return DateTime(now.year, now.month).millisecondsSinceEpoch;
      case 5:
        final c = _custom;
        return c == null ? 0 : c.start.millisecondsSinceEpoch;
      default:
        return 0;
    }
  }

  int _to() {
    final c = _custom;
    if (_period == 5 && c != null) {
      return DateTime(c.end.year, c.end.month, c.end.day + 1)
          .millisecondsSinceEpoch;
    }
    return _never;
  }

  Future<void> _pickCustom() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: _custom,
    );
    if (r != null) {
      setState(() {
        _custom = r;
        _period = 5;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final from = _from();
    final to = _to();
    final txs = widget.txs.where((t) => t.ts >= from && t.ts < to).toList();
    final all = totalsOf(txs);
    final stats = accountStats(txs, widget.accounts);
    final types = typeStats(txs);
    final parties = partyStats(txs);
    final c = _custom;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          spacing: 6,
          children: [
            for (var i = 0; i < _labels.length; i++)
              ChoiceChip(
                label: Text(_labels[i]),
                selected: _period == i,
                onSelected: (_) => setState(() => _period = i),
              ),
            ChoiceChip(
              avatar: const Icon(Icons.edit_calendar, size: 16),
              label: Text(c == null
                  ? 'نطاق محدد'
                  : '${dayKey(c.start)} ← ${dayKey(c.end)}'),
              selected: _period == 5,
              onSelected: (_) => _pickCustom(),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                statLine('عدد المعاملات', '${all.count}', null),
                statLine('إجمالي الداخل', fmt(all.inSum), _green),
                statLine('إجمالي الخارج', fmt(all.outSum), _red),
                statLine('إجمالي الرسوم', fmt(all.fee), null),
                statLine('الصافي', fmt(all.net), null, bold: true),
                if (all.unknown > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '⚠ ${all.unknown} معاملة بلا اتجاه غير محسوبة',
                      style: const TextStyle(fontSize: 12, color: _orange),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text('حسب نوع العملية',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final e in types)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(typeIcon(e.key), size: 18),
                      const SizedBox(width: 6),
                      Text(e.key.label,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  statLine('عدد المعاملات', '${e.value.count}', null),
                  statLine('الداخل', fmt(e.value.inSum), _green),
                  statLine('الخارج', fmt(e.value.outSum), _red),
                  if (e.value.fee > 0) statLine('الرسوم', fmt(e.value.fee), null),
                ],
              ),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text('حسب رقم المحفظة',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        for (final s in stats)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.label,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  statLine('عدد المعاملات', '${s.totals.count}', null),
                  statLine('الداخل', fmt(s.totals.inSum), _green),
                  statLine('الخارج', fmt(s.totals.outSum), _red),
                  statLine('الرسوم', fmt(s.totals.fee), null),
                  statLine('الصافي', fmt(s.totals.net), null, bold: true),
                ],
              ),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text('أكثر الأرقام تعاملاً',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (parties.isEmpty)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('لا توجد أرقام طرف آخر في الرسائل لهذه الفترة'),
          ),
        for (final p in parties.take(15))
          Card(
            child: ListTile(
              title: Text(p.party),
              subtitle: Text(
                '${p.count} معاملة · داخل ${fmt(p.inSum)} · خارج ${fmt(p.outSum)}',
              ),
              trailing: Text(fmt(p.total)),
            ),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------ accounts tab

class AccountsTab extends StatefulWidget {
  final List<Tx> txs;
  final List<Account> accounts;
  final Future<void> Function(Account) onSave;
  final Future<void> Function(int) onDelete;

  const AccountsTab({
    super.key,
    required this.txs,
    required this.accounts,
    required this.onSave,
    required this.onDelete,
  });

  @override
  State<AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends State<AccountsTab> {
  TimeOfDay? _time; // null = reminder off

  @override
  void initState() {
    super.initState();
    _loadReminder();
  }

  Future<void> _loadReminder() async {
    try {
      final r = await smsChannel.invokeMethod<Map<dynamic, dynamic>>('getReminder');
      if (!mounted) return;
      setState(() {
        _time = r == null
            ? null
            : TimeOfDay(hour: r['hour'] as int, minute: r['minute'] as int);
      });
    } catch (_) {}
  }

  Future<void> _setReminder(TimeOfDay? t) async {
    if (t == null) {
      await smsChannel.invokeMethod('cancelDaily');
    } else {
      await smsChannel.invokeMethod('requestNotifPermission');
      await smsChannel
          .invokeMethod('scheduleDaily', {'hour': t.hour, 'minute': t.minute});
    }
    if (mounted) setState(() => _time = t);
  }

  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 9, minute: 0),
    );
    if (t != null) await _setReminder(t);
  }

  Future<void> _edit(Account? a) async {
    final res = await editAccount(context, a, widget.txs);
    if (res != null) await widget.onSave(res);
  }

  Future<void> _confirmDelete(Account a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('حذف ${a.name}؟'),
        content: const Text('سيتم حذف الحساب وأرصدته الافتتاحية. المعاملات نفسها لن تُحذف.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok == true && a.id != null) await widget.onDelete(a.id!);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: SwitchListTile(
            title: const Text('تذكير يومي بالرصيد الافتتاحي'),
            subtitle: Text(
              _time == null
                  ? 'متوقف'
                  : 'يصل إشعار كل يوم الساعة ${two(_time!.hour)}:${two(_time!.minute)}',
            ),
            value: _time != null,
            onChanged: (on) => on
                ? _setReminder(const TimeOfDay(hour: 9, minute: 0))
                : _setReminder(null),
          ),
        ),
        if (_time != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _pickTime,
              icon: const Icon(Icons.access_time),
              label: const Text('تغيير وقت التذكير'),
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 12, 4, 4),
          child: Text('أرقام المحافظ',
              style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        if (widget.accounts.isEmpty)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'أضف كل رقم محفظة تملكه على هذا الهاتف. سيربط التطبيق الرسائل بالرقم حسب نوع المحفظة (وحسب الشريحة إن كان عندك رقمان من نفس النوع).',
            ),
          ),
        for (final a in widget.accounts)
          Card(
            child: ListTile(
              title: Text(a.name),
              subtitle: Text(
                '${a.wallet}${a.number.isEmpty ? '' : ' · ${a.number}'}'
                '${a.subId == null ? '' : ' · شريحة ${a.subId}'}',
              ),
              onTap: () => _edit(a),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDelete(a),
              ),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () => _edit(null),
          icon: const Icon(Icons.add),
          label: const Text('إضافة رقم محفظة'),
        ),
      ],
    );
  }
}
