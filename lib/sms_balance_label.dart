import 'package:flutter/material.dart';
import 'money_engine.dart';
import 'review_strings.dart';
import 'wallet_sms_balance.dart';

String smsBalanceTime(int ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

/// A timestamped SMS observation, deliberately separate from ledger totals.
class SmsBalanceLabel extends StatelessWidget {
  final SmsWalletBalance balance;
  const SmsBalanceLabel({super.key, required this.balance});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              '${reviewText(context, 'آخر رصيد مذكور برسالة', 'Last balance stated in SMS')}: ${formatMinor(balance.minor)} EGP'),
          Text(
              '${reviewText(context, 'وقت الرسالة', 'SMS time')}: ${smsBalanceTime(balance.ts)}',
              style: Theme.of(context).textTheme.bodySmall),
          Text(
              reviewText(
                  context,
                  'رصيد وقت الرسالة، وليس رصيد بداية اليوم أو تأكيداً للرصيد الحالي.',
                  'Balance at SMS time, not the day opening or a confirmed current balance.'),
              style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}
