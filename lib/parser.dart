/// Turns a raw wallet SMS into a structured transaction.
///
/// Egyptian wallets (Vodafone Cash, InstaPay, Orange Cash, Etisalat Cash /
/// Fawry) support transfers, cash in / cash out (agents and ATMs), phone
/// top-ups, bill payments, merchant payments, refunds and fees. Their SMS
/// templates are not public, so the rules below are deliberately cautious:
///  * OTP / temporary-code, failed, rejected and pending messages are ignored;
///  * when the direction or type cannot be told, the message is kept but flagged
///    for review instead of being guessed;
///  * balance, limit and fee amounts are separated from the transaction amount.
///  * only transfers and explicit deductions (خصم / debited) are marked as
///    counted; every other operation is flagged for review and stays out of the
///    totals until the owner confirms it.
/// Tune the word lists against your own real messages (see test/parser_test.dart).
enum Dir { inFlow, outFlow, unknown }

enum TxType {
  transfer,
  deduction,
  cashIn,
  cashOut,
  topup,
  bill,
  payment,
  refund,
  fee,
  other,
}

extension TxTypeX on TxType {
  String get label => switch (this) {
        TxType.transfer => 'تحويل',
        TxType.deduction => 'خصم رصيد',
        TxType.cashIn => 'إيداع نقدي',
        TxType.cashOut => 'سحب نقدي',
        TxType.topup => 'شحن رصيد',
        TxType.bill => 'فواتير وخدمات',
        TxType.payment => 'دفع لتاجر / مشتريات',
        TxType.refund => 'استرداد',
        TxType.fee => 'رسوم',
        TxType.other => 'غير مصنفة',
      };
}

extension DirX on Dir {
  String get label => switch (this) {
        Dir.inFlow => 'داخل',
        Dir.outFlow => 'خارج',
        Dir.unknown => 'غير محدد',
      };
}

class Parsed {
  final String wallet;
  final TxType type;
  final Dir dir;
  final double amount;
  final double fee;
  final String? party;
  final double? balance;
  /// true when the message is not a plain transfer / deduction, or the app is
  /// not sure about it: it is then left out of all totals until confirmed.
  final bool review;

  const Parsed({
    required this.wallet,
    required this.type,
    required this.dir,
    required this.amount,
    required this.fee,
    required this.party,
    required this.balance,
    required this.review,
  });
}

const _amt = r'(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)';
const _cur = r'(?:(?<![A-Za-z])(?:EGP|LE|L\.E\.?)(?![A-Za-z])|جنيه|جنية|ج\.م)';

final _amountRe =
    RegExp('(?:$_cur\\s*$_amt|$_amt\\s*$_cur)', caseSensitive: false);

// "balance" keywords must be specific: a bare "رصيد" also appears in
// "شحن رصيد 50 جنيه" (a top-up), which is a transaction, not a balance.
final _balanceRe = RegExp(
  '(?:balance|رصيدك|رصيد\\s+(?:المحفظة|محفظتك|حسابك|الحالي|المتاح|الجديد)|'
  'الرصيد\\s+(?:الحالي|المتاح|الجديد|المتبقي|بعد))'
  '(?:(?!مبلغ)\\D){0,20}?(?:$_cur\\s*)?$_amt',
  caseSensitive: false,
);

final _limitRe = RegExp(
  '(?:limit|remaining|available|الحد|المتبقي|المتاح)'
  '\\D{0,25}?(?:$_cur\\s*)?$_amt(?:\\s*$_cur)?',
  caseSensitive: false,
);

final _feeRe = RegExp(
  '(?:fees?|commission|charges?|رسوم|عمولة|مصاريف)'
  '\\D{0,20}?(?:$_cur\\s*)?$_amt(?:\\s*$_cur)?',
  caseSensitive: false,
);

RegExp _cat(List<String> en, List<String> ar) {
  final parts = <String>[];
  if (en.isNotEmpty) parts.add('(?<![a-z])(?:${en.join('|')})(?![a-z])');
  if (ar.isNotEmpty) parts.add('(?:${ar.join('|')})');
  return RegExp(parts.join('|'));
}

// Messages that must never become transactions.
final _skip = _cat(
  [
    'otp',
    'one[ -]?time',
    'temporary',
    'verification',
    'failed',
    'declined',
    'unsuccessful',
    'insufficient',
    'rejected',
    'cancel(?:l?ed)?',
    'expired',
    'pending',
    'offers?',
    'promo(?:tion)?',
    'win',
    'enjoy',
    'hurry',
  ],
  [
    'مؤقت',
    'رمز التحقق',
    'تعذر',
    'فشل',
    'لم تتم',
    'غير ناجح',
    'مرفوض',
    'رفض',
    'ملغ',
    'غير كاف',
    'منتهي',
    'قيد المعالجة',
    'قيد التنفيذ',
    'عرض',
    'عروض',
    'احصل على',
    'اشحن',
    'اربح',
    'سارع',
  ],
);

