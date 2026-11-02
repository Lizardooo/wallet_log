import 'package:flutter/material.dart';

import 'db.dart';

/// The "الإعدادات" tab: everything that is not needed every day, in one calm
/// list, with the how-to guide first.
class MoreTab extends StatelessWidget {
  final List<Account> accounts;
  final VoidCallback onGuide;
  final VoidCallback onAccounts;
  final VoidCallback onDaily;
  final VoidCallback onSuggestions;
  final VoidCallback onImport;
  final VoidCallback onAi;
  final VoidCallback onBackup;

  const MoreTab({
    super.key,
    required this.accounts,
    required this.onGuide,
    required this.onAccounts,
    required this.onDaily,
    required this.onSuggestions,
    required this.onImport,
    required this.onAi,
    required this.onBackup,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final missing = accounts.where((a) => a.number.isEmpty).length;
    Widget item(IconData icon, String title, String subtitle, VoidCallback tap,
            {Key? key, Color? color}) =>
        Card(
          key: key,
          child: ListTile(
            leading: Icon(icon, color: color ?? cs.primary),
            title: Text(title),
            subtitle: Text(subtitle,
                style: color == null ? null : TextStyle(color: color)),
            trailing: const Icon(Icons.chevron_right),
            onTap: tap,
          ),
        );
    Widget section(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
          child: Text(text,
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: cs.onSurfaceVariant)),
        );

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          key: const ValueKey('more-guide'),
          color: cs.primaryContainer,
          child: ListTile(
            leading: Icon(Icons.menu_book, color: cs.onPrimaryContainer),
            title: Text('إزاي أستخدم التطبيق؟',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: cs.onPrimaryContainer)),
            subtitle: Text('شرح خطوة بخطوة بالصور',
                style: TextStyle(color: cs.onPrimaryContainer)),
            trailing: Icon(Icons.chevron_right, color: cs.onPrimaryContainer),
            onTap: onGuide,
          ),
        ),
        section('محافظك'),
        item(
          Icons.sim_card_outlined,
          'محافظي وأرقامي',
          missing > 0
              ? '⚠ $missing رقم مش مكتوب. اضغط واكتبه.'
              : (accounts.isEmpty
                  ? 'ضيف أرقام المحافظ اللي عندك'
                  : '${accounts.length} رقم · التذكير اليومي'),
          onAccounts,
          key: const ValueKey('more-accounts'),
          color:
              missing > 0 || accounts.isEmpty ? Colors.orange.shade800 : null,
        ),
        item(Icons.today, 'رصيد اليوم والمتبقي',
            'الداخل والخارج والمتبقي لكل رقم', onDaily),
        section('أدوات'),
        item(Icons.lightbulb_outline, 'الاقتراحات',
            'رسايل ممكن تكون مكررة أو مرتبطة ببعض', onSuggestions),
        item(Icons.upload_file, 'استيراد ملف Excel',
            'تقرير من موبايل تاني أو من البنك', onImport),
        item(Icons.auto_awesome, 'الذكاء الاصطناعي (اختياري)',
            'يساعد في فهم الرسايل اللي مش واضحة', onAi),
        item(Icons.save_alt, 'النسخة الاحتياطية',
            'احفظ بياناتك أو رجّعها على موبايل جديد', onBackup),
        const SizedBox(height: 16),
        Text(
          'التطبيق بيقرا رسايل المحافظ على الموبايل ده بس، ومش بيحوّل ولا '
          'بيسحب فلوس. بياناتك متخزنة على الموبايل.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}
