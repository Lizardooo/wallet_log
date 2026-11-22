import 'package:flutter/material.dart';
import 'db.dart';
import 'logic.dart' show fmt, accountLabel;
import 'tabs.dart' show dayTitle, parseAmount;
import 'wallet_sms_balance.dart';
import 'sms_balance_label.dart';

/// Asks for today's opening balance of each account in [accounts].
/// Returns the amounts that were filled in, keyed by account id.
Future<Map<int, double>?> showSmsOpeningDialog(
  BuildContext context,
  String day,
  List<Account> accounts,
  Map<int, double?> prefill, {
  Map<int, SmsWalletBalance> latestSms = const {},
  Map<int, SmsWalletBalance> openingSms = const {},
}) {
  final controllers = {
    for (final a in accounts)
      a.id!: TextEditingController(
        text: prefill[a.id] == null ? '' : fmt(prefill[a.id]!),
      ),
  };
  return showDialog<Map<int, double>>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('رصيد بداية اليوم'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dayTitle(day)),
            const SizedBox(height: 4),
            const Text(
              'رصيد بداية اليوم مقترح من آخر رصيد مذكور برسالة قبل اليوم فقط. راجع التوقيت وأكده أو عدله؛ لو غير معروف اتركه فارغاً.',
              style: TextStyle(fontSize: 12),
            ),
            for (final a in accounts) ...[
              const SizedBox(height: 12),
              if (latestSms[a.id] != null)
                SmsBalanceLabel(balance: latestSms[a.id]!),
              if (openingSms[a.id] != null)
                Text(
                    'مصدر اقتراح بداية اليوم: ${smsBalanceTime(openingSms[a.id]!.ts)}',
                    style: const TextStyle(fontSize: 12)),
              if (openingSms[a.id] == null)
                const Text(
                    'لا يوجد رصيد واضح قبل اليوم؛ أدخل رصيد البداية إذا كنت تعرفه.',
                    style: TextStyle(fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: controllers[a.id!],
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: accountLabel(a),
                  border: const OutlineInputBorder(),
                  suffixText: 'EGP',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('لاحقاً'),
        ),
        FilledButton(
          onPressed: () {
            final out = <int, double>{};
            controllers.forEach((id, c) {
              final v = parseAmount(c.text);
              if (v != null) out[id] = v;
            });
            Navigator.pop(ctx, out);
          },
          child: const Text('حفظ'),
        ),
      ],
    ),
  );
}