final _refund = _cat(
  ['refund(?:ed)?', 'reversal', 'reversed'],
  ['استرداد', 'إسترداد', 'ارجاع', 'إرجاع', 'رد مبلغ', 'عكس'],
);
final _topup = _cat(['re-?charge[d]?', 'top[ -]?up'], ['شحن']);
final _bill = _cat(
  [
    'bills?',
    'electricity',
    'water',
    'gas',
    'internet',
    'landline',
    'subscription',
    'installments?',
    'insurance',
    'tax(?:es)?',
    'utilit(?:y|ies)',
  ],
  [
    'فاتور[ةه]',
    'فواتير',
    'سداد',
    'كهرباء',
    'مياه',
    'غاز',
    'انترنت',
    'إنترنت',
    'ارضي',
    'أرضي',
    'اشتراك',
    'قسط',
    'اقساط',
    'أقساط',
    'تأمين',
    'ضريبة',
    'ضرائب',
  ],
);
final _cashOut = _cat(['withdraw(?:al|n)?', 'atm'], ['سحب', 'صراف']);
final _cashIn = _cat(
  ['deposit(?:ed)?', 'cash[ -]?in'],
  ['ايداع', 'إيداع', 'تم اضافة', 'تم إضافة', 'اضافة رصيد', 'إضافة رصيد'],
);
final _deduction = _cat(
  ['debited', 'deducted', 'deduction', 'debit'],
  ['خصم', 'استقطاع'],
);
final _payment = _cat(
  ['merchant', 'purchase[d]?', 'pos', 'qr', 'payment', 'paid', 'pay'],
  ['تاجر', 'شراء', 'مشتريات', 'دفع', 'مدفوع'],
);
final _transfer = _cat(
  ['transfer(?:red)?', 'sent', 'send', 'received', 'receive'],
  ['تحويل', 'حول', 'استلام', 'استلمت', 'وصلك', 'ارسال', 'إرسال', 'استقبال'],
);

final _strongIn = _cat(
  ['received', 'receive', 'credited', 'deposit(?:ed)?', 'refund(?:ed)?'],
  [
    'استلمت',
    'استلام',
    'وصلك',
    'وصل إليك',
    'تم اضافة',
    'تم إضافة',
    'ايداع',
    'إيداع',
    'استرداد',
    'إسترداد',
    'استقبال',
  ],
);
final _strongOut = _cat(
  [
    'sent',
    'send',
    'paid',
    'pay',
    'payment',
    'purchase[d]?',
    'withdraw(?:al|n)?',
    'debited',
    'charged',
  ],
  ['ارسال', 'إرسال', 'دفع', 'سحب', 'خصم', 'شراء', 'سداد'],
);

