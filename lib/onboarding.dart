import 'package:flutter/material.dart';

import 'db.dart';
import 'gemini.dart';
import 'phone_numbers.dart';
import 'tabs.dart';

const _green = Color(0xFF0F766E);

class _SimDraft {
  final TextEditingController number;
  final Set<String> wallets = {};
  bool active = false;
  int? subId;
  int? slot;
  String carrier;

  _SimDraft({
    this.subId,
    this.slot,
    this.carrier = '',
    String numberText = '',
  }) : number = TextEditingController(text: numberText);

  /// The number came from the phone itself (not typed).
  bool detected = false;

  bool get selected => active && wallets.isNotEmpty;

  void dispose() => number.dispose();
}

String _shortWallet(String w) => switch (w) {
      'Vodafone Cash' => 'فودافون كاش',
      'Orange Cash' => 'أورنج كاش',
      'InstaPay' => 'إنستاباي',
      _ => 'اتصالات كاش / فوري',
    };

/// Shown once, before the tabs: the owner picks the SIM numbers that carry
/// wallets, enters his own number, then (optionally) the Gemini key so messages
/// can be classified by a model. Finishing goes straight to the reports.
class OnboardingPage extends StatefulWidget {
  final Future<void> Function() onDone;

  const OnboardingPage({super.key, required this.onDone});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _pages = PageController();
  final _key = TextEditingController();
  final _simDrafts = <_SimDraft>[];
  int _step = 0;
  bool _saving = false;
  bool _hideKey = true;

  List<SimSlot> _sims = const [];
  bool _simsLoaded = false;

  bool _loadingModels = false;
  List<GeminiModel> _models = const [];
  String? _model;
  String? _aiError;
  bool _showAllModels = false;

  @override
  void initState() {
    super.initState();
    _loadSims();
  }

  @override
  void dispose() {
    _pages.dispose();
    _key.dispose();
    for (final d in _simDrafts) {
      d.dispose();
    }
    super.dispose();
  }

  Future<void> _loadSims() async {
    var sims = <SimSlot>[];
    try {
      final granted =
          await smsChannel.invokeMethod<bool>('requestPhoneState') ?? false;
      if (granted) {
        final raw =
            await smsChannel.invokeMethod<List<dynamic>>('simInfo') ?? const [];
        for (var i = 0; i < raw.length; i++) {
          final m = Map<String, dynamic>.from(raw[i] as Map);
          final rawSlot = m['slot'] as int?;
          final rawSub = m['subId'] as int?;
          sims.add(SimSlot(
            subId: (rawSub != null && rawSub >= 0) ? rawSub : null,
            slot: (rawSlot == null || rawSlot < 0) ? i : rawSlot,
            carrier: (m['carrier'] as String?) ?? '',
            number: normalizeEgyptPhone((m['number'] as String?) ?? ''),
          ));
        }
      }
    } catch (_) {
      // The wizard still works: the owner can enter the numbers by hand.
    }
    if (!mounted) return;
    setState(() {
      _sims = sims;
      _simsLoaded = true;
      for (final d in _simDrafts) {
        d.dispose();
      }
      _simDrafts.clear();
      if (sims.isEmpty) {
        _simDrafts.add(_SimDraft(slot: 0));
        _simDrafts.add(_SimDraft(slot: 1));
      } else {
        for (final s in sims) {
          _simDrafts.add(_SimDraft(
            subId: s.subId,
            slot: s.slot,
            carrier: s.carrier,
            numberText: s.number,
          )..detected = s.number.isNotEmpty);
        }
      }
    });
  }

  String _autoName(String wallet, _SimDraft d, String number) {
    final w = _shortWallet(wallet);
    if (number.isNotEmpty) return '$w · $number';
    if (d.slot != null) return '$w · شريحة ${d.slot! + 1}';
    return w;
  }

  void _addManualNumber() {
    setState(() => _simDrafts.add(_SimDraft()));
  }

