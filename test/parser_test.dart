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
  });

  test('bill payment with fee', () {
    final r = p('VF-Cash',
        'تم دفع فاتورة الكهرباء بمبلغ 320.75 جنيه ورسوم 5 جنيه. رصيدك الحالي 1000 جنيه');
    expect(r.type, TxType.bill);
    expect(r.amount, 320.75);
    expect(r.fee, 5);
    expect(r.balance, 1000);
  });

  test('cash out and cash in', () {
    final out = p('VF-Cash', 'تم سحب مبلغ 1000 جنيه من ATM. الرسوم 10 جنيه. رصيدك 4000 جنيه');
    expect(out.type, TxType.cashOut);
    expect(out.dir, Dir.outFlow);
    expect(out.fee, 10);
    final inn = p('VF-Cash', 'تم ايداع 2000 جنيه في محفظتك. رصيدك الحالي 5000 جنيه');
    expect(inn.type, TxType.cashIn);
    expect(inn.dir, Dir.inFlow);
  });

  test('fee only message', () {
    final r = p('VF-Cash', 'تم خصم رسوم 5 جنيه. رصيدك الحالي 1995 جنيه');
    expect(r.type, TxType.fee);
    expect(r.amount, 5);
    expect(r.balance, 1995);
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