final _fromRe = RegExp(
  r'(?:من|(?<![a-z])from)\s*(?:رقم\s*|number\s*)?(01\d{9})',
);
final _toRe = RegExp(
  r'(?:إلى|الى|إلي|الي|(?<![a-z])to)\s*(?:رقم\s*|number\s*)?(01\d{9})',
);
final _toMe = RegExp(
  r'(?:إلى|الى|إلي|الي|(?<![a-z])to)\s*(?:محفظتك|حسابك|رصيدك|your\s+(?:wallet|account))',
);
final _fromMe = RegExp(
  r'(?:من|(?<![a-z])from)\s*(?:محفظتك|حسابك|رصيدك|your\s+(?:wallet|account))',
);
final _walletWord = RegExp(r'محفظ|wallet');
final _phoneRe = RegExp(r'01\d{9}');

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
  final vodafone = s.contains('vodafone') ||
      s.contains('vf') ||
      b.contains('vodafone') ||
      b.contains('فودافون');
  if (vodafone &&
      (s.contains('cash') || b.contains('cash') || b.contains('كاش'))) {
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

double? _num(String? s) =>
    s == null ? null : double.tryParse(s.replaceAll(',', ''));

({String rest, double? balance, double fee, List<double> amounts}) _extract(
    String body, bool useBalance) {
  var rest = body;
  double? balance;
  if (useBalance) {
    final m = _balanceRe.firstMatch(rest);
    if (m != null) {
      balance = _num(m.group(1));
      rest = rest.replaceRange(m.start, m.end, ' ');
    }
  }
  rest = rest.replaceAll(_limitRe, ' ');
  var fee = 0.0;
  final f = _feeRe.firstMatch(rest);
  if (f != null) {
    fee = _num(f.group(1)) ?? 0;
    rest = rest.replaceRange(f.start, f.end, ' ');
  }
  final amounts = _amountRe
      .allMatches(rest)
      .map((m) => _num(m.group(1) ?? m.group(2)))
      .whereType<double>()
      .where((v) => v > 0)
      .toList();
  return (rest: rest, balance: balance, fee: fee, amounts: amounts);
}

// Owner's rule: in a message that says "... وخصم 50 جنيه من محفظتك" the amount
// named there is what left the wallet, whatever else the message mentions.
final _walletDeductRe = RegExp(
  'و?خصم\\s*(?:مبلغ\\s*)?(?:$_cur\\s*)?$_amt\\s*(?:$_cur)?\\s*'
  '(?:رسوم\\s*)?من\\s*(?:رصيد\\s*)?(?:محفظتك|رصيدك|حسابك)',
);

/// Returns null when the message is not a completed wallet transaction.
Parsed? parseSms(String sender, String rawBody) {
  final body = normalizeDigits(rawBody);
  final wallet = detectWallet(sender, body);
  if (wallet == null) return null;
  if (_skip.hasMatch(body.toLowerCase())) return null;

  // A message that only reports a balance has no amount left after the balance
  // is removed, so it is not recorded as a transaction.
  final ex = _extract(body, true);
  final dedMatch = _walletDeductRe.firstMatch(body);
  final dedAmount = dedMatch == null ? null : _num(dedMatch.group(1));
  final viaWalletDeduction = dedAmount != null && dedAmount > 0;

  var fee = ex.fee;
  var amounts = ex.amounts;
  var feeOnly = false;
  if (amounts.isEmpty) {
    if (viaWalletDeduction) {
      amounts = [dedAmount!];
    } else if (fee > 0) {
      amounts = [fee];
      fee = 0;
      feeOnly = true;
    } else {
      return null;
    }
  }
  final amount = viaWalletDeduction ? dedAmount! : amounts.first;
  var review = !viaWalletDeduction && amounts.toSet().length > 1;

  final l = ex.rest.toLowerCase();
  TxType type;
  if (feeOnly) {
    type = TxType.fee;
  } else if (_refund.hasMatch(l)) {
    type = TxType.refund;
  } else if (_topup.hasMatch(l)) {
    type = TxType.topup;
  } else if (_bill.hasMatch(l)) {
    type = TxType.bill;
  } else if (_cashOut.hasMatch(l)) {
    type = TxType.cashOut;
  } else if (_cashIn.hasMatch(l)) {
    type = TxType.cashIn;
  } else if (_payment.hasMatch(l)) {
    type = TxType.payment;
  } else if (_transfer.hasMatch(l)) {
    type = TxType.transfer;
  } else if (_deduction.hasMatch(l)) {
    type = TxType.deduction;
  } else {
    type = TxType.other;
  }
  final hasDeduction = _deduction.hasMatch(l);
  if (viaWalletDeduction &&
      (type == TxType.other || type == TxType.refund || type == TxType.cashIn)) {
    type = TxType.deduction;
  }

  final fromM = _fromRe.firstMatch(l);
  final toM = _toRe.firstMatch(l);

  Dir wordsDir() {
    final sIn = _strongIn.hasMatch(l);
    final sOut = _strongOut.hasMatch(l);
    if (sIn && !sOut) return Dir.inFlow;
    if (sOut && !sIn) return Dir.outFlow;
    if (_toMe.hasMatch(l) && !_fromMe.hasMatch(l)) return Dir.inFlow;
    if (_fromMe.hasMatch(l) && !_toMe.hasMatch(l)) return Dir.outFlow;
    if (fromM != null && toM == null) return Dir.inFlow;
    if (toM != null && fromM == null) return Dir.outFlow;
    return Dir.unknown;
  }

  Dir dir;
  switch (type) {
    case TxType.refund:
    case TxType.cashIn:
      dir = Dir.inFlow;
    case TxType.deduction:
    case TxType.cashOut:
    case TxType.bill:
    case TxType.payment:
    case TxType.fee:
      dir = Dir.outFlow;
    case TxType.topup:
      // "تم شحن محفظتك" (wallet credited) vs "شحن رصيد" (airtime bought):
      // when the text mentions the wallet we cannot tell, so ask the user.
      dir = _walletWord.hasMatch(l) ? wordsDir() : Dir.outFlow;
    case TxType.transfer:
    case TxType.other:
      dir = wordsDir();
  }

  // "وخصم X من محفظتك" always means money left the wallet.
  if (viaWalletDeduction) dir = Dir.outFlow;

  // Only transfers (with a known direction), explicit deductions and the
  // "وخصم X من محفظتك" rule are counted automatically. Everything else waits for
  // the owner's confirmation.
  final counted = viaWalletDeduction ||
      (type == TxType.transfer && dir != Dir.unknown) ||
      type == TxType.deduction ||
      (hasDeduction && dir == Dir.outFlow);
  if (!counted) review = true;

  final cuePhone = dir == Dir.inFlow ? fromM?.group(1) : toM?.group(1);
  final party = cuePhone ?? _phoneRe.firstMatch(ex.rest)?.group(0);

  return Parsed(
    wallet: wallet,
    type: type,
    dir: dir,
    amount: amount,
    fee: fee,
    party: party,
    balance: ex.balance,
    review: review,
  );
}
