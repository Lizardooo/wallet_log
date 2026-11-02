import 'package:flutter/material.dart';
import 'db.dart';
import 'exclusions.dart';
import 'review_strings.dart';

class ExclusionDecision {
  final TxDisposition disposition;
  final ExclusionMatch? match;
  final String? text;

  /// Also exclude waiting messages with the same text (numbers ignored).
  final bool similar;
  const ExclusionDecision(this.disposition,
      {this.match, this.text, this.similar = false});
}

Future<ExclusionDecision?> showExclusionDialog(
  BuildContext context,
  Tx tx,
  List<Tx> messages,
) =>
    showDialog<ExclusionDecision>(
      context: context,
      builder: (_) => _ExclusionDialog(tx: tx, messages: messages),
    );

class _ExclusionDialog extends StatefulWidget {
  final Tx tx;
  final List<Tx> messages;
  const _ExclusionDialog({required this.tx, required this.messages});
  @override
  State<_ExclusionDialog> createState() => _ExclusionDialogState();
}

class _ExclusionDialogState extends State<_ExclusionDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _text;
  TxDisposition _disposition = TxDisposition.ignored;
  bool _future = false;
  bool _similar = true;
  ExclusionMatch _match = ExclusionMatch.exact;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.tx.body);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pattern = normalizeExclusionText(_text.text);
    final matching = pattern.isEmpty
        ? 0
        : widget.messages
            .where((t) =>
                t.wallet == widget.tx.wallet &&
                (_match == ExclusionMatch.exact
                    ? normalizeExclusionText(t.body) == pattern
                    : normalizeExclusionText(t.body).contains(pattern)))
            .length;
    final template = messageTemplate(widget.tx.body);
    final similar = template.isEmpty
        ? 0
        : widget.messages
            .where((t) =>
                t.id != widget.tx.id &&
                !t.isExcluded &&
                (t.review || t.isUnknown) &&
                messageTemplate(t.body) == template)
            .length;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      constraints: const BoxConstraints(maxWidth: 560),
      title: Text(reviewText(
          context, 'استبعاد من الاحتساب', 'Exclude from accounting')),
      content: SingleChildScrollView(
        child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(widget.tx.body),
                const SizedBox(height: 16),
                DropdownButtonFormField<TxDisposition>(
                  initialValue: _disposition,
                  isExpanded: true,
                  decoration: InputDecoration(
                      labelText: reviewText(context, 'السبب', 'Reason')),
                  items: [
                    for (final value in TxDisposition.values)
                      if (value != TxDisposition.active)
                        DropdownMenuItem(
                            value: value,
                            child: Text(dispositionLabel(context, value)))
                  ],
                  onChanged: (value) {
                    if (value != null)
                      setState(() {
                        _disposition = value;
                        if (value != TxDisposition.ignored) _future = false;
                        // A duplicate has the same text as the real message.
                        _similar = value == TxDisposition.ignored;
                      });
                  },
                ),
                SwitchListTile(
                  key: const ValueKey('exclude-similar'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(reviewText(
                      context,
                      'استبعد كل رسايل المراجعة اللي ليها نفس النص',
                      'Also exclude waiting messages with the same text')),
                  subtitle: Text(reviewText(
                      context,
                      'حتى لو الأرقام والمبالغ مختلفة · $similar رسالة دلوقتي، '
                          'وأي رسالة جاية بنفس النص. المعاملات المحسوبة مش بتتأثر.',
                      'Even if numbers and amounts differ · $similar now, and '
                          'any new one like it. Counted transactions are never touched.')),
                  value: _similar,
                  onChanged: template.isEmpty
                      ? null
                      : (v) => setState(() => _similar = v),
                ),
                const SizedBox(height: 8),
                Text(reviewText(
                    context,
                    'لا تُحتسب هذه الرسالة أو رسومها، ولن يعيدها مسح الرسائل أو الذكاء الاصطناعي. يمكنك إعادتها للمراجعة لاحقًا.',
                    'This message and its fees will not count. Rescans and AI cannot reactivate it. You can restore it to review later.')),
                if (_disposition == TxDisposition.ignored) ...[
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(reviewText(
                        context,
                        'تجاهل النص المطابق حاليًا ومستقبلًا',
                        'Ignore matching text now and in future')),
                    value: _future,
                    onChanged: (value) =>
                        setState(() => _future = value ?? false),
                  ),
                  if (_future) ...[
                    DropdownButtonFormField<ExclusionMatch>(
                      initialValue: _match,
                      isExpanded: true,
                      decoration: InputDecoration(
                          labelText: reviewText(
                              context, 'مطابقة النص', 'Text matching')),
                      items: [
                        DropdownMenuItem(
                            value: ExclusionMatch.exact,
                            child: Text(reviewText(
                                context, 'النص الكامل', 'Exact text'))),
                        DropdownMenuItem(
                            value: ExclusionMatch.contains,
                            child: Text(reviewText(context, 'يحتوي على العبارة',
                                'Contains phrase'))),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _match = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _text,
                      minLines: 2,
                      maxLines: 6,
                      decoration: InputDecoration(
                          border: const OutlineInputBorder(),
                          labelText: reviewText(
                              context, 'النص المستبعد', 'Excluded text')),
                      onChanged: (_) => setState(() {}),
                      validator: (value) =>
                          normalizeExclusionText(value ?? '').isEmpty
                              ? reviewText(context, 'أدخل نصًا غير فارغ',
                                  'Enter non-empty text')
                              : null,
                    ),
                    const SizedBox(height: 8),
                    Text(reviewText(
                        context,
                        'المحفظة: ${widget.tx.wallet} · $matching رسالة حالية تطابق النص. لا تُحذف الأرقام والمبالغ من المطابقة تلقائيًا. اختر عبارة مميزة لتجنب استبعاد معاملات حقيقية.',
                        'Wallet: ${widget.tx.wallet} · $matching current messages match. Numbers and amounts are not removed automatically. Choose a distinctive phrase to avoid excluding real transactions.')),
                  ],
                ],
              ],
            )),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(reviewText(context, 'إلغاء', 'Cancel'))),
        FilledButton(
            onPressed: () {
              if (!_form.currentState!.validate()) return;
              Navigator.pop(
                  context,
                  ExclusionDecision(_disposition,
                      match: _future ? _match : null,
                      text: _future ? _text.text : null,
                      similar: _similar && template.isNotEmpty));
            },
            child: Text(reviewText(context, 'استبعاد', 'Exclude'))),
      ],
    );
  }
}

