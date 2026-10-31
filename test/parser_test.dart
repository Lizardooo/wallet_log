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
    final r = p('InstaPay', 'تم تحويل ٥٠٠ جنيه إلى 01112345678. رصيدك الحالي ٢٠٠٠ جنيه');
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
    final out = p('VF-Cash', 'تم سحب مبلغ 1000 جنيه من ATM. الرسوم 10 جنيه. رصيدك 4000 جنيه');
    expect(out.type, TxType.cashOut);
    expect(out.dir, Dir.outFlow);
    expect(out.fee, 10);
    expect(out.review, isTrue);
    final inn = p('VF-Cash', 'تم ايداع 2000 جنيه في محفظتك. رصيدك الحالي 5000 جنيه');
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

  test('ambiguous direction is flagged, not guessed', () {
    final r = p('Orange Cash', 'تم تحويل 100 جنيه');
    expect(r.dir, Dir.unknown);
    expect(r.review, isTrue);
  });

  test('OTP, failed, promo and balance-only messages are ignored', () {
    expect(parseSms('VF-Cash', 'الرقم السري المؤقت للسحب هو 482913 لسحب 500 جنيه'), isNull);
    expect(parseSms('VF-Cash', 'فشلت عملية التحويل بمبلغ 500 جنيه'), isNull);
    expect(parseSms('VF-Cash', 'عرض خاص: اشحن بـ 20 جنيه واحصل على 5GB'), isNull);
    expect(parseSms('VF-Cash', 'Your balance is EGP 3,400.00'), isNull);
  });
}
