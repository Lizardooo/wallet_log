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
  '(?:(?!مبلغ|\\sبـ?\\s?\\d)\\D){0,40}?(?:$_cur\\s*)?$_amt',
  caseSensitive: false,
);

final _limitRe = RegExp(
  '(?:limit|remaining|available|الحد|المتبقي|المتاح)'
  '\\D{0,25}?(?:$_cur\\s*)?$_amt(?:\\s*$_cur)?',
  caseSensitive: false,
);

// "رسوم 5 جنيه" and the Vodafone Cash form "و 2.34 جنيه رسوم خدمة".
final _feeRe = RegExp(
  '(?:fees?|commission|charges?|رسوم|عمولة|مصاريف)'
  '\\D{0,20}?(?:$_cur\\s*)?$_amt(?:\\s*$_cur)?|'
  '$_amt\\s*$_cur\\s*(?:رسوم|عمولة|مصاريف|fees?|commission)',
  caseSensitive: false,
);

/// Folds the spelling variants wallet SMS use for the same word (أ/إ/آ → ا,
/// ى → ي, ة → ه, no tatweel or diacritics), so "إستلام", "استلام" and
/// "الحالى" / "الحالي" are matched by one rule. Only used for keyword matching;
/// amounts and stored text are never changed.
String normalizeArabic(String s) => s
    .replaceAll(RegExp('[أإآٱ]'), 'ا')
    .replaceAll('ى', 'ي')
    .replaceAll('ة', 'ه')
    .replaceAll(RegExp('[\u0640\u064B-\u0652]'), '');

/// Keyword regexes are written in normal spelling and matched against text
/// folded by [normalizeArabic], so the pattern is folded the same way.
RegExp _ar(String pattern) => RegExp(normalizeArabic(pattern));

RegExp _cat(List<String> en, List<String> ar) {
  final parts = <String>[];
  if (en.isNotEmpty) parts.add('(?<![a-z])(?:${en.join('|')})(?![a-z])');
  // "تم ..." must be a word of its own: "سيتم خصم" (will deduct) and "هيتم"
  // contain "تم خصم" but announce a future operation.
  final words =
      ar.map((w) => w.startsWith('تم') ? '(?<![\u0621-\u064A])$w' : w);
  if (ar.isNotEmpty) parts.add('(?:${words.join('|')})');
  return _ar(parts.join('|'));
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
  ],
);

// Messages that look financial but report no completed money movement. Wallets
// send many of these around a real transaction: the request to confirm a
// payment ("لتأكيد دفع مبلغ 468.30 جنيه لـ MYFAWRY_BP ... اطلب #55*9*"), a
// money / payment request from someone else, a cash-out code, a statement or
// "last transactions" list. They are never recorded, whatever else they say.
final _notTransaction = _cat(
  [
    'to confirm',
    'to complete',
    'confirm (?:the |your )?(?:payment|transfer|transaction|withdrawal)',
    'do you want',
    'reply with',
    'payment request',
    'money request',
    'collect(?:ion)? request',
    'request(?:ed|s)? (?:money|payment|to pay|you)',
    'request(?:ed|s)? [^.]{0,40}?from you',
    'withdrawal code',
    'cash ?-?out code',
    'valid (?:for|until|till)',
    'mini ?-?statement',
    'last \\d+ transactions',
  ],
  [
    'لتأكيد',
    'للتأكيد',
    '(?:برجاء|يرجى|رجاء|من فضلك)\\s*(?:ال)?تأكيد',
    'لإتمام',
    'لاستكمال',
    'لاكمال',
    'لإكمال',
    'عشان\\s*(?:تأكد|تكمل|تتمم)',
    'لو\\s*عايز\\s*تكمل',
    'هل تريد',
    'لديك طلب',
    'عندك طلب',
    'ب?يطلب منك',
    'طلب منك',
    'طلب\\s*(?:تحويل|دفع|تحصيل|سحب|أموال|اموال|فلوس)\\s*(?:من|بمبلغ|ب)',
    'طلب تحصيل',
    '(?:كود|رمز|كود رمز)\\s*(?:ال)?(?:سحب|استلام|صرف)',
    'صالح(?:ة)?\\s*(?:لمدة|حتى|لغاية)',
    'كشف حساب',
    'آخر\\s*\\d+\\s*(?:عمليات|معاملات|حركات)',
  ],
);

