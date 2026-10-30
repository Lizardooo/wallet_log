/// Turns a raw wallet SMS into a structured transaction.
///
/// The patterns are heuristics covering English and Arabic wording. Wallet
/// providers change their templates, so tune [_inWords], [_outWords] and the
/// wallet detection below against your own real messages.
enum Dir { inFlow, outFlow }

class Parsed {
  final String wallet;
  final Dir dir;
  final double amount;
  final String? party;
  final double? balance;

  const Parsed(this.wallet, this.dir, this.amount, this.party, this.balance);
}

const _amt = r'(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)';
const _cur =
    r'(?:(?<![A-Za-z])(?:EGP|LE|L\.E\.?)(?![A-Za-z])|جنيه|جنية|ج\.م)';

final _amountRe =
    RegExp('(?:$_cur\\s*$_amt|$_amt\\s*$_cur)', caseSensitive: false);
final _balanceRe = RegExp(
  '(?:balance|رصيد\\S*)\\D{0,20}?(?:$_cur\\s*)?$_amt',
  caseSensitive: false,
);
final _phoneRe = RegExp(r'01\d{9}');

const _inWords = [
  'received',
  'you have received',
  'credited',
  'deposit',
  'استلمت',
  'استلام',
  'وصلك',
  'ايداع',
  'إيداع',
  'تم اضافة',
  'تم إضافة',
];

const _outWords = [
  'sent',
  'paid',
  'payment',
  'transferred',
  'withdraw',
  'purchase',
  'debited',
  'تم تحويل',
  'تحويل',
  'دفع',
  'سحب',
  'خصم',
  'شراء',
];

String normalizeDigits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final c in s.split('')) {
    final i = ar.indexOf(c);
    if (i >= 0) {
      b.write(i);
    } else if (c == '٫') {
      b.write('.');
    } else if (c == '٬') {
      b.write(',');
    } else {
      b.write(c);
    }
  }
  return b.toString();
}

String? detectWallet(String sender, String body) {
  final s = sender.toLowerCase();
  final b = body.toLowerCase();
  if (s.contains('instapay') || b.contains('instapay') || b.contains('انستا')) {
    return 'InstaPay';
  }
  if (s.contains('orange') ||
      b.contains('orange') ||
      b.contains('اورنج') ||
      b.contains('أورنج')) {
    return 'Orange Cash';
  }
  final vodafone = s.contains('vodafone') || s.contains('vf') ||
      b.contains('vodafone') || b.contains('فودافون');
  if (vodafone && (s.contains('cash') || b.contains('cash') || b.contains('كاش'))) {
    return 'Vodafone Cash';
  }
  if (s.contains('etisalat') ||
      s.contains('e&') ||
      s.contains('fawry') ||
      b.contains('etisalat') ||
      b.contains('اتصالات') ||
      b.contains('فوري') ||
      b.contains('fawry')) {
    return 'Etisalat Cash / Fawry';
  }
  return null;
}

/// Returns null when the message is not a recognizable wallet transaction.
Parsed? parseSms(String sender, String rawBody) {
  final body = normalizeDigits(rawBody);
  final wallet = detectWallet(sender, body);
  if (wallet == null) return null;

  final balMatch = _balanceRe.firstMatch(body);
  final balance = double.tryParse(
    (balMatch?.group(1) ?? '').replaceAll(',', ''),
  );
  final rest =
      balMatch == null ? body : body.replaceRange(balMatch.start, balMatch.end, ' ');

  final m = _amountRe.firstMatch(rest);
  if (m == null) return null;
  final amount = double.tryParse(
    (m.group(1) ?? m.group(2) ?? '').replaceAll(',', ''),
  );
  if (amount == null) return null;

  final lower = rest.toLowerCase();
  Dir dir;
  if (_inWords.any(lower.contains)) {
    dir = Dir.inFlow;
  } else if (_outWords.any(lower.contains)) {
    dir = Dir.outFlow;
  } else {
    return null;
  }

  return Parsed(wallet, dir, amount, _phoneRe.firstMatch(rest)?.group(0), balance);
}
