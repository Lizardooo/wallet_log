import 'package:flutter/material.dart';

import 'db.dart';
import 'gemini.dart';
import 'logic.dart';
import 'parser.dart';

const _green = Color(0xFF0F766E);
const _red = Color(0xFFC62828);
const _orange = Color(0xFFE65100);

/// Gemini settings and the "classify my messages" action.
class AiTab extends StatefulWidget {
  final List<Tx> txs;
  final Future<void> Function() onChanged;

  const AiTab({super.key, required this.txs, required this.onChanged});

  @override
  State<AiTab> createState() => _AiTabState();
}

class _AiTabState extends State<AiTab> {
  static const _batch = 10;

  final _key = TextEditingController();
  List<GeminiModel> _models = const [];
  String? _model;
  bool _hideKey = true;
  bool _loadingModels = false;
  bool _showAll = false;
  bool _loaded = false;
  String? _error;

  bool _running = false;
  int _done = 0;
  int _total = 0;
  int _applied = 0;
  int _kept = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final s = await TxDb.allSettings();
    if (!mounted) return;
    setState(() {
      _key.text = s[TxDb.settingsApiKey] ?? '';
      _model = s[TxDb.settingsModel];
      _loaded = true;
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _fetchModels({bool silent = false}) async {
    if (_loadingModels) return;
    if (_key.text.trim().isEmpty) {
      _snack('أدخل مفتاح Gemini أولاً');
      return;
    }
    setState(() {
      _loadingModels = true;
      if (!silent) _error = null;
    });
    try {
      final list = await listGeminiModels(_key.text);
      if (!mounted) return;
      setState(() {
        _models = list;
        _error = null;
        final ids = list.map((m) => m.id).toSet();
        if (_model == null || !ids.contains(_model)) {
          final free = list.where((m) => m.free).toList();
          _model = (free.isNotEmpty ? free.first : list.first).id;
        }
      });
      await TxDb.setSetting(TxDb.settingsApiKey, _key.text.trim());
      if (_model != null) await TxDb.setSetting(TxDb.settingsModel, _model!);
    } on GeminiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذر جلب الموديلات: $e');
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _pickModel(String id) async {
    setState(() => _model = id);
    await TxDb.setSetting(TxDb.settingsModel, id);
  }

  List<Tx> get _unclear => widget.txs
      .where((t) => t.review || t.isUnknown || t.type == TxType.other)
      .toList();

  Future<void> _run({required bool onlyUnclear}) async {
    final key = _key.text.trim();
    final model = _model;
    if (key.isEmpty) {
      _snack('أدخل مفتاح Gemini أولاً');
      return;
    }
    if (model == null) {
      _snack('اضغط "جلب الموديلات" واختر موديلاً');
      return;
    }
    final targets = onlyUnclear ? _unclear : widget.txs;
    if (targets.isEmpty) {
      _snack('لا توجد رسائل لتصنيفها');
      return;
    }

    setState(() {
      _running = true;
      _error = null;
      _done = 0;
      _total = targets.length;
      _applied = 0;
      _kept = 0;
    });

    var applied = 0;
    var kept = 0;
    try {
      for (var i = 0; i < targets.length; i += _batch) {
        final chunk = targets.skip(i).take(_batch).toList();
        final items = [
          for (final t in chunk)
            AiItem(
              id: t.id,
              wallet: t.wallet,
              amount: fmt(t.amount),
              guess: '${t.type.label} / ${t.dir.label}',
              body: t.body,
            ),
        ];
        final res = await classifyMessages(
          apiKey: key,
          model: model,
          items: items,
        );
        final updates = <AiUpdate>[];
        for (final r in res) {
          final confident = r.confidence >= 0.6 &&
              r.dir != Dir.unknown &&
              r.type != TxType.other;
          updates.add(AiUpdate(
            id: r.id,
            type: r.type,
            dir: r.dir,
            confirm: confident,
            note: r.reason,
          ));
          if (confident) {
            applied++;
          } else {
            kept++;
          }
        }
        await TxDb.applyAiUpdates(updates);
        await widget.onChanged();
        if (!mounted) return;
        setState(() {
          _done += chunk.length;
          _applied = applied;
          _kept = kept;
        });
      }
    } on GeminiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'توقف التصنيف: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unclear = _unclear.length;
    final all = widget.txs.length;
    final shown = _showAll ? _models : _models.where((m) => m.free).toList();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.auto_awesome, size: 20, color: _green),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'محلل مالي بالذكاء الاصطناعي',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'أضف مفتاح Gemini من Google AI Studio. التطبيق يجيب الموديلات '
                  'المجانية المتاحة لمفتاحك وتختار واحد، ثم يقرأ الرسائل ويصنفها '
                  '(تحويل، إيداع، رسوم، فاتورة...) كمحلل مالي خبير ويشرح سبب كل '
                  'تصنيف.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 6),
                const SelectableText(
                  'https://aistudio.google.com/apikey',
                  style: TextStyle(fontSize: 11, color: _green),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _key,
                  obscureText: _hideKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Gemini API key',
                    hintText: 'AIza...',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: Icon(
                          _hideKey ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => _hideKey = !_hideKey),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed:
                          _loadingModels ? null : () => _fetchModels(),
                      icon: _loadingModels
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download),
                      label: const Text('جلب الموديلات المجانية'),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: _red, fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_models.isNotEmpty)
          Card(
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.memory, size: 20),
                  title: Text(
                    _model == null ? 'اختر موديلاً' : 'الموديل: $_model',
                    style: const TextStyle(fontSize: 13),
                  ),
                  trailing: TextButton(
                    onPressed: () => setState(() => _showAll = !_showAll),
                    child: Text(_showAll ? 'المجاني فقط' : 'عرض الكل'),
                  ),
                ),
                const Divider(height: 1),
                if (shown.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'لا يوجد موديل مجاني في قائمة مفتاحك. اضغط "عرض الكل".',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                for (final m in shown)
                  ListTile(
                    dense: true,
                    selected: _model == m.id,
                    leading: Icon(
                      _model == m.id
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: _model == m.id ? _green : null,
                      size: 20,
                    ),
                    onTap: () => _pickModel(m.id),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            m.displayName,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        if (m.free)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFD7EBE9),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text(
                              'مجاني',
                              style: TextStyle(fontSize: 10, color: _green),
                            ),
                          ),
                      ],
                    ),
                    subtitle: Text(m.id,
                        style: const TextStyle(fontSize: 11)),
                  ),
              ],
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'تصنيف الرسائل',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  'إجمالي الرسائل: $all · تحتاج توضيح: $unclear',
                  style: const TextStyle(fontSize: 12),
                ),
                Text(
                  'الموديل: ${_model ?? 'لم يتم اختيار موديل بعد'}',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 4),
                const Text(
                  'الرسائل الغامضة هي اللي محتاجة مراجعة أو اتجاهها غير محدد. '
                  'التصنيف بيشتغل على الرسائل دي فقط لتوفير حصة الاستخدام المجانية.',
                  style: TextStyle(fontSize: 11),
                ),
                const SizedBox(height: 10),
                if (!_loaded)
                  const LinearProgressIndicator()
                else if (_running) ...[
                  LinearProgressIndicator(
                    value: _total == 0 ? null : _done / _total,
                  ),
                  const SizedBox(height: 6),
                  Text('تم إرسال $_done من $_total رسالة...',
                      style: const TextStyle(fontSize: 12)),
                ] else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed:
                            unclear == 0 ? null : () => _run(onlyUnclear: true),
                        icon: const Icon(Icons.auto_fix_high, size: 18),
                        label: Text('تصنيف الغامضة ($unclear)'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            all == 0 ? null : () => _run(onlyUnclear: false),
                        icon: const Icon(Icons.done_all, size: 18),
                        label: Text('تصنيف الكل ($all)'),
                      ),
                    ],
                  ),
                if (_applied > 0 || _kept > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'تم احتساب $_applied رسالة'
                      '${_kept > 0 ? ' · $_kept رسالة تحتاج تأكيدك' : ''}.',
                      style: const TextStyle(color: _green, fontSize: 12),
                    ),
                  ),
                if (_applied > 0 || _kept > 0)
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'التصنيفات المنخفضة الثقة تبقى في "تحتاج مراجعة" حتى '
                      'تفتحها وتؤكدها، فمافيش مبلغ بيتحسب بالغلط.',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'عند تشغيل التصنيف تُرسل نصوص الرسائل إلى Google Gemini. '
                  'يمكنك التصنيف بدون إنترنت في أي وقت من تبويب المعاملات.',
                  style: TextStyle(fontSize: 10, color: _orange),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