  Future<void> _fetchModels() async {
    if (_loadingModels) return;
    setState(() {
      _loadingModels = true;
      _aiError = null;
    });
    try {
      final list = await listGeminiModels(_key.text);
      if (!mounted) return;
      setState(() {
        _models = list;
        final free = list.where((m) => m.free).toList();
        final pick = free.isNotEmpty ? free.first : list.first;
        _model = pick.id;
      });
    } on GeminiException catch (e) {
      if (mounted) setState(() => _aiError = e.message);
    } catch (e) {
      if (mounted) {
        setState(() => _aiError = 'تعذر جلب الموديلات: $e');
      }
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  Future<void> _finish({bool skipped = false}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      if (!skipped) {
        for (final d in _simDrafts) {
          if (!d.selected) continue;
          final number = normalizeEgyptPhone(d.number.text);
          if (number.isEmpty && d.subId == null) continue;
          for (final wallet in d.wallets) {
            await TxDb.saveAccount(Account(
              name: _autoName(wallet, d, number),
              wallet: wallet,
              number: number,
              subId: d.subId,
              slot: d.slot,
            ));
          }
        }
        final key = _key.text.trim();
        if (key.isNotEmpty) {
          await TxDb.setApiKey(key);
        }
        final model = _model;
        if (model != null && key.isNotEmpty) {
          await TxDb.setSetting(TxDb.settingsModel, model);
        }
      }
      await TxDb.setSetting(TxDb.settingsSetupDone, '1');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    await widget.onDone();
  }

  void _next() {
    if (_step == 0) {
      final chosen = _simDrafts.where((d) => d.active).toList();
      if (chosen.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'اختر رقم واحد على الأقل عليه محفظة، أو اضغط "تخطي" من الأعلى.'),
        ));
        return;
      }
      if (chosen.any((d) => d.wallets.isEmpty)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('اختر نوع المحفظة لكل رقم اخترته.'),
        ));
        return;
      }
      // Every chosen number must be known: the phone often cannot read it
      // from the SIM, and then the owner types it.
      for (final d in chosen) {
        final problem = phoneProblem(d.number.text);
        if (problem == null) continue;
        final where = d.slot == null ? 'الرقم الإضافي' : 'شريحة ${d.slot! + 1}';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(d.number.text.trim().isEmpty
              ? 'الموبايل ما قالناش رقم $where. اكتبه بنفسك في خانة الرقم.'
              : '$where: $problem'),
        ));
        return;
      }
    }
    setState(() => _step++);
    _pages.animateToPage(_step,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  void _back() {
    if (_step == 0) return;
    setState(() => _step--);
    _pages.animateToPage(_step,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_step) {
      0 => 'شرائحك ومحافظك',
      _ => 'الذكاء الاصطناعي',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        automaticallyImplyLeading: false,
        actions: [
          TextButton(
            onPressed: _saving ? null : () => _finish(skipped: true),
            child: const Text('تخطي الآن'),
          ),
        ],
      ),
      body: Column(
        children: [
          LinearProgressIndicator(value: (_step + 1) / 2),
          Expanded(
            child: PageView(
              controller: _pages,
              physics: const NeverScrollableScrollPhysics(),
              children: [_step0(), _step1()],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  if (_step > 0)
                    TextButton.icon(
                      onPressed: _saving ? null : _back,
                      icon: const Icon(Icons.chevron_left),
                      label: const Text('السابق'),
                    ),
                  const Spacer(),
                  if (_step < 1)
                    FilledButton.icon(
                      onPressed: _saving ? null : _next,
                      icon: const Icon(Icons.chevron_right),
                      label: const Text('التالي'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _saving ? null : () => _finish(),
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check),
                      label: const Text('ابدأ · اعرض التقارير'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _step0() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'علّم على كل شريحة عليها محفظة واختار نوعها. التطبيق بيحاول يعرف '
          'رقم الشريحة لوحده، ولو ما عرفش هيطلب منك تكتبه.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        if (!_simsLoaded)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          )
        else if (_sims.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'ما قدرناش نقرا شرايح الموبايل. اكتب رقم كل شريحة عليها محفظة '
              'واختار نوعها.',
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Text('الشرائح المكتشفة:', style: TextStyle(fontSize: 12)),
          ),
        for (var i = 0; i < _simDrafts.length; i++) _simCard(i),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _simsLoaded ? _addManualNumber : null,
          icon: const Icon(Icons.add),
          label: const Text('إضافة رقم آخر'),
        ),
      ],
    );
  }

  Widget _simCard(int index) {
    final d = _simDrafts[index];
    final title = d.slot == null ? 'رقم إضافي' : 'شريحة ${d.slot! + 1}';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sim_card_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      if (d.carrier.isNotEmpty)
                        Text(d.carrier, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
                if (_simDrafts.length > 1)
                  IconButton(
                    tooltip: 'حذف',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      final removed = _simDrafts[index];
                      setState(() => _simDrafts.removeAt(index));
                      WidgetsBinding.instance
                          .addPostFrameCallback((_) => removed.dispose());
                    },
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (!d.detected)
              Container(
                key: ValueKey('sim-missing-$index'),
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.orange.withAlpha(30),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        size: 18, color: Colors.orange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        d.subId == null
                            ? 'اكتب رقم المحفظة هنا.'
                            : 'الموبايل ما قالناش رقم الشريحة دي. لو عليها '
                                'محفظة، اكتب رقمها هنا عشان نربط الرسايل بيه.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            TextField(
              controller: d.number,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'رقم الشريحة / المحفظة',
                hintText: '${carrierPrefix(d.carrier) ?? '01'}xxxxxxxx'
                    '${carrierPrefix(d.carrier) == null ? 'x' : ''}',
                helperText: d.detected ? 'الرقم ده الموبايل عرفه لوحده ✓' : null,
                errorText: d.active && d.number.text.trim().isNotEmpty
                    ? phoneProblem(d.number.text)
                    : null,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (d.subId == null) ...[
              const SizedBox(height: 6),
              const Text('الشريحة (SIM slot)', style: TextStyle(fontSize: 12)),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (var s = 0; s < 2; s++)
                    ChoiceChip(
                      label: Text('شريحة ${s + 1}'),
                      selected: d.slot == s,
                      onSelected: (_) => setState(() => d.slot = s),
                    ),
                  ChoiceChip(
                    label: const Text('غير محدد'),
                    selected: d.slot == null,
                    onSelected: (_) => setState(() => d.slot = null),
                  ),
                ],
              ),
            ],
            InkWell(
              onTap: () => setState(() {
                d.active = !d.active;
                // Guess the wallet from the carrier; the owner can change it.
                if (d.active && d.wallets.isEmpty) {
                  final w = switch (carrierPrefix(d.carrier)) {
                    '010' => 'Vodafone Cash',
                    '012' => 'Orange Cash',
                    _ => null,
                  };
                  if (w != null && walletTypes.contains(w)) d.wallets.add(w);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      d.active
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      color: d.active
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    const SizedBox(width: 4),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('الرقم عليه محفظة / محفظة إلكترونية'),
                          SizedBox(height: 2),
                          Text(
                            'اختر نوع المحفظة أو أكثر اللي بتستقبل رسايلها '
                            'على الرقم ده',
                            style: TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (d.active)
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final w in walletTypes)
                    FilterChip(
                      label: Text(_shortWallet(w)),
                      selected: d.wallets.contains(w),
                      onSelected: (on) => setState(() {
                        if (on) {
                          d.wallets.add(w);
                        } else {
                          d.wallets.remove(w);
                        }
                      }),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _step1() {
    final shown =
        _showAllModels ? _models : _models.where((m) => m.free).toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'تصنيف الرسائل بالذكاء الاصطناعي (اختياري)',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        const Text(
          'أضف مفتاح Gemini من Google AI Studio. التطبيق يجيب قائمة الموديلات '
          'المجانية المتاحة لمفتاحك، وتختار واحد يقرأ الرسائل ويصنفها كمحلل مالي '
          'خبير. تقدر تضيف المفتاح لاحقاً من تبويب "الذكاء".',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _key,
          obscureText: _hideKey,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Gemini API key',
            hintText: 'AIza...',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.key),
            suffixIcon: IconButton(
              icon: Icon(_hideKey ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _hideKey = !_hideKey),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.tonalIcon(
              onPressed: _loadingModels ? null : _fetchModels,
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
        if (_aiError != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _aiError!,
              style: const TextStyle(color: Color(0xFFC62828), fontSize: 12),
            ),
          ),
        if (_models.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('اختر الموديل',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              TextButton(
                onPressed: () =>
                    setState(() => _showAllModels = !_showAllModels),
                child: Text(_showAllModels ? 'المجاني فقط' : 'عرض الكل'),
              ),
            ],
          ),
          if (shown.isEmpty)
            const Text(
              'لا يوجد موديل مجاني في القائمة. اضغط "عرض الكل" لاختيار أي موديل.',
              style: TextStyle(fontSize: 12),
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
              ),
              onTap: () => setState(() => _model = m.id),
              title: Row(
                children: [
                  Expanded(child: Text(m.displayName)),
                  if (m.free)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD7EBE9),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('مجاني',
                          style: TextStyle(fontSize: 10, color: _green)),
                    ),
                ],
              ),
              subtitle: Text(m.id, style: const TextStyle(fontSize: 11)),
            ),
        ],
        const SizedBox(height: 16),
        const Text(
          'ملاحظة: عند تشغيل التصنيف تُرسل نصوص الرسائل إلى Google Gemini. '
          'غير ذلك يبقى كل شيء على الهاتف.',
          style: TextStyle(fontSize: 11),
        ),
      ],
    );
  }
}
