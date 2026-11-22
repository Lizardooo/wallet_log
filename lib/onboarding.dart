import 'package:flutter/material.dart';

import 'db.dart';
import 'gemini.dart';
import 'sim_setup.dart';
import 'tabs.dart';
import 'privacy_disclosures.dart';

const _green = Color(0xFF0F766E);

class _SimDraft {
  final TextEditingController number;
  final Set<String> wallets = {};
  bool active = false;
  int? subId;
  int? slot;
  String carrier;
  String? defaultWallet;

  _SimDraft({
    this.subId,
    this.slot,
    this.carrier = '',
    String numberText = '',
  }) : number = TextEditingController(text: numberText);

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
  final bool simOnly;

  const OnboardingPage({super.key, required this.onDone, this.simOnly = false});

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
  List<Account> _existing = const [];

  bool _loadingModels = false;
  List<GeminiModel> _models = const [];
  String? _model;
  String? _aiError;
  bool _showAllModels = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final discover = await showSimDisclosure(context);
      if (mounted) await _loadSims(discover: discover);
    });
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

  Future<void> _loadSims({bool discover = true}) async {
    var sims = <SimSlot>[];
    try {
      final granted = discover &&
          (await smsChannel.invokeMethod<bool>('requestPhoneState') ?? false);
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
            number: normalizeSimNumber((m['number'] as String?) ?? ''),
          ));
        }
      }
    } catch (_) {
      // The wizard still works: the owner can enter the numbers by hand.
    }
    final existing = widget.simOnly ? await TxDb.accounts() : <Account>[];
    final settings =
        widget.simOnly ? await TxDb.allSettings() : <String, String>{};
    if (!mounted) return;
    setState(() {
      _existing = existing;
      _sims = sims;
      _simsLoaded = true;
      for (final d in _simDrafts) {
        d.dispose();
      }
      _simDrafts.clear();
      if (sims.isEmpty) {
        _simDrafts.add(_SimDraft());
      } else {
        for (final s in sims) {
          _simDrafts.add(_SimDraft(
            subId: s.subId,
            slot: s.slot,
            carrier: s.carrier,
            numberText: s.number,
          ));
        }
      }
      for (final d in _simDrafts) {
        final matches = existing.where((a) => d.subId != null
            ? a.subId == d.subId
            : d.number.text.isNotEmpty && a.number == d.number.text);
        if (matches.isNotEmpty) {
          if (d.number.text.isEmpty) d.number.text = matches.first.number;
          d.active = true;
          d.wallets.addAll(matches.map((a) => a.wallet));
          d.defaultWallet = settings[defaultWalletKey(d.subId, d.number.text)];
          if (!d.wallets.contains(d.defaultWallet)) {
            d.defaultWallet = d.wallets.length == 1 ? d.wallets.single : null;
          }
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
          final number = normalizeSimNumber(d.number.text);
          if (number.isEmpty && d.subId == null) continue;
          for (final wallet in d.wallets) {
            final matches = _existing.where((a) =>
                a.wallet == wallet &&
                ((d.subId != null && a.subId == d.subId) ||
                    a.number == number));
            await TxDb.saveAccount(Account(
              id: matches.length == 1 ? matches.single.id : null,
              name: _autoName(wallet, d, number),
              wallet: wallet,
              number: number,
              subId: d.subId,
              slot: d.slot,
            ));
          }
          // This is a user-selected preference, never an SMS routing rule.
          await TxDb.setSetting(defaultWalletKey(d.subId, number),
              d.defaultWallet ?? d.wallets.single);
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
      final missing =
          chosen.any((d) => normalizeSimNumber(d.number.text).isEmpty);
      if (missing) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('اكتب رقم المحفظة للرقم اللي اخترته.'),
        ));
        return;
      }
      if (chosen.any((d) => d.defaultWallet == null)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('حدد المحفظة الافتراضية لكل رقم اخترته.'),
        ));
        return;
      }
    }
    if (widget.simOnly) {
      _finish();
      return;
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
        toolbarHeight: 72,
        title: Text('إعداد أموالي · $title',
            maxLines: 2, style: const TextStyle(fontSize: 18)),
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
          'اختر الأرقام اللي عليها محافظ أو محافظ إلكترونية. هنقرأ رسايل '
          'المحافظ من الشرائح المختارة ونحسب معاملاتها. لو الرقم مش ظاهر، '
          'اكتبه يدوياً.',
          style: TextStyle(fontSize: 13),
        ),
        if (widget.simOnly)
          const Text(
              'الحسابات الموجودة لا تُحذف من هنا. التعديل أو الحذف من تبويب الحسابات.',
              style: TextStyle(fontSize: 12)),
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
              'لم نقدر نقرأ شرائح الهاتف تلقائياً. اكتب رقم كل شريحة ومحفظتها '
              'يدوياً.',
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
            TextField(
              controller: d.number,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: 'رقم الشريحة / المحفظة',
                hintText: '01xxxxxxxxx',
                helperText: 'راجع الرقم وعدله عند الحاجة، أو اكتبه لو مش ظاهر',
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (d.subId != null && d.number.text.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                    'تم اكتشاف الشريحة، لكن الشبكة لم توفّر رقمها. أدخله يدوياً.',
                    style: TextStyle(fontSize: 12)),
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
              onTap: () => setState(() => d.active = !d.active),
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
                          if (d.wallets.length == 1) d.defaultWallet = w;
                        } else {
                          d.wallets.remove(w);
                          if (d.defaultWallet == w) d.defaultWallet = null;
                        }
                      }),
                    ),
                ],
              ),
            if (d.active && d.wallets.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('${d.hashCode}|${d.defaultWallet}'),
                initialValue: d.defaultWallet,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'المحفظة الافتراضية لهذا الرقم',
                  border: OutlineInputBorder(),
                  helperText:
                      'اختيارك فقط، لا يغيّر تصنيف رسائل المحافظ الأخرى',
                  helperMaxLines: 2,
                ),
                items: [
                  for (final w in d.wallets)
                    DropdownMenuItem(value: w, child: Text(_shortWallet(w)))
                ],
                onChanged: (w) => setState(() => d.defaultWallet = w),
              ),
            ],
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
