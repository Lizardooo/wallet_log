import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/parser.dart';

// NOTE: these sample messages are invented. Replace them with (redacted)
// copies of your real wallet SMS to tune the parser.
void main() {
  test('Vodafone Cash incoming (English)', () {
    final p = parseSms('VF-Cash',
        'You have received 1,250.50 EGP from 01012345678. Your balance is EGP 3,400.00');
    expect(p, isNotNull);
    expect(p!.wallet, 'Vodafone Cash');
    expect(p.dir, Dir.inFlow);
    expect(p.amount, 1250.50);
    expect(p.party, '01012345678');
    expect(p.balance, 3400.00);
  });

  test('InstaPay outgoing (Arabic digits)', () {
    final p = parseSms('InstaPay', 'تم تحويل ٥٠٠ جنيه بنجاح. رصيدك الحالي ٢٠٠٠ جنيه');
    expect(p, isNotNull);
    expect(p!.dir, Dir.outFlow);
    expect(p.amount, 500);
    expect(p.balance, 2000);
  });

  test('Promo message is ignored', () {
    expect(parseSms('Orange', 'Get 5GB for only 50 EGP this week!'), isNull);
  });
}
