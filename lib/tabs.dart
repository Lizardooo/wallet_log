import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'db.dart';
import 'importer.dart';
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
      TxType.deduction => Icons.remove_circle_outline,
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
  final bool confirm; // false = only the note was saved

  const TxEdit(this.note, this.type, this.dir, this.confirm);
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
                  '⚠ هذه العملية غير محسوبة في الداخل والخارج حتى تراجعها. قارنها بنص الرسالة، اختر النوع والاتجاه الصحيحين، ثم اضغط "تأكيد واحتساب".',
                  style: TextStyle(color: _orange, fontSize: 12),
                ),
              if (mismatch != null)
                Text(
                  '⚠ الرصيد المكتوب في الرسالة لا يطابق الحساب (فرق ${fmt(mismatch)}). قد تكون هناك رسالة ناقصة أو محذوفة.',
                  style: const TextStyle(color: _red, fontSize: 12),
                ),
              if (t.ai)
                Text(
                  '🤖 تحليل الموديل: ${t.aiNote.isEmpty ? 'بدون تفصيل' : t.aiNote}',
                  style: const TextStyle(color: _green, fontSize: 12),
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
          if (t.review)
            OutlinedButton(
              onPressed: () => Navigator.pop(
                  ctx, TxEdit(c.text.trim(), t.type, t.dir, false)),
              child: const Text('حفظ الملاحظة فقط'),
            ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, TxEdit(c.text.trim(), type, dir, true)),
            child: Text(t.review ? 'تأكيد واحتساب' : 'حفظ'),
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
                    slot: existing?.slot,
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

class TransactionsTab extends StatefulWidget {
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

  @override
  State<TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<TransactionsTab> {
  Dir? _dir; // null = all, inFlow = incoming only, outFlow = outgoing only
  bool _review = false;

  TxFilter get _f => widget.filter;

  void _apply(VoidCallback change) {
    change();
    widget.onChanged();
    if (mounted) setState(() {});
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  bool _isRange(DateTime from, DateTime to) {
    final f = _f.from;
    final t = _f.to;
    return f != null && t != null && _day(f) == _day(from) && _day(t) == _day(to);
  }

  int get _activeFilters =>
      (_f.accountId != null ? 1 : 0) +
      (_f.types.isNotEmpty ? 1 : 0) +
      ((_f.from != null || _f.to != null) ? 1 : 0);

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final f = _f.from;
    final e = _f.to;
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: _day(now),
      initialDateRange:
          (f != null && e != null) ? DateTimeRange(start: f, end: e) : null,
    );
    if (r != null) {
      _apply(() {
        _f.from = r.start;
        _f.to = r.end;
      });
    }
  }

  void _openFilters() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          void change(VoidCallback c) {
            _apply(c);
            setSheet(() {});
          }

          final now = DateTime.now();
          final today = _day(now);
          final yesterday = DateTime(today.year, today.month, today.day - 1);
          final week = DateTime(today.year, today.month, today.day - 6);
          final month = DateTime(now.year, now.month);
          final noRange = _f.from == null && _f.to == null;
          final custom = !noRange &&
              !_isRange(today, today) &&
              !_isRange(yesterday, yesterday) &&
              !_isRange(week, today) &&
              !_isRange(month, today);
          final presentTypes = TxType.values
              .where((ty) => widget.txs.any((t) => t.type == ty))
              .toList();

          Widget title(String s) => Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 6),
                child: Text(s,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13)),
              );

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('تصفية المعاملات',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16)),
                      ),
                      if (_activeFilters > 0)
                        TextButton(
                          onPressed: () => change(() {
                            _f.accountId = null;
                            _f.types.clear();
                            _f.from = null;
                            _f.to = null;
                          }),
                          child: const Text('مسح الكل'),
                        ),
                    ],
                  ),
                  if (widget.accounts.isNotEmpty) ...[
                    title('الرقم'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        ChoiceChip(
                          label: const Text('الكل'),
                          selected: _f.accountId == null,
                          onSelected: (_) => change(() => _f.accountId = null),
                        ),
                        for (final a in widget.accounts)
                          ChoiceChip(
                            label: Text(a.name),
                            selected: _f.accountId == a.id,
                            onSelected: (_) =>
                                change(() => _f.accountId = a.id),
                          ),
                      ],
                    ),
                  ],
                  title('الفترة'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      ChoiceChip(
                        label: const Text('الكل'),
                        selected: noRange,
                        onSelected: (_) => change(() {
                          _f.from = null;
                          _f.to = null;
                        }),
                      ),
                      ChoiceChip(
                        label: const Text('اليوم'),
                        selected: _isRange(today, today),
                        onSelected: (_) => change(() {
                          _f.from = today;
                          _f.to = today;
                        }),
                      ),
                      ChoiceChip(
                        label: const Text('أمس'),
                        selected: _isRange(yesterday, yesterday),
                        onSelected: (_) => change(() {
                          _f.from = yesterday;
                          _f.to = yesterday;
                        }),
                      ),
                      ChoiceChip(
                        label: const Text('7 أيام'),
                        selected: _isRange(week, today),
                        onSelected: (_) => change(() {
                          _f.from = week;
                          _f.to = today;
                        }),
                      ),
                      ChoiceChip(
                        label: const Text('هذا الشهر'),
                        selected: _isRange(month, today),
                        onSelected: (_) => change(() {
                          _f.from = month;
                          _f.to = today;
                        }),
                      ),
                      ChoiceChip(
                        avatar: const Icon(Icons.edit_calendar, size: 16),
                        label: Text(custom
                            ? '${_f.from != null ? dayKey(_f.from!) : '...'} ← ${_f.to != null ? dayKey(_f.to!) : '...'}'
                            : 'نطاق محدد'),
                        selected: custom,
                        onSelected: (_) async {
                          await _pickRange();
                          setSheet(() {});
                        },
                      ),
                    ],
                  ),
                  if (presentTypes.isNotEmpty) ...[
                    title('نوع العملية'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final ty in presentTypes)
                          FilterChip(
                            avatar: Icon(typeIcon(ty), size: 16),
                            label: Text(ty.label),
                            selected: _f.types.contains(ty),
                            onSelected: (v) => change(() {
                              if (v) {
                                _f.types.add(ty);
                              } else {
                                _f.types.remove(ty);
                              }
                            }),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(sheetCtx).pop(),
                      child: const Text('عرض النتائج'),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Rows that need the owner's attention: not counted yet, or without a
  /// direction. They live in their own view so the main list stays clean.
  bool _needsReview(Tx t) => t.review || t.isUnknown;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final matched =
        widget.txs.where((t) => _f.matches(t, widget.accounts)).toList();
    final reviewList = matched.where(_needsReview).toList();
    final confirmed = matched.where((t) => !_needsReview(t)).toList();
    final shown = _dir == null
        ? confirmed
        : confirmed.where((t) => t.dir == _dir).toList();
    final totals = totalsOf(confirmed);

    final list = _review ? reviewList : shown;
    final groups = <String, List<Tx>>{};
    for (final t in list) {
      groups.putIfAbsent(dayKeyTs(t.ts), () => []).add(t);
    }
    final items = <Object>[];
    groups.forEach((day, l) {
      items.add(_DayHeader(day, totalsOf(l)));
      items.addAll(l);
    });

    final toolbar = Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: _review
          ? Row(
              children: [
                IconButton(
                  tooltip: 'رجوع',
                  onPressed: () => setState(() => _review = false),
                  icon: const Icon(Icons.arrow_forward),
                ),
                Expanded(
                  child: Text('تحتاج مراجعة (${reviewList.length})',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ],
            )
          : Row(
              children: [
                Expanded(
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    segments: const [
                      ButtonSegment(value: 0, label: Text('الكل')),
                      ButtonSegment(value: 1, label: Text('داخل')),
                      ButtonSegment(value: 2, label: Text('خارج')),
                    ],
                    selected: {
                      _dir == null ? 0 : (_dir == Dir.inFlow ? 1 : 2),
                    },
                    onSelectionChanged: (s) => setState(() {
                      final v = s.first;
                      _dir = v == 0
                          ? null
                          : (v == 1 ? Dir.inFlow : Dir.outFlow);
                    }),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  tooltip: 'تصفية',
                  onPressed: _openFilters,
                  icon: Badge(
                    isLabelVisible: _activeFilters > 0,
                    label: Text('$_activeFilters'),
                    child: const Icon(Icons.tune),
                  ),
                ),
                if (reviewList.isNotEmpty)
                  IconButton.filledTonal(
                    tooltip: 'تحتاج مراجعة',
                    onPressed: () => setState(() => _review = true),
                    icon: Badge(
                      label: Text('${reviewList.length}'),
                      child: const Icon(Icons.rule),
                    ),
                  ),
              ],
            ),
    );

    Widget summaryCell(String label, String value, Color color) => Expanded(
          child: Column(
            children: [
              Text(label,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(value,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: color)),
              ),
            ],
          ),
        );

    final summary = _review
        ? Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _orange.withAlpha(24),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'هذه الرسائل غير محسوبة في الداخل والخارج حتى تؤكدها. اضغط على '
              'أي معاملة لتحديد نوعها واتجاهها، أو صنّفها بالذكاء الاصطناعي '
              'من تبويب "الذكاء".',
              style: TextStyle(fontSize: 12, color: _orange),
            ),
          )
        : Container(
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                summaryCell('داخل', fmt(totals.inSum), _green),
                summaryCell('خارج', fmt(totals.outSum), _red),
                summaryCell('الصافي', fmt(totals.net),
                    totals.net < 0 ? _red : cs.onSurface),
              ],
            ),
          );

    return Column(
      children: [
        toolbar,
        summary,
        Expanded(
          child: items.isEmpty
              ? RefreshIndicator(
                  onRefresh: widget.onRefresh,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 80),
                      Icon(
                        _review ? Icons.verified_outlined : Icons.inbox_outlined,
                        size: 56,
                        color: cs.outline,
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: Text(
                          _review ? 'لا توجد معاملات تحتاج مراجعة' : 'لا توجد معاملات',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: widget.onRefresh,
                  child: ListView.builder(
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: items.length,
                    itemBuilder: (ctx, i) {
                      final it = items[i];
                      if (it is _DayHeader) return _header(context, it);
                      return _tile(context, it as Tx);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, _DayHeader h) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              dayTitle(h.day),
              style: TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 12, color: grey),
            ),
          ),
          if (!_review) ...[
            if (h.totals.inSum > 0)
              Text('+${fmt(h.totals.inSum)}',
                  style: const TextStyle(color: _green, fontSize: 12)),
            if (h.totals.inSum > 0 && h.totals.outSum > 0)
              const SizedBox(width: 10),
            if (h.totals.outSum > 0)
              Text('-${fmt(h.totals.outSum)}',
                  style: const TextStyle(color: _red, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, Tx t) {
    final cs = Theme.of(context).colorScheme;
    final pending = _needsReview(t);
    final color = pending ? _orange : dirColor(t.dir);
    final acc = accountFor(t, widget.accounts);
    final sign = t.isIn ? '+' : (t.isOut ? '-' : '');
    final mm = widget.mismatches[t.id];
    final icon = pending
        ? Icons.help_outline
        : (t.type == TxType.transfer
            ? (t.isIn ? Icons.south_west : Icons.north_east)
            : typeIcon(t.type));
    final sub = <String>[
      t.type.label,
      acc == null ? t.wallet : accountLabel(acc),
      timeOf(t.ts),
    ].join(' · ');
    final small = TextStyle(fontSize: 11, color: cs.onSurfaceVariant);

    return InkWell(
      onTap: () => widget.onTap(t),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: color.withAlpha(30),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.party ?? t.type.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(sub, style: small),
                  if (t.note.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(Icons.sticky_note_2_outlined,
                              size: 12, color: cs.onSurfaceVariant),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(t.note,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: small),
                          ),
                        ],
                      ),
                    ),
                  if (pending)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        t.ai && t.aiNote.isNotEmpty
                            ? '🤖 ${t.aiNote}'
                            : (t.isUnknown
                                ? 'الاتجاه غير محدد · اضغط للتأكيد'
                                : 'غير محسوبة · اضغط للتأكيد'),
                        style: const TextStyle(fontSize: 11, color: _orange),
                      ),
                    ),
                  if (mm != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('⚠ الرصيد لا يطابق (فرق ${fmt(mm)})',
                          style: const TextStyle(fontSize: 11, color: _orange)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$sign${fmt(t.amount)}',
                  style: TextStyle(
                      color: color, fontWeight: FontWeight.bold, fontSize: 15),
                ),
                if (t.fee > 0 && !pending)
                  Text('رسوم ${fmt(t.fee)}', style: small),
                if (t.balance != null)
                  Text('رصيد ${fmt(t.balance!)}', style: small),
              ],
            ),
          ],
        ),
      ),
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
                  d.abs() < 0.005
                      ? 'مطابق للرسائل ✓'
                      : 'فرق عن الرسائل: ${fmt(d)}${r.pending > 0 ? ' (قد يكون بسبب عمليات تحت المراجعة)' : ''}',
                  style: TextStyle(
                    color: d.abs() < 0.005 ? _green : _red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (r.pending > 0 || r.unknown > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '⚠ ${r.pending + r.unknown} معاملة تحتاج مراجعة ولا تدخل في الحساب. راجعها من تبويب المعاملات.',
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
  final Future<void> Function() onChanged;

  const ReportsTab({
    super.key,
    required this.txs,
    required this.accounts,
    required this.onChanged,
  });

  @override
  State<ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<ReportsTab> {
  int _period = 3;
  int? _accountId;
  DateTimeRange? _custom;
  static const _labels = ['اليوم', '7 أيام', '30 يوم', 'هذا الشهر', 'الكل'];
  static const _never = 253402300799000; // year 9999

  Account? _selectedAccount() {
    if (_accountId == null) return null;
    for (final a in widget.accounts) {
      if (a.id == _accountId) return a;
    }
    return null;
  }

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

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  /// Imports a report the owner exported from Excel / Google Sheets. The sheet
  /// and the recognized columns are shown before anything is stored.
  Future<void> _importExcel() async {
    try {
      const group = XTypeGroup(
        label: 'Excel',
        extensions: ['xlsx'],
        mimeTypes: [
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ],
        uniformTypeIdentifiers: ['org.openxmlformats.spreadsheetml.sheet'],
      );
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final workbook = readWorkbook(bytes);
      if (workbook.error != null) {
        _snack(workbook.error!);
        return;
      }
      if (workbook.isEmpty) {
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('لم أجد صفوفاً واضحة'),
              content: Text(
                'قرأت الملف لكن لم أتعرف على صفوف فيها تاريخ ومبلغ.\n'
                'الأعمدة المطلوبة على الأقل: تاريخ + مبلغ، ويفضل كمان: نوع '
                'العملية، الاتجاه، المحفظة، البيان.\n\n'
                'الأعمدة التي كانت في الملف: '
                '${workbook.sheets.map((s) => '${s.name} (${s.columns.join('، ')})').join(' · ')}',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('حسناً'),
                ),
              ],
            ),
          );
        }
        return;
      }
      if (!mounted) return;
      final sheet = await showDialog<SheetImport>(
        context: context,
        builder: (ctx) => _ImportDialog(sheets: workbook.sheets),
      );
      if (sheet == null) return;
      final added =
          await TxDb.importRows(sheet.rows, account: _selectedAccount());
      await widget.onChanged();
      _snack(added == 0
          ? 'كل صفوف "${sheet.name}" موجودة بالفعل، لم يتغير شيء.'
          : 'تم استيراد $added معاملة من "${sheet.name}" إلى التقارير.');
    } catch (e) {
      _snack('تعذر استيراد الملف: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final from = _from();
    final to = _to();
    final periodTxs =
        widget.txs.where((t) => t.ts >= from && t.ts < to).toList();
    final account = _selectedAccount();
    final txs = account == null
        ? periodTxs
        : periodTxs
            .where((t) => accountFor(t, widget.accounts)?.id == account.id)
            .toList();
    final all = totalsOf(txs);
    final stats =
        accountStats(txs, account == null ? widget.accounts : [account]);
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
        if (widget.accounts.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('المحفظة', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: const Text('كل المحافظ'),
                selected: account == null,
                onSelected: (_) => setState(() => _accountId = null),
              ),
              for (final a in widget.accounts)
                if (a.id != null)
                  ChoiceChip(
                    label: Text(accountLabel(a)),
                    selected: account?.id == a.id,
                    onSelected: (_) => setState(() => _accountId = a.id),
                  ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _importExcel,
          icon: const Icon(Icons.upload_file, size: 18),
          label: const Text('استيراد تقرير Excel (.xlsx)'),
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
                if (all.pending > 0 || all.unknown > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '⚠ ${all.pending + all.unknown} معاملة تحتاج مراجعة (${fmt(all.pendingSum)} غير محسوبة)',
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
                  if (e.value.pending > 0)
                    Text(
                      'تحتاج مراجعة: ${e.value.pending} (${fmt(e.value.pendingSum)} غير محسوبة)',
                      style: const TextStyle(color: _orange, fontSize: 12),
                    ),
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
                '${a.slot == null ? '' : ' · شريحة ${a.slot! + 1}'}',
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

// ------------------------------------------------------------- excel import

/// Lets the owner pick a sheet and shows what was understood before importing.
class _ImportDialog extends StatefulWidget {
  final List<SheetImport> sheets;

  const _ImportDialog({required this.sheets});

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    for (var i = 1; i < widget.sheets.length; i++) {
      if (widget.sheets[i].rows.length > widget.sheets[_index].rows.length) {
        _index = i;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sheets[_index];
    return AlertDialog(
      title: const Text('استيراد تقرير Excel'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.sheets.length > 1) ...[
              const Text('الصفحة', style: TextStyle(fontSize: 12)),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < widget.sheets.length; i++)
                    ChoiceChip(
                      label: Text(
                          '${widget.sheets[i].name} (${widget.sheets[i].rows.length})'),
                      selected: _index == i,
                      onSelected: (_) => setState(() => _index = i),
                    ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            Text(
              'الأعمدة: ${s.columns.isEmpty ? 'لم يتم التعرف عليها' : s.columns.join(' · ')}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              '${s.rows.length} صف جاهز من ${s.total}'
              '${s.skipped > 0 ? ' · ${s.skipped} صف مستبعد (رصيد أو صف إجمالي أو بدون مبلغ)' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
            if (s.preview.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  s.preview.join('\n'),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'الصفوف المستوردة تُضاف للمعاملات وتظهر في التقارير حسب تاريخها، '
              'ولا تتأثر بإعادة قراءة الرسائل.',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, s),
          child: Text('استيراد ${s.rows.length}'),
        ),
      ],
    );
  }
}
