import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/money_engine.dart';

final _d = DateTime(2026, 1, 1);

FeeRule atm({int id = 1, int version = 1, DateTime? from, DateTime? to}) =>
    FeeRule(
      id: id,
      version: version,
      provider: 'p1',
      kind: 'cash_out',
      channel: 'atm',
      percentBp: 100, // 10 per 1,000
      effectiveFrom: from ?? _d,
      effectiveTo: to,
    );

void main() {
  test('minor units avoid float drift', () {
    expect(toMinor(0.1 + 0.2), 30);
    expect(toMinor(1250.5), 125050);
    expect(formatMinor(123456789), '1,234,567.89');
    expect(formatMinor(-5), '-0.05');
  });

  test('ATM example: 2,000 received, 2,020 debited, rule explains 20', () {
    final rule = atm();
    final ex = explainDebit(
        walletDebitMinor: toMinor(2020),
        receivedMinor: toMinor(2000),
        rule: rule);
    expect(ex.source, FeeSource.rule);
    expect(ex.feeMinor, toMinor(20));
    expect(ex.needsReview, isFalse);
  });

  test('a difference the rule does not explain is flagged, not a fee', () {
    final ex = explainDebit(
        walletDebitMinor: toMinor(2035),
        receivedMinor: toMinor(2000),
        rule: atm());
    expect(ex.unexplainedMinor, toMinor(15));
    expect(ex.needsReview, isTrue);
    final none = explainDebit(
        walletDebitMinor: toMinor(2020), receivedMinor: toMinor(2000));
    expect(none.source, FeeSource.unexplained);
    expect(none.unexplainedMinor, toMinor(20));
  });

  test('stated SMS fee takes precedence', () {
    final ex = explainDebit(
        walletDebitMinor: 10200,
        receivedMinor: 10000,
        statedFeeMinor: 200,
        rule: atm());
    expect(ex.source, FeeSource.explicitSms);
    expect(ex.needsReview, isFalse);
  });

  test('recharge 100 + fee 2 debits 102 and leaves 898', () {
    expect(expectedAfter(toMinor(1000), debitMinor: toMinor(100) + toMinor(2)),
        toMinor(898));
  });

  test('fixed, min, max and rounding', () {
    FeeRule r(
            {int fixed = 0,
            int bp = 0,
            int? min,
            int? max,
            Rounding ro = Rounding.nearest}) =>
        FeeRule(
            id: 1,
            provider: 'p',
            kind: 'k',
            fixedMinor: fixed,
            percentBp: bp,
            minMinor: min,
            maxMinor: max,
            rounding: ro,
            effectiveFrom: _d);
    expect(computeFee(r(fixed: 500), 99999)!.feeMinor, 500);
    expect(computeFee(r(bp: 50, min: 100), 1000)!.feeMinor, 100); // min
    expect(computeFee(r(bp: 50, max: 1500), 10000000)!.feeMinor, 1500); // max
    expect(computeFee(r(bp: 50, ro: Rounding.up), 101)!.feeMinor, 1);
    expect(computeFee(r(bp: 50, ro: Rounding.down), 399)!.feeMinor, 1);
    expect(computeFee(r(bp: 50), 100)!.feeMinor, 1); // 0.5 rounds up
  });

  test('tiered fees; an uncovered amount is unknown, not zero', () {
    final rule = FeeRule(
      id: 2,
      provider: 'p',
      kind: 'send',
      effectiveFrom: _d,
      tiers: const [
        FeeTier(fromMinor: 0, toMinor: 100000, fixedMinor: 100),
        FeeTier(fromMinor: 100000, toMinor: 500000, fixedMinor: 300),
      ],
    );
    expect(computeFee(rule, 50000)!.feeMinor, 100);
    expect(computeFee(rule, 100000)!.feeMinor, 300);
    expect(computeFee(rule, 500000), isNull);
  });

  test('rule changes do not rewrite history: snapshot keeps rule version', () {
    final old = atm(
        id: 1,
        version: 1,
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 6, 1));
    final newer = FeeRule(
        id: 1,
        version: 2,
        provider: 'p1',
        kind: 'cash_out',
        channel: 'atm',
        percentBp: 150,
        effectiveFrom: DateTime(2026, 6, 1));
    final rules = [old, newer];
    final before =
        selectRule(rules, 'p1', 'cash_out', 'atm', DateTime(2026, 3, 1))!;
    final after =
        selectRule(rules, 'p1', 'cash_out', 'atm', DateTime(2026, 7, 1))!;
    expect(computeFee(before, 100000)!.feeMinor, 1000);
    expect(computeFee(before, 100000)!.ruleVersion, 1);
    expect(computeFee(after, 100000)!.feeMinor, 1500);
    expect(computeFee(after, 100000)!.ruleVersion, 2);
  });

  test('rule selection: channel match wins, other provider/inactive ignored',
      () {
    final any = FeeRule(
        id: 1,
        provider: 'p1',
        kind: 'cash_out',
        fixedMinor: 999,
        effectiveFrom: _d);
    final atmRule = atm(id: 2);
    final off = FeeRule(
        id: 3,
        provider: 'p1',
        kind: 'cash_out',
        channel: 'atm',
        fixedMinor: 1,
        effectiveFrom: _d,
        active: false);
    final other = FeeRule(
        id: 4,
        provider: 'p2',
        kind: 'cash_out',
        channel: 'atm',
        fixedMinor: 1,
        effectiveFrom: _d);
    final rules = [any, atmRule, off, other];
    expect(selectRule(rules, 'p1', 'cash_out', 'atm', _d)!.id, 2);
    expect(selectRule(rules, 'p1', 'cash_out', 'agent', _d)!.id, 1);
    expect(selectRule(rules, 'p3', 'cash_out', 'atm', _d), isNull);
  });

  test('reconciliation: matched, earliest divergence, no opening, no evidence',
      () {
    final ok = [
      LedgerEntry(creditMinor: 5000, statedBalanceMinor: 105000),
      LedgerEntry(debitMinor: 10200),
      LedgerEntry(debitMinor: 100, statedBalanceMinor: 94700),
    ];
    expect(reconcile(100000, ok).status, ReconStatus.matched);

    final bad = [
      LedgerEntry(creditMinor: 5000, statedBalanceMinor: 105000),
      LedgerEntry(debitMinor: 10000, statedBalanceMinor: 94000), // 20 missing
      LedgerEntry(debitMinor: 100, statedBalanceMinor: 93900),
    ];
    final r = reconcile(100000, bad);
    expect(r.status, ReconStatus.mismatched);
    expect(r.firstDivergence, 1);
    expect(r.expectedMinor, 95000);
    expect(r.observedMinor, 94000);

    expect(reconcile(null, ok).status, ReconStatus.missingOpening);
    expect(reconcile(0, [LedgerEntry(creditMinor: 1)]).status,
        ReconStatus.insufficientEvidence);
  });

  test('internal transfer nets to zero across owned wallets', () {
    final a = expectedAfter(100000, debitMinor: 50000);
    final b = expectedAfter(20000, creditMinor: 50000);
    expect(a + b, 100000 + 20000);
  });

  test('parseMinor is exact and refuses sub-piaster or junk input', () {
    expect(parseMinor('1,250.5'), 125050);
    expect(parseMinor('١٢٫٥٠'), 1250);
    expect(parseMinor('0.07'), 7);
    expect(parseMinor('19.99'), 1999); // a double would give 1998.999...
    expect(parseMinor('1.234'), isNull);
    expect(parseMinor('-5'), isNull);
    expect(parseMinor(''), isNull);
    expect(parseMinor('abc'), isNull);
  });
}
