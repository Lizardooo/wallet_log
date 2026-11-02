import 'package:flutter/material.dart';

import 'db.dart';
import 'gemini.dart';
import 'parser.dart';
import 'tabs.dart';

const _green = Color(0xFF0F766E);

class _SimDraft {
  final TextEditingController number;
  final Set<String> wallets = {};
  final int? subId;
  final int slot;
  final String carrier;

  /// true when the phone reported this SIM's number by itself.
  final bool autoNumber;

  /// false for a slot the phone did not report (filled in by hand).
  final bool detected;

  _SimDraft({
    required this.slot,
    this.subId,
    this.carrier = '',
    this.detected = false,
    String numberText = '',
  })  : autoNumber = numberText.isNotEmpty,
        number = TextEditingController(text: numberText) {
    final guess = walletForSim(numberText, carrier);
    if (guess != null) wallets.add(guess);
  }

  String get title =>
      carrier.isEmpty ? 'شريحة ${slot + 1}' : 'شريحة ${slot + 1} · $carrier';

  void dispose() => number.dispose();
}

String _shortWallet(String w) => switch (w) {
      'Vodafone Cash' => 'فودافون كاش',
      'Orange Cash' => 'أورنج كاش',
      'InstaPay' => 'إنستاباي',
      'WE Pay' => 'وي باي',
      _ => 'اتصالات كاش / فوري',
    };

/// An Egyptian mobile number in local form (01xxxxxxxxx), or null when [raw]
/// is not one. Accepts Arabic digits, spaces, dashes and the +20 / 0020 / 20
/// country prefix that some phones report for the SIM's own number.
String? normalizeEgyptMobile(String raw) {
  var n = normalizeDigits(raw).replaceAll(RegExp(r'[\s\-().]'), '');
  if (n.startsWith('+20')) {
    n = '0${n.substring(3)}';
  } else if (n.startsWith('0020')) {
    n = '0${n.substring(4)}';
  } else if (n.startsWith('20') && n.length == 12) {
    n = '0${n.substring(2)}';
  } else if (n.startsWith('1') && n.length == 10) {
    n = '0$n';
  }
  return RegExp(r'^01[0125]\d{8}$').hasMatch(n) ? n : null;
}

/// Best guess of the wallet on a SIM, from the carrier name the phone reports
/// or else the number's prefix (010 Vodafone, 011 Etisalat, 012 Orange,
/// 015 WE). Only a pre-selection: numbers can be ported, so the owner can
/// change it.
String? walletForSim(String number, String carrier) {
  final c = carrier.toLowerCase();
  if (c.contains('vodafone')) return 'Vodafone Cash';
  if (c.contains('orange') || c.contains('mobinil')) return 'Orange Cash';
  if (c.contains('etisalat') || c.contains('e&')) {
    return 'Etisalat Cash / Fawry';
  }
  if (RegExp(r'(?<![a-z])we(?![a-z])').hasMatch(c) ||
      c.contains('telecom egypt')) {
    return 'WE Pay';
  }
  final n = normalizeEgyptMobile(number);
  if (n == null) return null;
  return switch (n.substring(0, 3)) {
    '010' => 'Vodafone Cash',
    '011' => 'Etisalat Cash / Fawry',
    '012' => 'Orange Cash',
    '015' => 'WE Pay',
    _ => null,
  };
}

