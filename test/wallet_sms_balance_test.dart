import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/parser.dart';
import 'package:wallet_log/wallet_sms_balance.dart';

void main() {
  const accounts = [
    Account(
        id: 1,
        name: 'A',
        wallet: 'Vodafone Cash',
        number: '01011111111',
        subId: 11),
    Account(
        id: 2,
        name: 'B',
        wallet: 'Vodafone Cash',
        number: '01022222222',
        subId: 22),
    Account(
        id: 3,
        name: 'C',
        wallet: 'Orange Cash',
        number: '01211111111',
        subId: 33),
  ];
  RawSms sms(int time, String body, {int? subId = 11}) =>
      RawSms('VF-Cash', body, time, subId);

  test('balance-only SMS is read but not invented as a transaction', () {
    const body = 'رصيد محفظتك الحالي 295.90 جنيه';
    expect(parseSms('VF-Cash', body), isNull);
    final result = latestSmsBalances([sms(100, body)], accounts);
    expect(result[1]!.minor, 29590);
    expect(result[1]!.ts, 100);
  });
  test('latest timestamp wins regardless of inbox order and zero is valid', () {
    final result = latestSmsBalances([
      sms(200, 'رصيد محفظتك 0 جنيه'),
      sms(100, 'رصيد محفظتك 500 جنيه'),
    ], accounts);
    expect(result[1]!.minor, 0);
    expect(result[1]!.ts, 200);
  });
  test('same provider on two SIMs never leaks a balance across accounts', () {
    final result = latestSmsBalances([
      sms(100, 'رصيد محفظتك 100 جنيه'),
      sms(200, 'رصيد محفظتك 900 جنيه', subId: 22),
      sms(300, 'رصيد محفظتك 999 جنيه', subId: 44),
      sms(400, 'رصيد محفظتك 777 جنيه', subId: null),
    ], accounts);
    expect(result[1]!.minor, 10000);
    expect(result[2]!.minor, 90000);
    expect(result.containsKey(3), false);
  });
  test('no balance remains unknown, not zero or transaction amount', () {
    expect(
        latestSmsBalances(
            [sms(100, 'تم تحويل 500 جنيه إلى 01000000000')], accounts),
        isEmpty);
  });
  test('pending, failed, ambiguous and unknown-sender balances are ignored',
      () {
    expect(statedWalletBalance('BankUnknown', 'رصيد محفظتك 500 جنيه'), isNull);
    expect(statedWalletBalance('VF-Cash', 'pending balance 500 EGP'), isNull);
    expect(
        statedWalletBalance(
            'VF-Cash', 'رصيد محفظتك 10 جنيه. الرصيد الحالي 20 جنيه'),
        isNull);
  });
  test('conflicting balances with equal timestamps stay unknown', () {
    final result = latestSmsBalances([
      sms(100, 'رصيد محفظتك 100 جنيه'),
      sms(100, 'رصيد محفظتك 200 جنيه'),
      sms(100, 'رصيد محفظتك 100 جنيه'),
    ], accounts);
    expect(result, isEmpty);
  });
  test('opening suggestion excludes all messages at or after local day start',
      () {
    final today = DateTime(2026, 11, 22).millisecondsSinceEpoch;
    final result = latestSmsBalances([
      sms(today - 1, 'رصيد محفظتك 100 جنيه'),
      sms(today, 'رصيد محفظتك 800 جنيه'),
      sms(today + 1000, 'رصيد محفظتك 900 جنيه'),
    ], accounts, before: today);
    expect(result[1]!.minor, 10000);
    expect(result[1]!.ts, today - 1);
  });
  test('Arabic digits and comma separators retain exact piasters', () {
    final result =
        latestSmsBalances([sms(100, 'رصيد محفظتك ١٬٢٣٤٫٥٦ جنيه')], accounts);
    expect(result[1]!.minor, 123456);
    final western =
        latestSmsBalances([sms(100, 'رصيد محفظتك ١,٢٣٤.٥٦ جنيه')], accounts);
    expect(western[1]!.minor, 123456);
  });
}
