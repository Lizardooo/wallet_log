import 'db.dart';
import 'parser.dart';

String two(int n) => n.toString().padLeft(2, '0');
String dayKey(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
String dayKeyTs(int ts) => dayKey(DateTime.fromMillisecondsSinceEpoch(ts));
String fmt(double v) => v.toStringAsFixed(2);

int dayStartMs(String key) {
  final p = key.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]))
      .millisecondsSinceEpoch;
}

/// Finds which of the trader's wallet numbers a transaction belongs to.
/// Matches by wallet type, then by SIM (subscription id) when several numbers
/// share a wallet type. Returns null when it cannot tell.
Account? accountFor(Tx t, List<Account> accounts) {
  final cands = accounts
      .where((a) =>
          a.wallet == t.wallet &&
          (a.subId == null || t.subId == null || a.subId == t.subId))
      .toList();
  for (final a in cands) {
    if (a.subId != null && a.subId == t.subId) return a;
  }
  if (cands.length == 1) return cands.first;
  final open = cands.where((a) => a.subId == null).toList();
  return open.length == 1 ? open.first : null;
}

String accountLabel(Account a) =>
    a.number.isEmpty ? a.name : '${a.name} · ${a.number}';

/// In / out / fee totals. Transactions whose direction is unknown are counted
/// separately and never added to in or out.
class Totals {
  double inSum = 0;
  double outSum = 0;
  double fee = 0;
  int count = 0;
  int unknown = 0;

  double get net => inSum - outSum - fee;

  void add(Tx t) {
    count++;
    if (t.isIn) {
      inSum += t.amount;
    } else if (t.isOut) {
      outSum += t.amount;
    } else {
      unknown++;
    }
    fee += t.fee;
  }
}

Totals totalsOf(Iterable<Tx> txs) {
  final t = Totals();
  for (final x in txs) {
    t.add(x);
  }
  return t;
}

/// Filter shared by the transactions list. [from] and [to] are whole days,
/// both inclusive.
class TxFilter {
  int? accountId;
  Set<TxType> types = {};
  DateTime? from;
  DateTime? to;

  bool get isActive =>
      accountId != null || types.isNotEmpty || from != null || to != null;

  bool matches(Tx t, List<Account> accounts) {
    if (accountId != null && accountFor(t, accounts)?.id != accountId) {
      return false;
    }
    if (types.isNotEmpty && !types.contains(t.type)) return false;
    final f = from;
    if (f != null &&
        t.ts < DateTime(f.year, f.month, f.day).millisecondsSinceEpoch) {
      return false;
    }
    final e = to;
    if (e != null &&
        t.ts >= DateTime(e.year, e.month, e.day + 1).millisecondsSinceEpoch) {
      return false;
    }
    return true;
  }
}

