import 'db.dart';

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

/// One wallet number's figures for one day.
class DayRow {
  final Account? account; // null = transactions not linked to any number
  final String label;
  final double? opening;
  final bool suggested; // opening taken from the last SMS balance
  final double inSum;
  final double outSum;
  final int count;
  final double? reported; // last balance printed in that day's SMS

  const DayRow({
    required this.account,
    required this.label,
    required this.opening,
    required this.suggested,
    required this.inSum,
    required this.outSum,
    required this.count,
    required this.reported,
  });

  double? get expected => opening == null ? null : opening! + inSum - outSum;

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
      ..sort((a, b) => a.ts.compareTo(b.ts));
    double inSum = 0;
    double outSum = 0;
    double? reported;
    for (final t in dayTx) {
      if (t.isIn) {
        inSum += t.amount;
      } else {
        outSum += t.amount;
      }
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
      inSum: inSum,
      outSum: outSum,
      count: dayTx.length,
      reported: reported,
    );
  }

  final rows = <DayRow>[
    for (final a in accounts) build(a, accountLabel(a)),
  ];
  final hasUnassigned = all.any((t) => assigned[t.id] == null && dayKeyTs(t.ts) == day);
  if (hasUnassigned) rows.add(build(null, 'غير مربوط بحساب'));
  return rows;
}

class AccStat {
  final String label;
  double inSum = 0;
  double outSum = 0;
  int count = 0;

  AccStat(this.label);

  double get net => inSum - outSum;
}

List<AccStat> accountStats(List<Tx> txs, List<Account> accounts) {
  final m = <String, AccStat>{};
  for (final a in accounts) {
    m['a${a.id}'] = AccStat(accountLabel(a));
  }
  for (final t in txs) {
    final a = accountFor(t, accounts);
    final key = a != null ? 'a${a.id}' : 'w${t.wallet}';
    final s = m.putIfAbsent(key, () => AccStat('${t.wallet} (غير مربوط)'));
    if (t.isIn) {
      s.inSum += t.amount;
    } else {
      s.outSum += t.amount;
    }
    s.count++;
  }
  return m.values.toList();
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
    if (p == null) continue;
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
