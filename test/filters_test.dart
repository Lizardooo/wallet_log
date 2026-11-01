import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/logic.dart';
import 'package:wallet_log/parser.dart';

const accounts = [
  Account(
    id: 1,
    name: 'VF 1',
    wallet: 'Vodafone Cash',
    number: '01011111111',
    subId: 11,
  ),
  Account(
    id: 2,
    name: 'VF 2',
    wallet: 'Vodafone Cash',
    number: '01022222222',
    subId: 22,
  ),
  Account(id: 3, name: 'Orange', wallet: 'Orange Cash', number: '01211111111'),
];

Tx transaction(
  int id,
  DateTime date, {
  String wallet = 'Vodafone Cash',
  int? subId = 11,
  TxType type = TxType.transfer,
  Dir dir = Dir.inFlow,
  bool review = false,
  double amount = 100,
}) =>
    Tx(
      id: id,
      ts: date.millisecondsSinceEpoch,
      wallet: wallet,
      subId: subId,
      type: type,
      dir: dir,
      review: review,
      amount: amount,
    );

void main() {
  group('DateFilter calendar bounds', () {
    final now = DateTime(2026, 11, 1, 13, 4);
    final cases = <DatePeriod, (DateTime?, DateTime?)>{
      DatePeriod.all: (null, null),
      DatePeriod.today: (DateTime(2026, 11, 1), DateTime(2026, 11, 2)),
      DatePeriod.yesterday: (DateTime(2026, 10, 31), DateTime(2026, 11, 1)),
      DatePeriod.last7Days: (DateTime(2026, 10, 26), DateTime(2026, 11, 2)),
      DatePeriod.last30Days: (DateTime(2026, 10, 3), DateTime(2026, 11, 2)),
      DatePeriod.thisMonth: (DateTime(2026, 11, 1), DateTime(2026, 11, 2)),
    };
    for (final entry in cases.entries) {
      test('${entry.key} uses inclusive start and exclusive end', () {
        final f = DateFilter(period: entry.key);
        final range = f.bounds(now: now);
        expect(range.start, entry.value.$1);
        expect(range.end, entry.value.$2);
        final start = range.start;
        final end = range.end;
        if (start != null && end != null) {
          final a = start.millisecondsSinceEpoch;
          final b = end.millisecondsSinceEpoch;
          expect(f.matches(a, now: now), isTrue);
          expect(f.matches(a - 1, now: now), isFalse);
          expect(f.matches(b - 1, now: now), isTrue);
          expect(f.matches(b, now: now), isFalse);
        } else {
          expect(
            f.matches(DateTime(2019).millisecondsSinceEpoch, now: now),
            isTrue,
          );
          expect(
            f.matches(DateTime(2030).millisecondsSinceEpoch, now: now),
            isTrue,
          );
        }
      });
    }

    test(
      'first-of-month selection has one identity even with equal bounds',
      () {
        final f = DateFilter(period: DatePeriod.thisMonth);
        final month = f.bounds(now: now);
        expect(f.period, DatePeriod.thisMonth);
        f.select(DatePeriod.today);
        expect(f.bounds(now: now), month);
        expect(f.period, DatePeriod.today);
        f.select(DatePeriod.thisMonth);
        expect(f.period, DatePeriod.thisMonth);
      },
    );

    test(
      'calendar shortcuts recompute after midnight without reopening filters',
      () {
        final f = DateFilter(period: DatePeriod.today);
        final ts = DateTime(2026, 11, 1, 23, 59).millisecondsSinceEpoch;
        expect(f.matches(ts, now: now), isTrue);
        expect(f.matches(ts, now: DateTime(2026, 11, 2)), isFalse);
      },
    );

    test(
      'month-to-date includes prior days, excludes last month and tomorrow',
      () {
        final f = DateFilter(period: DatePeriod.thisMonth);
        final middle = DateTime(2026, 11, 15, 12);
        expect(
          f.matches(DateTime(2026, 11, 1).millisecondsSinceEpoch, now: middle),
          isTrue,
        );
        expect(
          f.matches(
            DateTime(2026, 11, 15, 23, 59, 59, 999).millisecondsSinceEpoch,
            now: middle,
          ),
          isTrue,
        );
        expect(
          f.matches(
            DateTime(2026, 10, 31, 23, 59).millisecondsSinceEpoch,
            now: middle,
          ),
          isFalse,
        );
        expect(
          f.matches(DateTime(2026, 11, 16).millisecondsSinceEpoch, now: middle),
          isFalse,
        );
      },
    );

    test('week and month shortcuts cross New Year correctly', () {
      final f = DateFilter(period: DatePeriod.last7Days);
      expect(f.bounds(now: DateTime(2027, 1, 1)).start, DateTime(2026, 12, 26));
      f.select(DatePeriod.last30Days);
      expect(f.bounds(now: DateTime(2027, 1, 1)).start, DateTime(2026, 12, 3));
      f.select(DatePeriod.yesterday);
      expect(f.bounds(now: DateTime(2027, 1, 1)).start, DateTime(2026, 12, 31));
    });

    test('seven calendar days include leap day', () {
      final f = DateFilter(period: DatePeriod.last7Days);
      expect(f.bounds(now: DateTime(2028, 3, 1)).start, DateTime(2028, 2, 24));
      expect(
        f.matches(
          DateTime(2028, 2, 29, 23, 59).millisecondsSinceEpoch,
          now: DateTime(2028, 3, 1),
        ),
        isTrue,
      );
    });

    test('custom range normalizes time, reversals and inclusive last day', () {
      final f = DateFilter();
      f.setCustom(DateTime(2026, 11, 4, 8), DateTime(2026, 11, 2, 22));
      expect(f.period, DatePeriod.custom);
      expect(f.from, DateTime(2026, 11, 2));
      expect(f.to, DateTime(2026, 11, 4));
      expect(
        f.matches(
          DateTime(2026, 11, 4, 23, 59, 59, 999).millisecondsSinceEpoch,
        ),
        isTrue,
      );
      expect(f.matches(DateTime(2026, 11, 5).millisecondsSinceEpoch), isFalse);
      f.clear();
      expect(f.period, DatePeriod.all);
      expect(f.from, isNull);
      expect(f.to, isNull);
    });

    test('a one-day custom range remains custom, not today or this month', () {
      final f = DateFilter()..setCustom(now, now);
      expect(f.period, DatePeriod.custom);
      expect(f.bounds(now: now).start, DateTime(2026, 11, 1));
      expect(f.bounds(now: now).end, DateTime(2026, 11, 2));
    });
  });

  group('Combined transaction filters', () {
    final now = DateTime(2026, 11, 15, 13);
    late List<Tx> rows;
    late TxFilter f;
    List<int> ids() => rows
        .where((t) => f.matches(t, accounts, now: now))
        .map((t) => t.id)
        .toList();
    setUp(() {
      f = TxFilter();
      rows = [
        transaction(1, DateTime(2026, 11, 15, 8)),
        transaction(
          2,
          DateTime(2026, 11, 15, 9),
          dir: Dir.outFlow,
          type: TxType.bill,
        ),
        transaction(3, DateTime(2026, 11, 14, 12), subId: 22),
        transaction(4, DateTime(2026, 10, 31, 12)),
        transaction(
          5,
          DateTime(2026, 11, 15, 10),
          review: true,
          type: TxType.topup,
        ),
        transaction(6, DateTime(2026, 11, 15, 11), dir: Dir.unknown),
        transaction(
          7,
          DateTime(2026, 11, 15, 12),
          wallet: 'Orange Cash',
          subId: null,
        ),
        transaction(
          8,
          DateTime(2026, 11, 15, 13),
          wallet: '01011111111',
          subId: null,
        ),
        transaction(9, DateTime(2026, 11, 15, 14), subId: null),
      ];
    });

    test('all shows confirmed rows; pending and unknown live in review', () {
      expect(ids(), [1, 2, 3, 4, 7, 8, 9]);
      f.reviewOnly = true;
      expect(ids(), [5, 6]);
    });
    test(
        'same-provider accounts use SIM and Excel number; ambiguous is unassigned',
        () {
      f.accountId = 1;
      expect(ids(), [1, 2, 4, 8]);
      f.accountId = 2;
      expect(ids(), [3]);
      f.accountId = 3;
      expect(ids(), [7]);
      f.accountId = 999;
      expect(ids(), isEmpty);
    });
    test(
      'types are OR within selection and AND with account/date/direction',
      () {
        f.accountId = 1;
        f.date.select(DatePeriod.today);
        f.types = {TxType.transfer, TxType.bill};
        expect(ids(), [1, 2, 8]);
        f.dir = Dir.outFlow;
        expect(ids(), [2]);
        f.types = {TxType.transfer};
        expect(ids(), isEmpty);
      },
    );
    test('every operation type can be selected and deselected independently',
        () {
      rows = [
        for (var i = 0; i < TxType.values.length; i++)
          transaction(i, now, type: TxType.values[i])
      ];
      for (var i = 0; i < TxType.values.length; i++) {
        f.types = {TxType.values[i]};
        expect(ids(), [i], reason: TxType.values[i].name);
      }
      f.types.clear();
      expect(ids(), List.generate(TxType.values.length, (i) => i));
    });

    test('in/out filters switch without changing the date or account', () {
      f.accountId = 1;
      f.date.select(DatePeriod.today);
      f.dir = Dir.inFlow;
      expect(ids(), [1, 8]);
      f.dir = Dir.outFlow;
      expect(ids(), [2]);
      f.dir = null;
      expect(ids(), [1, 2, 8]);
      expect(f.date.period, DatePeriod.today);
      expect(f.accountId, 1);
    });
    test('review ignores in/out but respects date, account and type', () {
      f.accountId = 1;
      f.date.select(DatePeriod.today);
      f.dir = Dir.outFlow;
      f.reviewOnly = true;
      expect(ids(), [5, 6]);
      f.types = {TxType.topup};
      expect(ids(), [5]);
    });
    test(
        'reports retain pending rows for review counts but never add their amounts',
        () {
      f.date.select(DatePeriod.today);
      final selected =
          rows.where((t) => f.matchesBase(t, accounts, now: now)).toList();
      expect(selected.map((t) => t.id), [1, 2, 5, 6, 7, 8, 9]);
      final total = totalsOf(selected);
      expect(total.inSum, 400);
      expect(total.outSum, 100);
      expect(total.pending, 1);
      expect(total.unknown, 1);
    });
    test('clear removes ALL constraints including direction and review', () {
      f.accountId = 1;
      f.types = {TxType.bill};
      f.dir = Dir.outFlow;
      f.reviewOnly = true;
      f.date.setCustom(now, now);
      expect(f.isActive, isTrue);
      f.clear();
      expect(f.isActive, isFalse);
      expect(ids(), [1, 2, 3, 4, 7, 8, 9]);
    });
    test('this month on day one returns today rows, not previous month', () {
      final first = DateTime(2026, 11, 1, 13);
      final sample = [
        transaction(1, DateTime(2026, 10, 31, 23, 59)),
        transaction(2, DateTime(2026, 11, 1)),
        transaction(3, DateTime(2026, 11, 1, 23, 59)),
        transaction(4, DateTime(2026, 11, 2)),
      ];
      f.date.select(DatePeriod.thisMonth);
      expect(
        sample
            .where((t) => f.matches(t, accounts, now: first))
            .map((t) => t.id),
        [2, 3],
      );
    });
  });
}
