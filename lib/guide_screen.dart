import 'package:flutter/material.dart';

/// One step of the how-to guide: a title, short numbered instructions and a
/// screenshot of the real screen with the places to tap marked on it.
class GuideStep {
  final String id; // screenshot: assets/guide/<id>.png
  final IconData icon;
  final String title;
  final List<String> points;
  const GuideStep(this.id, this.icon, this.title, this.points);
}

const guideSteps = <GuideStep>[
  GuideStep('setup', Icons.sim_card_outlined, 'أول مرة: اختار شرايحك', [
    'لما التطبيق يطلب إذن قراءة الرسايل وحالة الموبايل، دوس "سماح".',
    'علّم ✓ على الشريحة اللي عليها محفظة.',
    'اختار نوع المحفظة: فودافون كاش، إنستاباي، أورنج كاش أو اتصالات كاش.',
    'لو رقم الشريحة ظاهر، سيبه زي ما هو.',
  ]),
  GuideStep('number', Icons.dialpad, 'لو الرقم مش ظاهر: اكتبه بنفسك', [
    'موبايلات كتير ما بتقولش رقم الشريحة. ساعتها هيظهر لك تنبيه برتقاني.',
    'اكتب الرقم 11 رقم ويبدأ بـ 01، زي 01012345678.',
    'التطبيق مش هيكمل غير لما كل شريحة متعلّم عليها يبقى ليها رقم.',
    'تقدر تعدّل الأرقام بعدين من الإعدادات ← محافظي وأرقامي.',
  ]),
  GuideStep('home', Icons.home_outlined, 'الرئيسية: الصورة كلها في نظرة', [
    'هنا هتلاقي الداخل والخارج والرسوم المؤكدة.',
    'المبالغ "المعلّقة" لسه محتاجة تأكيد منك، ومش داخلة في الحساب.',
    'دوس زرار التحديث ↻ (أو اسحب الشاشة لتحت) عشان التطبيق يقرا الرسايل الجديدة.',
  ]),
  GuideStep('transactions', Icons.list_alt, 'المعاملات: كل عملية لوحدها', [
    'كل رسالة محفظة بتتحول لسطر فيه المبلغ والنوع والرقم التاني والوقت.',
    'استخدم 🔍 عشان تدوّر برقم أو مبلغ، واستخدم الفلاتر عشان تختار محفظة أو يوم.',
    'دوس على أي عملية عشان تشوف الرسالة الأصلية أو تكتب ملاحظة.',
  ]),
  GuideStep('review', Icons.rule, 'المراجعة: رسايل محتاجة رأيك', [
    'أي رسالة التطبيق مش متأكد منها بيحطها هنا، ومش بيحسبها.',
    'افتحها، اتأكد من النوع والاتجاه (داخل ولا خارج)، ودوس "تأكيد واحتساب".',
    'لو الرسالة مش مهمة أو مكررة، تقدر تستبعدها.',
  ]),
  GuideStep('reports', Icons.bar_chart, 'التقارير: لكل رقم ولكل فترة', [
    'اختار الفترة: النهارده، 7 أيام، الشهر ده… واختار المحفظة.',
    'هتلاقي إجمالي كل رقم، وأكتر الأرقام اللي بتتعامل معاها.',
    'عندك موبايل تاني؟ صدّر منه ملف Excel وابعته، وهنا دوس "استيراد" واختار المحفظة اللي الملف جاي منها.',
  ]),
  GuideStep('settings', Icons.settings_outlined, 'الإعدادات: كل حاجة تانية', [
    'محافظي وأرقامي: ضيف رقم أو عدّله، وشغّل التذكير اليومي.',
    'رصيد اليوم والمتبقي: اكتب رصيد أول اليوم، والتطبيق يحسب لك الفاضل.',
    'النسخة الاحتياطية: اعملها كل فترة عشان ما تخسرش بياناتك لو غيّرت الموبايل.',
  ]),
];

const guideFaq = <(String, String)>[
  (
    'هو التطبيق ده محفظة؟',
    'لأ. هو بيقرا رسايل المحافظ اللي بتوصلك ويرتبها لك. مفيش أي فلوس بتتحرك منه.'
  ),
  (
    'ليه في عملية مش محسوبة في الإجمالي؟',
    'لأنها محتاجة مراجعة. روح تبويب "المراجعة"، افتحها ودوس "تأكيد واحتساب".'
  ),
  (
    'مش لاقي رسايل خالص!',
    'اتأكد إنك سمحت للتطبيق يقرا الرسايل، وإن رقم المحفظة مكتوب صح في '
        'الإعدادات ← محافظي وأرقامي. وبعدين دوس ↻.'
  ),
  (
    'بياناتي بتروح فين؟',
    'كلها متخزنة على الموبايل ده بس. لو شغّلت الذكاء الاصطناعي، الرسايل اللي '
        'بتختار تصنفها بس هي اللي بتتبعت لجوجل.'
  ),
];

class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('إزاي أستخدم التطبيق')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            color: cs.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'التطبيق ده بيقرا رسايل المحافظ اللي بتوصل على موبايلك '
                '(فودافون كاش، إنستاباي، أورنج كاش، اتصالات كاش) ويرتبها لك: '
                'دخل كام، خرج كام، وفاضل كام. مش محفظة، ومش بيحوّل فلوس.',
                style: TextStyle(color: cs.onPrimaryContainer, height: 1.5),
              ),
            ),
          ),
          for (var i = 0; i < guideSteps.length; i++)
            _StepCard(index: i + 1, step: guideSteps[i]),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 16, 4, 4),
            child: Text('أسئلة بتتكرر',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          for (final (q, a) in guideFaq)
            Card(
              child: ExpansionTile(
                title: Text(q),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                expandedAlignment: AlignmentDirectional.centerStart,
                children: [Text(a, style: const TextStyle(height: 1.5))],
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final int index;
  final GuideStep step;
  const _StepCard({required this.index, required this.step});

  void _zoom(BuildContext context, String asset) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(8),
        child: Stack(children: [
          InteractiveViewer(
            maxScale: 4,
            child: Image.asset(asset, fit: BoxFit.contain),
          ),
          PositionedDirectional(
            top: 4,
            end: 4,
            child: IconButton.filledTonal(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final asset = 'assets/guide/${step.id}.png';
    return Card(
      key: ValueKey('guide-${step.id}'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: cs.primary,
                child: Text('$index',
                    style: TextStyle(
                        color: cs.onPrimary, fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 8),
              Icon(step.icon, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(step.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ),
            ]),
            const SizedBox(height: 8),
            for (var i = 0; i < step.points.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      margin: const EdgeInsetsDirectional.only(end: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE53935),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Text('${i + 1}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                    ),
                    Expanded(
                        child: Text(step.points[i],
                            style: const TextStyle(height: 1.5))),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Center(
              child: GestureDetector(
                onTap: () => _zoom(context, asset),
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: 260, maxHeight: 460),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          border: Border.all(color: cs.outlineVariant)),
                      child: Image.asset(
                        asset,
                        fit: BoxFit.contain,
                        // No screenshot bundled: the written steps still work.
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const Center(
              child: Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                    'الدواير الحمرا في الصورة بتوريك تدوس فين · '
                    'دوس على الصورة عشان تكبّرها',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