/// Finds transactions whose SMS balance does not follow from the previous
/// message's balance (same wallet number). A gap usually means a message was
/// deleted, or a fee/transaction was parsed wrongly. Returns id -> difference.
Map<int, double> balanceMismatches(List<Tx> all, List<Account> accounts) {
  final groups = <String, List<Tx>>{};
  for (final t in all) {
    final a = accountFor(t, accounts);
    final k = a != null ? 'a${a.id}' : 'w${t.wallet}|${t.subId}';
    groups.putIfAbsent(k, () => []).add(t);
  }
  final out = <int, double>{};
  for (final list in groups.values) {
    list.sort((a, b) {
      final c = a.ts.compareTo(b.ts);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    Tx? prev;
    for (final t in list) {
      final p = prev;
      final pb = p?.balance;
      final tb = t.balance;
      if (pb != null && tb != null && !t.isUnknown) {
        final delta = t.isIn ? t.amount : -t.amount;
        final d = tb - (pb + delta - t.fee);
        if (d.abs() > 0.01) out[t.id] = d;
      }
      prev = t;
    }
  }
  return out;
}

/// One wallet number's figures for one day.
class DayRow {
  final Account? account; // null = transactions not linked to any number
  final String label;
  final double? opening;
  final bool suggested; // opening taken from the last SMS balance
  final double inSum;
  final double outSum;
  final double feeSum;
  final int count;
  final int unknown;
  final double? reported; // last balance printed in that day's SMS

  const DayRow({
    required this.account,
    required this.label,
    required this.opening,
    required this.suggested,
    required this.inSum,
    required this.outSum,
    required this.feeSum,
    required this.count,
    required this.unknown,
    required this.reported,
  });

  double? get expected =>
      opening == null ? null : opening! + inSum - outSum - feeSum;

  double? get diff {
    final e = expected;
    final r = reported;
    return (e == null || r == null) ? null : r - e;
  }
}

/// [all] must be sorted newest first (as TxDb.allTx returns it).
List<DayRow> dailyRows(String day, List<Tx> all, List<Account> accounts,
    Map<String, double> openings) {
  final start = dayStartMs(day);
  final assigned = <int, int?>{
    for (final t in all) t.id: accountFor(t, accounts)?.id,
  };

  DayRow build(Account? acc, String label) {
    final accId = acc?.id;
    final dayTx = all
        .where((t) => assigned[t.id] == accId && dayKeyTs(t.ts) == day)
        .toList()
      ..sort((a, b) {
        final c = a.ts.compareTo(b.ts);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final totals = totalsOf(dayTx);
    double? reported;
    for (final t in dayTx) {
      if (t.balance != null) reported = t.balance;
    }
    double? opening;
    var suggested = false;
    if (acc != null) {
      opening = openings['${acc.id}|$day'];
      if (opening == null) {
        for (final t in all) {
          if (assigned[t.id] == accId && t.ts < start && t.balance != null) {
            opening = t.balance;
            suggested = true;
            break;
          }
        }
      }
    }
    return DayRow(
      account: acc,
      label: label,
      opening: opening,
      suggested: suggested,
      inSum: totals.inSum,
      outSum: totals.outSum,
      feeSum: totals.fee,
      count: totals.count,
      unknown: totals.unknown,
      reported: reported,
    );
  }

  final rows = <DayRow>[
    for (final a in accounts) build(a, accountLabel(a)),
  ];
  final hasUnassigned =
      all.any((t) => assigned[t.id] == null && dayKeyTs(t.ts) == day);
  if (hasUnassigned) rows.add(build(null, 'غير مربوط بحساب'));
  return rows;
}

class AccStat {
  final String label;
  final Totals totals = Totals();

  AccStat(this.label);
}

List<AccStat> accountStats(List<Tx> txs, List<Account> accounts) {
  final m = <String, AccStat>{};
  for (final a in accounts) {
    m['a${a.id}'] = AccStat(accountLabel(a));
  }
  for (final t in txs) {
    final a = accountFor(t, accounts);
    final key = a != null ? 'a${a.id}' : 'w${t.wallet}';
    m.putIfAbsent(key, () => AccStat('${t.wallet} (غير مربوط)')).totals.add(t);
  }
  return m.values.toList();
}

/// Totals per transaction type, biggest first.
List<MapEntry<TxType, Totals>> typeStats(List<Tx> txs) {
  final m = <TxType, Totals>{};
  for (final t in txs) {
    m.putIfAbsent(t.type, () => Totals()).add(t);
  }
  final list = m.entries.toList();
  list.sort((a, b) => b.value.count.compareTo(a.value.count));
  return list;
}

class PartyStat {
  final String party;
  double inSum = 0;
  double outSum = 0;
  int count = 0;

  PartyStat(this.party);

  double get total => inSum + outSum;
}

/// Counterparty phone numbers ranked by total volume.
List<PartyStat> partyStats(List<Tx> txs) {
  final m = <String, PartyStat>{};
  for (final t in txs) {
    final p = t.party;
    if (p == null || t.isUnknown) continue;
    final s = m.putIfAbsent(p, () => PartyStat(p));
    if (t.isIn) {
      s.inSum += t.amount;
    } else {
      s.outSum += t.amount;
    }
    s.count++;
  }
  final list = m.values.toList();
  list.sort((a, b) => b.total.compareTo(a.total));
  return list;
}
