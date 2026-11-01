import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/exclusions.dart';
import 'package:wallet_log/exporter.dart';
import 'package:wallet_log/logic.dart';
import 'package:wallet_log/parser.dart';

Tx tx(int id, DateTime day,
        {TxDisposition state = TxDisposition.active,
        double amount = 100,
        double? balance,
        bool review = false}) =>
    Tx(
      id: id,
      ts: day.millisecondsSinceEpoch,
      wallet: 'Vodafone Cash',
      type: TxType.transfer,
      dir: Dir.inFlow,
      amount: amount,
      balance: balance,
      party: '01012345678',
      disposition: state,
      review: review,
    );
void main() {
  test('normalization does not turn changed amounts into an exact match', () {
    const rule = ExclusionRule(
        id: 1,
        wallet: 'Vodafone Cash',
        match: ExclusionMatch.exact,
        text: '  ABC ١٠٠ جنيه  ');
    expect(rule.matches('Vodafone Cash', 'abc  100 جنيه'), isTrue);
    expect(rule.matches('Vodafone Cash', 'abc 200 جنيه'), isFalse);
    expect(rule.matches('Orange Cash', 'abc 100 جنيه'), isFalse);
    expect(
        const ExclusionRule(
                id: 2,
                wallet: 'Vodafone Cash',
                match: ExclusionMatch.contains,
                text: ' ')
            .matches('Vodafone Cash', 'anything'),
        isFalse);
  });
  for (final state in [
    TxDisposition.deferred,
    TxDisposition.ignored,
    TxDisposition.duplicate
  ]) {
    test('$state is absent from every accounting aggregation', () {
      final excluded =
          tx(1, DateTime(2026, 11, 1), state: state, balance: 99999);
      final totals = totalsOf([excluded]);
      expect(totals.count, 0);
      expect(totals.inSum + totals.outSum + totals.fee, 0);
      expect(totals.pending + totals.unknown, 0);
      expect(TxFilter().matches(excluded, []), isFalse);
      expect(TxFilter().matchesBase(excluded, []), isFalse);
      expect((TxFilter()..reviewOnly = true).matches(excluded, []), isFalse);
      expect(typeStats([excluded]), isEmpty);
      expect(partyStats([excluded]), isEmpty);
      expect(accountStats([excluded], []), isEmpty);
      expect(balanceMismatches([excluded], []), isEmpty);
      expect(dailyRows('2026-11-01', [excluded], [], {}), isEmpty);
    });
  }
  test('ignored balances cannot become an opening or reported balance', () {
    const account = Account(id: 1, name: 'wallet', wallet: 'Vodafone Cash');
    final rows = [
      tx(4, DateTime(2026, 11, 2, 20),
          state: TxDisposition.ignored, balance: 99999),
      tx(3, DateTime(2026, 11, 2, 12), balance: 1100),
      tx(2, DateTime(2026, 11, 1, 23),
          state: TxDisposition.ignored, balance: 88888),
      tx(1, DateTime(2026, 11, 1, 12), balance: 1000),
    ];
    final daily = dailyRows('2026-11-02', rows, [account], {}).single;
    expect(daily.opening, 1000);
    expect(daily.reported, 1100);
    expect(daily.count, 1);
    expect(daily.diff, 0);
    expect(balanceMismatches(rows, [account]), isEmpty);
  });
  test('Excel export excludes all dispositions, including their summary rows',
      () {
    final rows = [
      tx(1, DateTime(2026, 11, 1)),
      for (var i = 1; i < TxDisposition.values.length; i++)
        tx(i + 1, DateTime(2026, 11, i + 1),
            state: TxDisposition.values[i], amount: 500),
    ];
    final workbook = Excel.decodeBytes(buildReportXlsx(rows, [])!);
    expect(workbook['المعاملات'].maxRows, 2);
    expect(workbook['ملخص يومي'].maxRows, 2);
    expect(workbook['ملخص الأرقام'].maxRows, 2);
    expect(num.parse(workbook['ملخص يومي'].rows[1][1]!.value.toString()), 100);
  });
}
