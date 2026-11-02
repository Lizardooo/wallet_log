import 'package:flutter/material.dart';
import 'db.dart';
import 'exclusions.dart';
import 'logic.dart';
import 'review_strings.dart';

enum ReviewBucket { pending, deferred, ignored, duplicate, rules }

class ReviewTab extends StatefulWidget {
  final List<Tx> txs;
  final List<Account> accounts;
  final List<ExclusionRule> rules;
  final Future<void> Function(Tx) onOpen;
  final Future<void> Function(Tx) onExclude;
  final Future<void> Function(Tx) onRestore;
  final Future<void> Function(ExclusionRule) onDeleteRule;
  const ReviewTab(
      {super.key,
      required this.txs,
      required this.accounts,
      required this.rules,
      required this.onOpen,
      required this.onExclude,
      required this.onRestore,
      required this.onDeleteRule});
  @override
  State<ReviewTab> createState() => _ReviewTabState();
}

class _ReviewTabState extends State<ReviewTab> {
  ReviewBucket _bucket = ReviewBucket.pending;
  String _search = '';
  int? _accountId;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant ReviewTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_accountId != null && !widget.accounts.any((a) => a.id == _accountId)) {
      _accountId = null;
    }
  }

  bool _inBucket(Tx t, ReviewBucket bucket) => switch (bucket) {
        ReviewBucket.pending => !t.isExcluded && (t.review || t.isUnknown),
        ReviewBucket.deferred => t.disposition == TxDisposition.deferred,
        ReviewBucket.ignored => t.disposition == TxDisposition.ignored,
        ReviewBucket.duplicate => t.disposition == TxDisposition.duplicate,
        ReviewBucket.rules => false,
      };
  String _label(ReviewBucket bucket) => switch (bucket) {
        ReviewBucket.pending =>
          reviewText(context, 'تحتاج مراجعة', 'Needs review'),
        ReviewBucket.deferred =>
          dispositionLabel(context, TxDisposition.deferred),
        ReviewBucket.ignored =>
          dispositionLabel(context, TxDisposition.ignored),
        ReviewBucket.duplicate =>
          dispositionLabel(context, TxDisposition.duplicate),
        ReviewBucket.rules =>
          reviewText(context, 'قواعد التجاهل', 'Ignore rules'),
      };

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(reviewText(
                context,
                'تعذر حفظ التغيير. حاول مرة أخرى.',
                'Could not save the change. Please retry.'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(ExclusionRule rule) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(
                  reviewText(ctx, 'حذف قاعدة التجاهل؟', 'Delete ignore rule?')),
              content: Text(reviewText(
                  ctx,
                  'الرسائل التي كانت مستبعدة بهذه القاعدة تعود للمراجعة لا للاحتساب. الرسائل المستبعدة يدويًا تبقى مستبعدة، وقد تظل قواعد أخرى منطبقة.',
                  'Messages excluded by this rule return to review, not accounting. Manually excluded messages stay excluded, and other rules may still apply.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(reviewText(ctx, 'إلغاء', 'Cancel'))),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(reviewText(ctx, 'حذف', 'Delete'))),
              ],
            ));
    if (confirm == true) await _run(() => widget.onDeleteRule(rule));
  }

  @override
  Widget build(BuildContext context) {
    final query = normalizeExclusionText(_search);
    final scoped = widget.txs
        .where((t) =>
            (_accountId == null ||
                accountFor(t, widget.accounts)?.id == _accountId) &&
            (query.isEmpty ||
                normalizeExclusionText('${t.body} ${t.note} ${t.party ?? ''}')
                    .contains(query)))
        .toList();
    final rows = scoped.where((t) => _inBucket(t, _bucket)).toList();
    final rules = widget.rules
        .where((r) =>
            query.isEmpty ||
            normalizeExclusionText('${r.text} ${r.wallet}').contains(query))
        .toList();
    return Center(
        child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 960),
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Text(reviewText(
            context,
            'رسايل التطبيق مش متأكد منها. افتح الرسالة وأكّدها عشان تتحسب، أو استبعدها.',
            'Messages the app is not sure about. Open one and confirm it to count it, or exclude it.')),
        const SizedBox(height: 12),
        DropdownButtonFormField<ReviewBucket>(
          initialValue: _bucket,
          isExpanded: true,
          decoration: InputDecoration(
              labelText: reviewText(context, 'القائمة', 'View'),
              border: const OutlineInputBorder()),
          items: [
            for (final bucket in ReviewBucket.values)
              DropdownMenuItem(
                  value: bucket,
                  child: Text(
                      '${_label(bucket)} (${bucket == ReviewBucket.rules ? widget.rules.length : scoped.where((t) => _inBucket(t, bucket)).length})'))
          ],
          onChanged: (value) {
            if (value != null) setState(() => _bucket = value);
          },
        ),
        const SizedBox(height: 12),
        TextField(
          decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              labelText:
                  reviewText(context, 'بحث في النصوص', 'Search messages'),
              border: const OutlineInputBorder()),
          onChanged: (value) => setState(() => _search = value),
        ),
        if (widget.accounts.isNotEmpty && _bucket != ReviewBucket.rules) ...[
          const SizedBox(height: 12),
          InputDecorator(
              decoration: InputDecoration(
                  labelText: reviewText(context, 'المحفظة', 'Wallet'),
                  border: const OutlineInputBorder()),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int?>(
                    value: _accountId,
                    isExpanded: true,
                    items: [
                      DropdownMenuItem<int?>(
                          value: null,
                          child: Text(reviewText(
                              context, 'كل المحافظ', 'All wallets'))),
                      for (final a in widget.accounts)
                        if (a.id != null)
                          DropdownMenuItem<int?>(
                              value: a.id,
                              child: Text(accountLabel(a),
                                  overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (value) => setState(() => _accountId = value)),
              )),
        ],
        if (_busy)
          const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator()),
        const SizedBox(height: 12),
        if (_bucket == ReviewBucket.rules) ...[
          Text(reviewText(
              context,
              'القواعد تخص نوع المحفظة وتطبّق على الرسائل السابقة والجديدة. الرسالة المستعادة يدويًا مستثناة من القواعد.',
              'Rules apply to past and new messages for the same wallet type. Individually restored messages are exempt.')),
          for (final rule in rules)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(rule.wallet.isEmpty
                              ? reviewText(context, 'كل المحافظ', 'All wallets')
                              : rule.wallet),
                          Text(switch (rule.match) {
                            ExclusionMatch.exact => reviewText(
                                context, 'مطابقة النص الكامل', 'Exact text'),
                            ExclusionMatch.contains => reviewText(
                                context, 'يحتوي على العبارة', 'Contains phrase'),
                            ExclusionMatch.template => reviewText(
                                context,
                                'نفس النص (الأرقام بتتغير) · رسايل المراجعة بس',
                                'Same text, any numbers · waiting messages only'),
                          }),
                          const SizedBox(height: 8),
                          SelectableText(rule.text),
                          Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: TextButton.icon(
                                  onPressed: _busy ? null : () => _delete(rule),
                                  icon: const Icon(Icons.delete_outline),
                                  label: Text(reviewText(
                                      context, 'حذف القاعدة', 'Delete rule')))),
                        ]))),
          if (rules.isEmpty)
            Text(reviewText(
                context, 'لا توجد قواعد مطابقة', 'No matching rules')),
        ] else ...[
          if (rows.isEmpty)
            Text(reviewText(context, 'لا توجد رسائل في هذه القائمة',
                'No messages in this view')),
          for (final t in rows)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('${t.wallet} · ${dayKeyTs(t.ts)}',
                              style: Theme.of(context).textTheme.labelLarge),
                          const SizedBox(height: 6),
                          Text(t.body,
                              maxLines: 4, overflow: TextOverflow.ellipsis),
                          if (t.exclusionRuleId != null)
                            Text(reviewText(context, 'مستبعد بقاعدة نص',
                                'Excluded by a text rule')),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            OutlinedButton(
                                onPressed: _busy
                                    ? null
                                    : () => _run(() => widget.onOpen(t)),
                                child: Text(reviewText(
                                    context, 'فتح الرسالة', 'Open message'))),
                            if (t.isExcluded)
                              FilledButton.tonal(
                                  onPressed: _busy
                                      ? null
                                      : () => _run(() => widget.onRestore(t)),
                                  child: Text(reviewText(context,
                                      'إعادة للمراجعة', 'Restore to review')))
                            else
                              TextButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _run(() => widget.onExclude(t)),
                                  icon: const Icon(Icons.block),
                                  label: Text(reviewText(
                                      context, 'استبعاد', 'Exclude'))),
                          ]),
                        ]))),
        ],
      ]),
    ));
  }
}
