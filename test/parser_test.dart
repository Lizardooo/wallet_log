import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/parser.dart';

// NOTE: these sample messages are invented, not real wallet templates.
// Replace them with (redacted) copies of your real SMS to tune the parser.
void main() {
  Parsed p(String sender, String body) {
    final r = parseSms(sender, body);
    expect(r, isNotNull, reason: body);
    return r!;
  }

  test('transfer received', () {
    final r = p('VF-Cash',
        'You have received 1,250.50 EGP from 01012345678. Your balance is EGP 3,400.00');
    expect(r.type, TxType.transfer);
    expect(r.dir, Dir.inFlow);
    expect(r.amount, 1250.50);
    expect(r.balance, 3400.00);
    expect(r.party, '01012345678');
    expect(r.review, isFalse);
  });

  test('transfer sent (Arabic digits)', () {
    final r = p('InstaPay',
        'تم تحويل ٥٠٠ جنيه إلى 01112345678. رصيدك الحالي ٢٠٠٠ جنيه');
    expect(r.dir, Dir.outFlow);
    expect(r.amount, 500);
    expect(r.balance, 2000);
  });

  test('phone top-up', () {
    final r = p('VF-Cash',
        'تم شحن رصيد 01012345678 بمبلغ 50 جنيه. رصيدك الحالي 450 جنيه');
    expect(r.type, TxType.topup);
    expect(r.dir, Dir.outFlow);
    expect(r.amount, 50);
    expect(r.review, isTrue); // not a transfer / deduction: waits for review
  });

  test('bill payment with fee', () {
    final r = p('VF-Cash',
        'تم دفع فاتورة الكهرباء بمبلغ 320.75 جنيه ورسوم 5 جنيه. رصيدك الحالي 1000 جنيه');
    expect(r.type, TxType.bill);
    expect(r.review, isTrue);
    expect(r.amount, 320.75);
    expect(r.fee, 5);
    expect(r.balance, 1000);
  });

  test('cash out and cash in', () {
    final out = p('VF-Cash',
        'تم سحب مبلغ 1000 جنيه من ATM. الرسوم 10 جنيه. رصيدك 4000 جنيه');
    expect(out.type, TxType.cashOut);
    expect(out.dir, Dir.outFlow);
    expect(out.fee, 10);
    expect(out.review, isTrue);
    final inn =
        p('VF-Cash', 'تم ايداع 2000 جنيه في محفظتك. رصيدك الحالي 5000 جنيه');
    expect(inn.type, TxType.cashIn);
    expect(inn.dir, Dir.inFlow);
    expect(inn.review, isTrue);
  });

  test('balance deduction is counted', () {
    final r = p('VF-Cash', 'تم خصم 50 جنيه من رصيدك. رصيدك الحالي 450 جنيه');
    expect(r.type, TxType.deduction);
    expect(r.dir, Dir.outFlow);
    expect(r.amount, 50);
    expect(r.balance, 450);
    expect(r.review, isFalse);
  });

  test('fee only message', () {
    final r = p('VF-Cash', 'تم خصم رسوم 5 جنيه. رصيدك الحالي 1995 جنيه');
    expect(r.type, TxType.fee);
    expect(r.amount, 5);
    expect(r.balance, 1995);
    expect(r.review, isFalse); // an explicit deduction is counted
  });

  test('"وخصم X من محفظتك" is always an outgoing, counted amount', () {
    final a = p('VF-Cash',
        'تم تحويل 200 جنيه الى 01012345678 وخصم 201 جنيه من محفظتك. رصيدك الحالي 800 جنيه');
    expect(a.dir, Dir.outFlow);
    expect(a.amount, 201);
    expect(a.balance, 800);
    expect(a.review, isFalse);
    final b = p('VF-Cash', 'تم شحن 50 جنيه وخصم 50 جنيه من محفظتك');
    expect(b.dir, Dir.outFlow);
    expect(b.amount, 50);
    expect(b.review, isFalse);
    final c = p('VF-Cash', 'تمت العملية بنجاح وخصم ٧٥ من محفظتك');
    expect(c.type, TxType.deduction);
    expect(c.amount, 75);
    expect(c.review, isFalse);
  });

  test('real Vodafone Cash top-up with promo footer', () {
    final r = p(
      'VF-Cash',
      'تم شحن رصيد موبايلك ب 80 بنجاح وخصم 114.29 من محفظتك شاملة الضريبة; '
          'رصيد حسابك في فودافون كاش الحالي 8.98. حول فلوس لأي محفظة وزود فرصك '
          'تكسب جنيه دهب! وكمان هيجيلك لحد 100ج كاش باك. '
          'http://vf.eg/vfcash?id=money_transfer',
    );
    expect(r.type, TxType.topup);
    expect(r.dir, Dir.outFlow);
    expect(r.amount, 114.29); // what left the wallet, not the 80 face value
    expect(r.balance, 8.98);
    expect(r.fee, 0);
    expect(r.review, isFalse);
  });

  test('promo footer amounts are never read as the transaction', () {
    final r = p('VF-Cash',
        'تم تحويل 100 جنيه الى 01012345678 بنجاح. رصيدك الحالي 900 جنيه. وكمان هيجيلك لحد 100 جنيه كاش باك! http://vf.eg/x');
    expect(r.amount, 100);
    expect(r.balance, 900);
  });

  test('ambiguous direction is flagged, not guessed', () {
    final r = p('Orange Cash', 'تم تحويل 100 جنيه');
    expect(r.dir, Dir.unknown);
    expect(r.review, isTrue);
  });

  test('OTP, failed, promo and balance-only messages are ignored', () {
    expect(
        parseSms('VF-Cash', 'الرقم السري المؤقت للسحب هو 482913 لسحب 500 جنيه'),
        isNull);
    expect(parseSms('VF-Cash', 'فشلت عملية التحويل بمبلغ 500 جنيه'), isNull);
    expect(
        parseSms('VF-Cash', 'عرض خاص: اشحن بـ 20 جنيه واحصل على 5GB'), isNull);
    expect(parseSms('VF-Cash', 'Your balance is EGP 3,400.00'), isNull);
  });

  test('cash-back and reward messages are not transactions', () {
    expect(
        parseSms('VF-Cash', 'مبروك! حصلت على 5 جنيه كاش باك على تحويلك الأخير'),
        isNull);
    expect(parseSms('VF-Cash', 'تم إضافة 10 جنيه مكافأة إلى محفظتك'), isNull);
    expect(parseSms('VF-Cash', 'رصيد حسابك في فودافون كاش 150 جنيه'), isNull);
  });

  test('cash-back inside a real transfer message is dropped, transfer kept',
      () {
    final r = p('VF-Cash',
        'تم تحويل 200 جنيه الى 01012345678 بنجاح وحصلت على 5 جنيه كاش باك. رصيدك الحالي 900 جنيه');
    expect(r.amount, 200);
    expect(r.review, isFalse);
  });

  test('telecom ads that merely mention Orange or Etisalat are ignored', () {
    expect(parseSms('Orange', 'باقة جديدة بـ 100 جنيه فقط مع اورنج، 20 جيجا'),
        isNull);
    expect(parseSms('Etisalat', 'جدد باقتك بمبلغ 50 جنيه واستمتع'), isNull);
  });

  test('body wording alone never makes an unknown sender a wallet', () {
    expect(parseSms('+201001234567', 'تم تحويل 500 جنيه من محفظة فودافون كاش'),
        isNull);
    expect(parseSms('Shop', 'Your wallet cash transfer of 100 EGP'), isNull);
  });

  group('non-transaction wallet messages are never recorded', () {
    const notTx = <String, String>{
      // The owner's example: Vodafone Cash asks to confirm a payment first.
      'confirm request (Vodafone Cash)':
          'لتأكيد دفع مبلغ 468.30 جنيه لـ MYFAWRY_BP و 2.34 جنيه رسوم خدمة من محفظة فودافون كاش؛ اطلب #55*9*',
      'confirm transfer request':
          'لتأكيد تحويل مبلغ 200 جنيه لرقم 01012345678 اطلب *9*1# وادخل الرقم السري',
      'please confirm': 'برجاء تأكيد عملية سحب 1000 جنيه من الماكينة',
      'English confirm request':
          'To confirm the payment of EGP 150.00 to Fawry, dial *9*55#',
      'money request':
          'لديك طلب تحويل بمبلغ 300 جنيه من رقم 01112345678، للموافقة اطلب *9#',
      'payment request English':
          '01012345678 requested EGP 250 from you via InstaPay. Open the app to pay.',
      'withdraw code':
          'كود السحب الخاص بك 123456 لسحب مبلغ 500 جنيه صالح لمدة 30 دقيقة',
      'reminder':
          'تذكير: موعد سداد فاتورة الإنترنت 250 جنيه يوم 5 من الشهر. ادفعها من فودافون كاش',
      'future deduction':
          'سيتم خصم 5 جنيه رسوم اشتراك الخدمة الشهرية من محفظتك',
      'English future debit':
          'Reminder: EGP 50 will be debited from your wallet on 01/12 for your subscription',
      'wallet activation':
          'تم تفعيل محفظة فودافون كاش بنجاح، يمكنك تحويل حتى 60000 جنيه شهرياً',
      'pin change': 'تم تغيير الرقم السري لمحفظتك. الحد اليومي 30000 جنيه',
      'statement': 'آخر 3 عمليات: تحويل 100 جنيه، سحب 200 جنيه، شحن 10 جنيه',
      'promotion with discount':
          'خصم 20% على مشترياتك بفودافون كاش لحد 50 جنيه، لفترة محدودة',
      'pending': 'عملية تحويل 100 جنيه قيد التنفيذ',
      'rejected': 'تم رفض عملية تحويل 100 جنيه لعدم كفاية الرصيد',
    };
    for (final e in notTx.entries) {
      test(e.key, () {
        expect(parseSms('VF-Cash', e.value), isNull, reason: e.value);
        expect(isWalletCandidate('Bank', e.value), isFalse, reason: e.value);
      });
    }
  });

  group('completed wallet messages keep working', () {
    test('Vodafone Cash payment with fee written after the amount', () {
      final r = p('VF-Cash',
          'تم دفع 468.30 جنيه لـ MYFAWRY_BP و 2.34 جنيه رسوم خدمة من محفظة فودافون كاش. رصيدك الحالي 1200 جنيه');
      expect(r.type, TxType.payment);
      expect(r.dir, Dir.outFlow);
      expect(r.amount, 468.30);
      expect(r.fee, 2.34);
      expect(r.balance, 1200);
    });

    test('Vodafone Cash receive with sender name and transaction number', () {
      final r = p('VF-Cash',
          'تم استلام مبلغ 500.00 جنيه من رقم 01012345678؛ المسجل باسم AHMED ALI رصيد حسابك في فودافون كاش الحالي 1,250.00 جنيه. رقم العملية 012345678901');
      expect(r.type, TxType.transfer);
      expect(r.dir, Dir.inFlow);
      expect(r.amount, 500);
      expect(r.balance, 1250);
      expect(r.party, '01012345678');
      expect(r.review, isFalse);
    });

    test('transfer "لرقم" is outgoing to that number', () {
      final r = p('VF-Cash',
          'تم تحويل 200 جنيه لرقم 01112345678 المسجل باسم MONA; رسوم الخدمة 1 جنيه. رصيدك الحالي 300 جنيه');
      expect(r.dir, Dir.outFlow);
      expect(r.amount, 200);
      expect(r.fee, 1);
      expect(r.party, '01112345678');
      expect(r.review, isFalse);
    });

    test('Etisalat spelling variants (إستلام / الحالى)', () {
      final r = p('Etisalat Cash',
          'تم إستلام 150 جنيه من 01112345678. رصيدك الحالى 400 جنيه');
      expect(r.dir, Dir.inFlow);
      expect(r.amount, 150);
      expect(r.balance, 400);
    });

    test('completed transfer that mentions a future cash-back stays', () {
      final r = p('VF-Cash',
          'تم تحويل 100 جنيه الى 01012345678 بنجاح وسيتم إضافة 2 جنيه كاش باك خلال 48 ساعة');
      expect(r.amount, 100);
      expect(r.dir, Dir.outFlow);
    });

    test('English receipt with a security footer stays', () {
      final r = p('InstaPay',
          'You have received EGP 500.00 from 01012345678. Never share your PIN with anyone.');
      expect(r.dir, Dir.inFlow);
      expect(r.amount, 500);
    });

    test('WE Pay sender is a wallet', () {
      final r =
          p('WE Pay', 'تم استلام 75 جنيه من 01512345678. رصيدك الحالي 90 جنيه');
      expect(r.wallet, 'WE Pay');
      expect(r.dir, Dir.inFlow);
    });
  });
}
