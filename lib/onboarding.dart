import 'package:flutter/material.dart';

import 'db.dart';
import 'gemini.dart';
import 'parser.dart';
import 'tabs.dart';

const _green = Color(0xFF0F766E);

class _Draft {
  final TextEditingController label;
  final TextEditingController number;
  String? wallet;
  int? subId;
  int? slot;

  _Draft({String labelText = '', String numberText = ''})
      : label = TextEditingController(text: labelText),
        number = TextEditingController(text: numberText);

  void dispose() {
    label.dispose();
    number.dispose();
  }
}

String _shortWallet(String w) => switch (w) {
      'Vodafone Cash' => 'فودافون كاش',
      'Orange Cash' => 'أورنج كاش',
      'InstaPay' => 'إنستاباي',
      _ => 'اتصالات كاش',
    };

/// Shown once, before the tabs: the owner enters his number and each wallet's
/// SIM slot, then (optionally) the Gemini key so messages can be classified by
/// a model. Finishing goes straight to the reports.
class OnboardingPage extends StatefulWidget {
  final Future<void> Function() onDone;

  const OnboardingPage({super.key, required this.onDone});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _pages = PageController();
  final _phone = TextEditingController();
  final _key = TextEditingController();
  final _drafts = <_Draft>[_Draft()];
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
    _phone.dispose();
    _key.dispose();
    for (final d in _drafts) {
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
        for (final e in raw) {
          final m = Map<String, dynamic>.from(e as Map);
          sims.add(SimSlot(
            subId: m['subId'] as int?,
            slot: (m['slot'] as int?) ?? 0,
            carrier: (m['carrier'] as String?) ?? '',
            number: (m['number'] as String?) ?? '',
          ));
        }
      }
    } catch (_) {
      // The wizard still works: the owner can pick the slot by hand.
    }
    if (!mounted) return;
    setState(() {
      _sims = sims;
      _simsLoaded = true;
      if (sims.isNotEmpty) {
        for (final d in _drafts) {
          d.subId ??= sims.first.subId;
          d.slot ??= sims.first.slot;
        }
      }
    });
  }

  List<SimSlot> get _slotOptions => _sims.isEmpty
      ? const [SimSlot(slot: 0), SimSlot(slot: 1)]
      : _sims;

  String _autoName(_Draft d, String number) {
    final w = d.wallet == null ? 'محفظة' : _shortWallet(d.wallet!);
    if (number.isNotEmpty) return '$w · $number';
    if (d.slot != null) return '$w · شريحة ${d.slot! + 1}';
    return w;
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
        final phone = normalizeDigits(_phone.text.trim());
        if (phone.isNotEmpty) {
          await TxDb.setSetting(TxDb.settingsOwnerPhone, phone);
        }
        for (final d in _drafts) {
          final wallet = d.wallet;
          if (wallet == null) continue;
          final number = normalizeDigits(d.number.text.trim());
          if (number.isEmpty && _drafts.length > 1) continue;
          final label = d.label.text.trim();
          await TxDb.saveAccount(Account(
            name: label.isEmpty ? _autoName(d, number) : label,
            wallet: wallet,
            number: number,
            subId: d.subId,
            slot: d.slot,
          ));
        }
        final key = _key.text.trim();
        if (key.isNotEmpty) {
          await TxDb.setSetting(TxDb.settingsApiKey, key);
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
    if (_step == 1 && !_drafts.any((d) => d.wallet != null)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('اختر محفظة واحدة على الأقل، أو اضغط "تخطي" من الأعلى.'),
      ));
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
      0 => 'بياناتك',
      1 => 'محافظك والشرائح',
      _ => 'الذكاء الاصطناعي',
    };
    return Scaffold(
      appBar: AppBar(
        title: Text('إعداد أموالي · $title'),
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
          LinearProgressIndicator(value: (_step + 1) / 3),
          Expanded(
            child: PageView(
              controller: _pages,
              physics: const NeverScrollableScrollPhysics(),
              children: [_step0(), _step1(), _step2()],
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
                      icon: const Icon(Icons.chevron_right),
                      label: const Text('السابق'),
                    ),
                  const Spacer(),
                  if (_step < 2)
                    FilledButton.icon(
                      onPressed: _saving ? null : _next,
                      icon: const Icon(Icons.chevron_left),
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
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: Image.asset('assets/logo.png', height: 84),
        ),
        const SizedBox(height: 16),
        const Text(
          'أهلاً بك في أموالي',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'إعداد مرة واحدة فقط: رقمك، والمحافظ اللي عندك، والشريحة اللي بتستقبل '
          'رسايل كل محفظة. بعد كده التطبيق يقرأ الرسائل ويجهز التقارير.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'رقم موبايلك',
            helperText: 'الرقم المسجل عليه المحافظ (11 رقم)',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.phone_android),
          ),
        ),
        const SizedBox(height: 20),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.lock_outline, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'كل شيء يُحفظ على هذا الهاتف فقط. لا يُرفع أي شيء لأي خدمة '
                    'إلا إذا شغّلت التصنيف بالذكاء الاصطناعي.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _step1() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'سجّل كل رقم محفظة على هذا الهاتف، وحدد نوع المحفظة والشريحة (SIM) '
          'اللي بتستقبل رسايلها. لو عندك رقمين من نفس المحفظة، كل واحد له شريحة.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 4),
        if (!_simsLoaded)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          )
        else if (_sims.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'لم يتم قراءة شرائح الهاتف تلقائياً (محتاج إذن الهاتف). اختر '
              '"شريحة 1" أو "شريحة 2" يدوياً، أو "غير محدد".',
              style: TextStyle(fontSize: 12, color: Colors.orange),
            ),
          ),
        for (var i = 0; i < _drafts.length; i++) _walletCard(i),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () {
            final firstNumber = _drafts.isEmpty
                ? _phone.text.trim()
                : _drafts.first.number.text.trim();
            setState(() => _drafts.add(_Draft(numberText: firstNumber)));
          },
          icon: const Icon(Icons.add),
          label: const Text('إضافة محفظة أخرى'),
        ),
      ],
    );
  }

  Widget _walletCard(int index) {
    final d = _drafts[index];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('محفظة ${index + 1}',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_drafts.length > 1)
                  IconButton(
                    tooltip: 'حذف',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      setState(() {
                        _drafts.removeAt(index).dispose();
                      });
                    },
                  ),
              ],
            ),
            const Text('نوع المحفظة', style: TextStyle(fontSize: 12)),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final w in walletTypes)
                  ChoiceChip(
                    label: Text(w),
                    selected: d.wallet == w,
                    onSelected: (_) => setState(() => d.wallet = w),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: d.number,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'رقم المحفظة',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: d.label,
              decoration: const InputDecoration(
                labelText: 'اسم مختصر (اختياري)',
                hintText: 'مثال: فودافون الأساسي',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            const Text('الشريحة (SIM slot)',
                style: TextStyle(fontSize: 12)),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final s in _slotOptions)
                  ChoiceChip(
                    label: Text(s.label),
                    selected: d.subId == s.subId && d.slot == s.slot,
                    onSelected: (_) => setState(() {
                      d.subId = s.subId;
                      d.slot = s.slot;
                    }),
                  ),
                ChoiceChip(
                  label: const Text('غير محدد'),
                  selected: d.subId == null && d.slot == null,
                  onSelected: (_) => setState(() {
                    d.subId = null;
                    d.slot = null;
                  }),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _step2() {
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
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