enum ExcludedMessageAction { restore, change }

Future<ExcludedMessageAction?> showExcludedMessage(
        BuildContext context, Tx tx) =>
    showDialog<ExcludedMessageAction>(
        context: context,
        builder: (ctx) => AlertDialog(
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              constraints: const BoxConstraints(maxWidth: 560),
              title: Text(dispositionLabel(ctx, tx.disposition)),
              content: SingleChildScrollView(
                  child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SelectableText(tx.body),
                  if (tx.note.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(tx.note)
                  ],
                  const SizedBox(height: 12),
                  Text(reviewText(
                      ctx,
                      'الإعادة تستثني هذه الرسالة فقط من قواعد النص وتضعها في المراجعة، ولا تحتسبها حتى تؤكدها.',
                      'Restoring exempts only this message from text rules and returns it to review. It will not count until confirmed.')),
                ],
              )),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(reviewText(ctx, 'إغلاق', 'Close'))),
                TextButton(
                    onPressed: () =>
                        Navigator.pop(ctx, ExcludedMessageAction.change),
                    child:
                        Text(reviewText(ctx, 'تغيير السبب', 'Change reason'))),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(ctx, ExcludedMessageAction.restore),
                    child: Text(reviewText(
                        ctx, 'إعادة للمراجعة', 'Restore to review'))),
              ],
            ));