/// Shown once, before the tabs. The owner says whether one or two SIMs carry
/// an e-wallet; the app detects the SIM slots and their numbers, and asks for
/// any number it could not read. Then (optionally) the Gemini key so messages
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

  /// How many SIMs carry a wallet (1 or 2), and which drafts they are.
  int _simCount = 1;
  final _chosen = <int>[];
  bool _showErrors = false;
  bool _phoneDenied = false;
  int _step = 0;
  bool _saving = false;
  bool _hideKey = true;

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

  /// Reads the phone's SIM slots and, when the carrier stored it, each SIM's
  /// own number. Slots the phone does not report (or every slot, when the
  /// permission is refused) are still offered so the owner can type them.
  Future<void> _loadSims() async {
    if (_simsLoaded) setState(() => _simsLoaded = false);
    var sims = <SimSlot>[];
    var denied = false;
    try {
      final granted =
          await smsChannel.invokeMethod<bool>('requestPhoneState') ?? false;
      denied = !granted;
      if (granted) {
        final raw =
            await smsChannel.invokeMethod<List<dynamic>>('simInfo') ?? const [];
        for (var i = 0; i < raw.length; i++) {
          final m = Map<String, dynamic>.from(raw[i] as Map);
          final rawSlot = m['slot'] as int?;
          final rawSub = m['subId'] as int?;
          final number = (m['number'] as String?) ?? '';
          sims.add(SimSlot(
            subId: (rawSub != null && rawSub >= 0) ? rawSub : null,
            slot: (rawSlot == null || rawSlot < 0) ? i : rawSlot,
            carrier: (m['carrier'] as String?) ?? '',
            // Shown in local form; an unreadable value is left for the owner.
            number: normalizeEgyptMobile(number) ?? '',
          ));
        }
      }
    } catch (_) {
      // The wizard still works: the owner can enter the numbers by hand.
    }
    if (!mounted) return;
    setState(() {
      _simsLoaded = true;
      _phoneDenied = denied;
      for (final d in _simDrafts) {
        d.dispose();
      }
      _simDrafts.clear();
      sims.sort((a, b) => a.slot.compareTo(b.slot));
      for (final s in sims) {
        _simDrafts.add(_SimDraft(
          subId: s.subId,
          slot: s.slot,
          carrier: s.carrier,
          detected: true,
          numberText: s.number,
        ));
      }
      // Always offer SIM 1 and SIM 2, even when the phone hid one of them.
      for (final slot in const [0, 1]) {
        if (!_simDrafts.any((d) => d.slot == slot)) {
          _simDrafts.add(_SimDraft(slot: slot));
        }
      }
      _simDrafts.sort((a, b) => a.slot.compareTo(b.slot));
      final detected = _simDrafts.where((d) => d.detected).length;
      _simCount = detected >= 2 ? 2 : 1;
      _resetChosen();
    });
  }

  /// Picks the default SIMs for the current count: detected SIMs first.
  void _resetChosen() {
    _chosen.clear();
    final order = [
      for (var i = 0; i < _simDrafts.length; i++)
        if (_simDrafts[i].detected) i,
      for (var i = 0; i < _simDrafts.length; i++)
        if (!_simDrafts[i].detected) i,
    ];
    _chosen.addAll(order.take(_simCount));
  }

  void _setSimCount(int count) {
    setState(() {
      _simCount = count;
      if (_chosen.length > count) {
        _chosen.removeRange(count, _chosen.length);
      }
      for (var i = 0; _chosen.length < count && i < _simDrafts.length; i++) {
        if (!_chosen.contains(i)) _chosen.add(i);
      }
    });
  }

  void _toggleChosen(int index) {
    setState(() {
      if (_chosen.contains(index)) {
        if (_chosen.length > 1) _chosen.remove(index);
        return;
      }
      _chosen.add(index);
      // Keep exactly [_simCount] SIMs: the oldest pick gives way.
      while (_chosen.length > _simCount) {
        _chosen.removeAt(0);
      }
    });
  }

  String _autoName(String wallet, _SimDraft d, String number) =>
      '${_shortWallet(wallet)} · $number';

  /// Why the SIM step cannot continue, or null when it can.
  String? _simProblem() {
    final chosen = [for (final i in _chosen) _simDrafts[i]];
    if (chosen.length != _simCount) {
      return _simCount == 1
          ? 'اختر الشريحة اللي عليها المحفظة.'
          : 'اختر الشريحتين اللي عليهم المحافظ.';
    }
    for (final d in chosen) {
      if (normalizeEgyptMobile(d.number.text) == null) {
        return 'اكتب رقم ${d.title} صحيح (11 رقم يبدأ بـ 010 أو 011 أو 012 أو 015).';
      }
      if (d.wallets.isEmpty) {
        return 'اختر نوع المحفظة على ${d.title}.';
      }
    }
    if (chosen.length == 2 &&
        normalizeEgyptMobile(chosen[0].number.text) ==
            normalizeEgyptMobile(chosen[1].number.text)) {
      return 'رقم الشريحتين لا يمكن أن يكون نفس الرقم.';
    }
    return null;
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

  /// Saves the wallet SIMs (always required) and, unless [skipAi], the
  /// Gemini key and model.
  Future<void> _finish({bool skipAi = false}) async {
    if (_saving) return;
    final problem = _simProblem();
    if (problem != null) {
      setState(() => _showErrors = true);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    setState(() => _saving = true);
    try {
      for (final i in _chosen) {
        final d = _simDrafts[i];
        final number = normalizeEgyptMobile(d.number.text)!;
        for (final wallet in walletTypes.where(d.wallets.contains)) {
          await TxDb.saveAccount(Account(
            name: _autoName(wallet, d, number),
            wallet: wallet,
            number: number,
            subId: d.subId,
            slot: d.slot,
          ));
        }
      }
      if (!skipAi) {
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
      final problem = _simProblem();
      if (problem != null) {
        setState(() => _showErrors = true);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(problem)));
        return;
      }
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      FocusScope.of(context).unfocus();
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
        title: Text('إعداد أموالي · $title'),
        automaticallyImplyLeading: false,
        actions: [
          // The SIM step cannot be skipped: the app needs a wallet SIM.
          if (_step == 1)
            TextButton(
              onPressed: _saving ? null : () => _finish(skipAi: true),
              child: const Text('تخطي'),
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
    final detected = _simDrafts.where((d) => d.detected).length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'لاستخدام التطبيق لازم يكون عندك محفظة إلكترونية على شريحة واحدة على '
          'الأقل. هنقرأ رسايل المحفظة اللي بتوصل على الشريحة دي بس.',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        if (!_simsLoaded)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('جاري اكتشاف شرائح الهاتف…',
                    style: TextStyle(fontSize: 12)),
                SizedBox(height: 6),
                LinearProgressIndicator(),
              ],
            ),
          )
        else ...[
          _detectionStatus(detected),
          const SizedBox(height: 12),
          const Text('كام شريحة عليها محفظة؟',
              style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                  value: 1,
                  label: Text('شريحة واحدة'),
                  icon: Icon(Icons.sim_card_outlined)),
              ButtonSegment(
                  value: 2, label: Text('شريحتين'), icon: Icon(Icons.sim_card)),
            ],
            selected: {_simCount},
            onSelectionChanged: (v) => _setSimCount(v.first),
          ),
          if (_simDrafts.length > _simCount) ...[
            const SizedBox(height: 12),
            Text(
              _simCount == 1
                  ? 'أي شريحة عليها المحفظة؟'
                  : 'اختر الشريحتين اللي عليهم المحافظ:',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (var i = 0; i < _simDrafts.length; i++)
                  ChoiceChip(
                    label: Text(_simDrafts[i].title),
                    selected: _chosen.contains(i),
                    onSelected: (_) => _toggleChosen(i),
                  ),
              ],
            ),
          ],
          for (final i in [..._chosen]..sort()) _simCard(i),
        ],
      ],
    );
  }

  Widget _detectionStatus(int detected) {
    final String text;
    final Color color;
    if (_phoneDenied) {
      text = 'لم يتم السماح بقراءة الشرائح، فمش هنقدر نكتشفها تلقائياً. '
          'اكتب رقم الشريحة يدوياً أو اسمح بالإذن وأعد المحاولة.';
      color = Colors.orange.shade800;
    } else if (detected == 0) {
      text = 'لم نتمكن من اكتشاف شرائح الهاتف تلقائياً. اكتب رقم الشريحة '
          'يدوياً.';
      color = Colors.orange.shade800;
    } else {
      final numbers = _simDrafts.where((d) => d.autoNumber).length;
      text = 'تم اكتشاف $detected ${detected == 1 ? 'شريحة' : 'شرائح'}'
          '${numbers == 0 ? '، لكن الهاتف لم يُظهر أرقامها: اكتب الرقم يدوياً.' : numbers < detected ? '، وتم قراءة رقم $numbers منها.' : ' وأرقامها.'}';
      color = _green;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(detected == 0 ? Icons.info_outline : Icons.check_circle_outline,
            size: 18, color: color),
        const SizedBox(width: 6),
        Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color))),
        if (detected == 0)
          TextButton(
            onPressed: _loadSims,
            child: const Text('إعادة المحاولة'),
          ),
      ],
    );
  }

  Widget _simCard(int index) {
    final d = _simDrafts[index];
    final valid = normalizeEgyptMobile(d.number.text) != null;
    final String helper;
    final Color helperColor;
    if (d.autoNumber) {
      helper = 'تم اكتشاف الرقم تلقائياً، عدّله لو مش صحيح';
      helperColor = _green;
    } else if (d.detected) {
      helper = 'الهاتف لم يُظهر رقم الشريحة، اكتبه يدوياً';
      helperColor = Colors.orange.shade800;
    } else {
      helper = 'الشريحة غير مكتشفة، اكتب رقمها يدوياً';
      helperColor = Colors.orange.shade800;
    }
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
                  child: Text(d.title,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: d.number,
              keyboardType: TextInputType.phone,
              textDirection: TextDirection.ltr,
              onChanged: (v) => setState(() {
                // Pre-select the wallet from the prefix while none is chosen.
                final guess = walletForSim(v, d.carrier);
                if (d.wallets.isEmpty && guess != null) d.wallets.add(guess);
              }),
              decoration: InputDecoration(
                labelText: 'رقم الشريحة / المحفظة',
                hintText: '01xxxxxxxxx',
                helperText: helper,
                helperStyle: TextStyle(color: helperColor),
                errorText: _showErrors && !valid
                    ? 'رقم غير صحيح: 11 رقم يبدأ بـ 010 / 011 / 012 / 015'
                    : null,
                prefixIcon: Icon(d.autoNumber
                    ? Icons.verified_outlined
                    : Icons.edit_outlined),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            const Text('المحفظة على الرقم ده (اختر واحدة أو أكثر)',
                style: TextStyle(fontSize: 12)),
            const SizedBox(height: 4),
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
            if (_showErrors && d.wallets.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('اختر نوع المحفظة',
                    style: TextStyle(fontSize: 12, color: Color(0xFFC62828))),
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