// Reminders, future / scheduled notices and account administration (wallet
// activation, PIN change, limits, suspension). They are dropped unless the
// message also states a completed money movement ([_completedMove]): "تم تحويل
// 100 جنيه ... وسيتم إضافة الكاش باك" is still a transfer.
final _notice = _cat(
  [
    'reminder',
    'remind',
    'due',
    'will be',
    'upcoming',
    'scheduled',
    'activated',
    'activation',
    'register(?:ed)?',
    'registration',
    'pin',
    'password',
    'suspended',
    'blocked',
  ],
  [
    'تذكير',
    'نذكرك',
    'نود تذكيرك',
    'لا تنس',
    'متنساش',
    'موعد',
    'استحقاق',
    'مستحق',
    'سيتم',
    'هيتم',
    'سوف',
    'تفعيل',
    'تسجيل',
    'الرقم السري',
    'الرقم السرى',
    'كلمة (?:المرور|السر)',
    'تحديث (?:ال)?بيانات',
    'إيقاف',
    'تجميد',
    'حظر',
  ],
);

final _completedMove = _cat(
  [
    // "will be debited" is a notice, not a completed movement.
    '(?<!will be )(?<!will )(?:received|credited|debited|paid|sent|'
        'transferred|withdrawn|deposited)',
  ],
  [
    'تمت?\\s*(?:عملية\\s*)?(?:ال)?(?:استلام|تحويل|إرسال|ارسال|سحب|إيداع|ايداع|دفع|شحن|خصم|إضافة|اضافة|سداد|استرداد|شراء)',
    'استلمت',
    'حولت',
    'دفعت',
    'وصلك',
    'وصلتك',
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
  [
    'تحويل',
    'حول',
    'استلام',
    'استلمت',
    'وصلك',
    'وصلتك',
    'ارسال',
    'إرسال',
    'ارسلت',
    'أرسلت',
    'استقبال',
  ],
);

final _strongIn = _cat(
  [
    'received',
    'receive',
    'credited',
    'deposit(?:ed)?',
    'refund(?:ed)?',
    'incoming',
  ],
  [
    'استلمت',
    'استلام',
    'وصلك',
    'وصلتك',
    'وارد',
    'تمت إضافة',
    'أضيف',
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
  [
    'ارسال',
    'إرسال',
    'ارسلت',
    'أرسلت',
    'حولت',
    'قمت بتحويل',
    'صادر',
    'دفع',
    'سحب',
    'خصم',
    'شراء',
    'سداد',
  ],
);

// Matched against text folded by [normalizeArabic] (so "إلى" reads "الي").
final _fromRe = RegExp(
  r'(?:من|(?<![a-z])from)\s*(?:ال)?(?:رقم\s*|number\s*)?(01\d{9})',
);
final _toRe = RegExp(
  r'(?:(?:الي|الى)\s*(?:ال)?(?:رقم\s*)?|(?<![\u0621-\u064A])لل?\s*(?:رقم\s*)?|'
  r'(?<![a-z])to\s*(?:number\s*)?)(01\d{9})',
);
final _toMe = RegExp(
  r'(?:إلى|الى|إلي|الي|(?<![a-z])to)\s*(?:محفظتك|حسابك|رصيدك|your\s+(?:wallet|account))',
);
final _fromMe = RegExp(
  r'(?:من|(?<![a-z])from)\s*(?:محفظتك|حسابك|رصيدك|your\s+(?:wallet|account))',
);
final _walletWord = RegExp(r'محفظ|wallet');
final _phoneRe = RegExp(r'01\d{9}');

/// Stable across app and Dart versions (String.hashCode is not guaranteed to be).
int stableHash(String s) {
  var h = 0x811c9dc5;
  for (final u in s.codeUnits) {
    h ^= u;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// Duplicate-detection key for an SMS. Kept here (not in the database layer) so
/// the Excel importer can build keys without touching SQLite.
String smsKey(String body, int ts) =>
    '${stableHash(body.trim())}|${ts ~/ 300000}';

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

/// Trusted sender patterns per wallet provider. A message is a wallet message
/// only when its sender matches; wording in the body is never enough, because a
/// customer-written or phishing SMS can say anything. The body only picks
/// between providers when the sender itself is shared (e.g. a generic "Cash").
bool _isWePay(String s) => RegExp(r'we\s*-?\s*pay').hasMatch(s);

bool _trustedSender(String s) =>
    s.contains('cash') ||
    _isWePay(s) ||
    s.contains('instapay') ||
    s.contains('fawry') ||
    s.contains('vf') ||
    s.contains('vodafone') ||
    s.contains('orange') ||
    s.contains('etisalat') ||
    s.contains('e&');

String? detectWallet(String sender, String body) {
  final s = sender.toLowerCase();
  final b = body.toLowerCase();
  if (!_trustedSender(s)) return null;
  if (s.contains('instapay')) return 'InstaPay';
  if (_isWePay(s)) return 'WE Pay';
  if (s.contains('orange')) return 'Orange Cash';
  if (s.contains('vodafone') || s.contains('vf')) return 'Vodafone Cash';
  if (s.contains('etisalat') || s.contains('e&') || s.contains('fawry')) {
    return 'Etisalat Cash / Fawry';
  }
  // Generic "...cash" sender: let the body choose the provider.
  if (b.contains('instapay') || b.contains('انستا') || b.contains('إنستا')) {
    return 'InstaPay';
  }
  if (b.contains('orange') || b.contains('اورنج') || b.contains('أورنج')) {
    return 'Orange Cash';
  }
  if (b.contains('vodafone') || b.contains('فودافون')) return 'Vodafone Cash';
  if (_isWePay(b) || b.contains('وي باي')) return 'WE Pay';
  if (b.contains('etisalat') ||
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
    fee = _num(f.group(1) ?? f.group(2)) ?? 0;
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

// Promotional sentences (cash-back offers, "transfer money and win...") often
// follow the real transaction text. They are removed before parsing so their
// amounts ("100ج كاش باك") are never mistaken for the transaction.
final _promo = _ar(
  r'(?<![a-z])(?:cash\s*back|offers?|promo(?:tion)?|win|enjoy|hurry|discount|'
  r'coupon|download|limited\s+time|\d+\s*%\s*off)(?![a-z])|'
  r'(?<![\u0621-\u064A])(?:كاش\s*باك|فرصك|فرصة|تكسب|جنيه\s*(?:دهب|ذهب)|هيجيلك|'
  r'حول\s+فلوس|عرض|عروض|احصل\s+على|اشحن|اربح|سارع|استمتع|خصم\s*\d+\s*%|'
  r'\d+\s*%\s*خصم|كوبون|مسابقة|السحب\s+على|حمل\s+(?:تطبيق|ابلكيشن|أبلكيشن)|'
  r'لفترة\s+محدودة|بادر)',
);

// Cash-back, rewards, points and gifts are not money movements. The phrase and
// the amount next to it are removed even when it sits inside a real sentence.
final _rewardWord =
    r'(?:(?<![a-z])(?:cash\s*-?\s*back|rewards?|bonus|gift|points?)(?![a-z])|'
    r'كاش\s*-?\s*باك|استرداد\s*نقدي|مكاف[أا][ةه]|هدي[ةه]|هدايا|نقاط|بونص|جائز[ةه]|'
    r'جنيه\s*(?:دهب|ذهب))';
const _rewardAmt = r'\d[\d,]*(?:\.\d+)?\s*(?:EGP|LE|جنيه|جنية|ج\.م|ج)?';
final _reward = RegExp(
  '$_rewardWord[^.!؟?\\n]{0,40}?$_rewardAmt|$_rewardAmt\\s*$_rewardWord',
  caseSensitive: false,
);

String _stripPromo(String s) {
  final noUrl = s
      .replaceAll(RegExp(r'(?:https?://|www\.)\S+', caseSensitive: false), ' ')
      .replaceAll(_reward, ' ');
  // Split on sentence ends only (". " / "! "), so decimals like 114.29 survive.
  return noUrl
      .split(RegExp(r'(?<=[.!؟?])\s+'))
      .where((part) => !_promo.hasMatch(normalizeArabic(part.toLowerCase())))
      .join(' ');
}

// Owner's rule: in a message that says "... وخصم 50 جنيه من محفظتك" the amount
// named there is what left the wallet, whatever else the message mentions.
final _walletDeductRe = RegExp(
  'و?خصم\\s*(?:مبلغ\\s*)?(?:$_cur\\s*)?$_amt\\s*(?:$_cur)?\\s*'
  '(?:رسوم\\s*)?من\\s*(?:رصيد\\s*)?(?:محفظتك|رصيدك|حسابك)',
);

/// Returns null when the message is not a completed wallet transaction.
Parsed? parseSms(String sender, String rawBody) {
  final full = normalizeDigits(rawBody);
  final wallet = detectWallet(sender, full); // the link / footer helps here
  if (wallet == null) return null;
  final body = _stripPromo(full);
  final folded = normalizeArabic(body.toLowerCase());
  if (_skip.hasMatch(folded)) return null;
  if (_notTransaction.hasMatch(folded)) return null;
  if (_notice.hasMatch(folded) && !_completedMove.hasMatch(folded)) {
    return null;
  }

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
  if (viaWalletDeduction) fee = 0; // X already includes any fee / tax
  final amount = viaWalletDeduction ? dedAmount! : amounts.first;
  var review = !viaWalletDeduction && amounts.toSet().length > 1;

  final l = normalizeArabic(ex.rest.toLowerCase());
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
  // No operation word at all (a number in an ad, notice or news message):
  // this is not a transaction, so it is ignored instead of flagged for review.
  if (type == TxType.other && !viaWalletDeduction) return null;
  final hasDeduction = _deduction.hasMatch(l);
  if (viaWalletDeduction &&
      (type == TxType.other ||
          type == TxType.refund ||
          type == TxType.cashIn)) {
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

/// Best-effort operation type from free text (used by the Excel import).
TxType typeFromText(String text) {
  final l = normalizeDigits(text).toLowerCase();
  if (_refund.hasMatch(l)) return TxType.refund;
  if (_topup.hasMatch(l)) return TxType.topup;
  if (_bill.hasMatch(l)) return TxType.bill;
  if (_cashOut.hasMatch(l)) return TxType.cashOut;
  if (_cashIn.hasMatch(l)) return TxType.cashIn;
  if (_payment.hasMatch(l)) return TxType.payment;
  if (_transfer.hasMatch(l)) return TxType.transfer;
  if (_deduction.hasMatch(l)) return TxType.deduction;
  if (RegExp(r'رسوم|عمولة|fee').hasMatch(l)) return TxType.fee;
  return TxType.other;
}

/// Direction from a label such as "وارد" / "خارج" / "credit" / "debit".
Dir dirFromText(String text) {
  final l = normalizeDigits(text).trim().toLowerCase();
  if (l.isEmpty) return Dir.unknown;
  bool has(List<String> words) => words.any((w) => l.contains(w));
  final inAr =
      has(['وارد', 'داخل', 'دائن', 'استلام', 'استلمت', 'ايداع', 'إيداع']);
  final outAr =
      has(['صادر', 'خارج', 'مدين', 'ارسال', 'إرسال', 'سحب', 'دفع', 'خصم']);
  final tokens =
      l.split(RegExp(r'[^a-z+\-]+')).where((t) => t.isNotEmpty).toSet();
  const inLatin = {'in', 'credit', 'received', 'income', 'cr', '+'};
  const outLatin = {'out', 'debit', 'sent', 'expense', 'dr', '-'};
  final i = inAr || tokens.any((t) => inLatin.contains(t));
  final o = outAr || tokens.any((t) => outLatin.contains(t));
  if (i && !o) return Dir.inFlow;
  if (o && !i) return Dir.outFlow;
  return Dir.unknown;
}

/// Wallet name from free text, or null when it is not recognisable.
String? walletFromText(String text) {
  final t = text.toLowerCase();
  if (t.contains('instapay') || t.contains('انستا')) return 'InstaPay';
  if (t.contains('orange') || t.contains('اورنج') || t.contains('أورنج')) {
    return 'Orange Cash';
  }
  if (t.contains('vodafone') || t.contains('فودافون')) return 'Vodafone Cash';
  if (_isWePay(t) || t.contains('وي باي')) return 'WE Pay';
  if (t.contains('etisalat') ||
      t.contains('اتصالات') ||
      t.contains('e&') ||
      t.contains('fawry') ||
      t.contains('فوري')) {
    return 'Etisalat Cash / Fawry';
  }
  return null;
}

/// Strict rule for keeping a message from an unknown sender in the opt-in
/// review inbox: an alphanumeric sender (not a person's phone number), a
/// currency amount, a money-movement word and a wallet word, and none of the
/// OTP / failure / promo markers. It only decides what is shown for review.
bool isWalletCandidate(String sender, String rawBody) {
  final s = sender.trim();
  if (s.isEmpty || !RegExp(r'[A-Za-z\u0621-\u064A]').hasMatch(s)) return false;
  final body = normalizeDigits(rawBody);
  if (!_amountRe.hasMatch(body)) return false;
  final low = normalizeArabic(body.toLowerCase());
  if (_skip.hasMatch(low) ||
      _promo.hasMatch(low) ||
      _notTransaction.hasMatch(low) ||
      (_notice.hasMatch(low) && !_completedMove.hasMatch(low))) {
    return false;
  }
  final wallet =
      RegExp(r'محفظ|كاش|wallet|cash|instapay|انستا|إنستا').hasMatch(low);
  final move = RegExp(
          r'تحويل|تم\s+(?:ايداع|خصم|سحب|استلام)|حولت|transfer|deposit|withdraw|received|debited|credited|paid')
      .hasMatch(low);
  return wallet && move;
}

final _refRe = RegExp(
    r'(?:رقم\s*(?:العملية|العمليه|المرجع|المعاملة|المعامله|المرجعي)|reference(?:\s*(?:no|number|id))?|ref(?:\.|\s*no\.?|\s*#)?|trx(?:\s*id)?|transaction\s*(?:id|no|number))\s*[:：#\-]?\s*([A-Za-z0-9]{6,20})',
    caseSensitive: false);

/// The provider's reference / transaction number when the message states one.
/// Needs at least one digit so ordinary words are never taken as a reference.
String? extractReference(String body) {
  final m = _refRe.firstMatch(normalizeDigits(body));
  final v = m?.group(1);
  if (v == null || !RegExp(r'\d').hasMatch(v)) return null;
  return v.toUpperCase();
}
