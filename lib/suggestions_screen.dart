import 'dart:convert';

import 'package:flutter/material.dart';

import 'db.dart';
import 'review_strings.dart';

/// Delayed-SMS matches and Gemini suggestions. Every item shows why it was
/// raised and what disagrees; nothing changes until the owner accepts it.
class SuggestionsScreen extends StatefulWidget {
  const SuggestionsScreen({super.key});

  @override
  State<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _SuggestionsScreenState extends State<SuggestionsScreen> {
  List<Map<String, Object?>> _matches = [], _ai = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await (await TxDb.matches()).pending();
    final a = await (await TxDb.aiSuggestions()).pending();
    if (mounted)
      setState(() {
        _matches = m;
        _ai = a;
      });
  }

  Future<void> _run(Future<void> Function() f) async {
    final msg = ScaffoldMessenger.of(context);
    try {
      await f();
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text('$e')));
    }
    await _load();
  }

  List<String> _list(Object? json) =>
      (jsonDecode(json! as String) as List).cast<String>();

  @override
  Widget build(BuildContext context) {
    final t = reviewText;
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'الاقتراحات', 'Suggestions'))),
      body: (_matches.isEmpty && _ai.isEmpty)
          ? Center(
              child:
                  Text(t(context, 'لا توجد اقتراحات.', 'Nothing to review.')))
          : ListView(padding: const EdgeInsets.all(12), children: [
              for (final m in _matches)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              t(
                                  context,
                                  'رسالة وصلت متأخرة قد تخص معاملة مسجلة يدوياً #${m['manual_tx_id']}',
                                  'A delayed SMS may confirm manual record #${m['manual_tx_id']}'),
                              style: Theme.of(context).textTheme.titleSmall),
                          Text(
                              '${t(context, 'التطابق', 'Why')}: ${_list(m['reasons']).join(', ')}'),
                          if (_list(m['conflicts']).isNotEmpty)
                            Text(
                                '${t(context, 'اختلافات', 'Conflicts')}: ${_list(m['conflicts']).join(', ')}',
                                style: TextStyle(
                                    color:
                                        Theme.of(context).colorScheme.error)),
                          Text(
                              '${t(context, 'الثقة', 'Confidence')}: ${m['score']}'),
                          OverflowBar(children: [
                            TextButton(
                                onPressed: () => _run(() async =>
                                    (await TxDb.matches())
                                        .reject(m['id']! as int)),
                                child: Text(t(context, 'ليست نفس المعاملة',
                                    'Not the same'))),
                            FilledButton(
                                onPressed: () => _run(() async =>
                                    (await TxDb.matches())
                                        .accept(m['id']! as int)),
                                child: Text(t(
                                    context, 'ربط وتأكيد', 'Link & confirm'))),
                          ]),
                        ]),
                  ),
                ),
              for (final a in _ai)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${t(context, 'اقتراح Gemini', 'Gemini suggestion')}: ${a['action']}',
                              style: Theme.of(context).textTheme.titleSmall),
                          Text('${a['reason']}'),
                          Text(
                              '${t(context, 'المعاملة', 'Transaction')} #${a['tx_id']}  ·  '
                              '${((a['confidence'] as num?) ?? 0) * 100 ~/ 1}%'),
                          Text(a['payload'] as String? ?? '',
                              style: Theme.of(context).textTheme.bodySmall),
                          OverflowBar(children: [
                            TextButton(
                                onPressed: () => _run(() async =>
                                    (await TxDb.aiSuggestions())
                                        .dismiss(a['id']! as int)),
                                child: Text(t(context, 'تجاهل', 'Dismiss'))),
                            FilledButton(
                                onPressed: () => _run(() async =>
                                    (await TxDb.aiSuggestions())
                                        .accept(a['id']! as int)),
                                child: Text(t(context, 'قبول', 'Accept'))),
                          ]),
                        ]),
                  ),
                ),
            ]),
    );
  }
}
