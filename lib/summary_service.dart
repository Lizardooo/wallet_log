/// Numbers for the dashboard, wallet screen and reports. Everything is derived
/// from the same exact rules as [ConfirmedTotals]; pending money never enters
/// a confirmed figure, and moves between the owner's own wallets are kept per
/// wallet but left out of consolidated income and spending.
library;

import 'package:sqflite/sqflite.dart';

import 'evidence_service.dart';
import 'match_service.dart';
import 'money_engine.dart';

class WalletSummary {
  final int walletId;
  final String provider, phone, nickname;
  final WalletTotals totals;

  /// Balance the owner last confirmed by hand, and its difference from the
  /// computed confirmed balance (null when either is unknown).
  final int? lastConfirmedMinor;
  final int? discrepancyMinor;
  const WalletSummary(this.walletId, this.provider, this.phone, this.nickname,
      this.totals, this.lastConfirmedMinor, this.discrepancyMinor);
}

class DashboardData {
  final List<WalletSummary> wallets;

  /// Consolidated confirmed figures (internal transfers excluded).
  final int incomeMinor, spendMinor, feesMinor;
  final int pendingInMinor, pendingOutMinor, pendingCount;
  final int mismatchedCount, gapCount, uncertainFeeMinor;
  final Map<String, int> spendByType;
  const DashboardData(
      this.wallets,
      this.incomeMinor,
      this.spendMinor,
      this.feesMinor,
      this.pendingInMinor,
      this.pendingOutMinor,
      this.pendingCount,
      this.mismatchedCount,
      this.gapCount,
      this.uncertainFeeMinor,
      this.spendByType);

  int get netMinor => incomeMinor - spendMinor - feesMinor;
}

class SummaryService {
  final Database db;
  const SummaryService(this.db);

  Future<DashboardData> dashboard({DateTime? from, DateTime? to}) async {
    final wallets = await db.rawQuery(
        'SELECT w.*, p.name AS pname FROM wallet_accounts w '
        'JOIN wallet_providers p ON p.id = w.provider_id WHERE w.archived = 0 ORDER BY w.id');
    final totals = ConfirmedTotals(db);
    final list = <WalletSummary>[];
    var pIn = 0, pOut = 0, pCount = 0, unc = 0;
    for (final w in wallets) {
      final t = await totals.forWallet(w['id']! as int);
      final lc = w['last_confirmed_minor'] as int?;
      list.add(WalletSummary(
          w['id']! as int,
          w['pname']! as String,
          (w['phone'] as String?) ?? '',
          (w['nickname'] as String?) ?? '',
          t,
          lc,
          (lc != null && t.confirmedBalanceMinor != null)
              ? lc - t.confirmedBalanceMinor!
              : null));
      pIn += t.pendingInMinor;
      pOut += t.pendingOutMinor;
      pCount += t.pendingCount;
      unc += t.uncertainFeeMinor;
    }
    // Consolidated, period-limited figures straight from the rows.
    final reversed = {
      for (final r in await db.query('tx',
          columns: ['reverses_tx_id'], where: 'reverses_tx_id IS NOT NULL'))
        r['reverses_tx_id'] as int
    };
    final rows = await db.query('tx',
        where:
            "disposition = 'active' AND review = 0 AND amount_minor IS NOT NULL "
            "AND dir IN ('in','out') AND confirmation IN ('provider_confirmed','balance_confirmed')");
    var income = 0, spend = 0, fees = 0;
    final byType = <String, int>{};
    for (final r in rows) {
      final ts = r['ts'] as int;
      if (from != null && ts < from.millisecondsSinceEpoch) continue;
      if (to != null && ts >= to.millisecondsSinceEpoch) continue;
      if (reversed.contains(r['id']) || r['reverses_tx_id'] != null) continue;
      final amount = r['amount_minor']! as int;
      final fee = (r['fee_owner'] ?? FeeOwner.owner) == FeeOwner.owner
          ? (r['fee_minor'] as int? ?? 0)
          : 0;
      final internal = r['transfer_peer_id'] != null;
      if (!internal) {
        if (r['dir'] == 'in') {
          income += amount;
        } else {
          spend += amount;
          final type = (r['type'] as String?) ?? 'other';
          byType[type] = (byType[type] ?? 0) + amount;
        }
      }
      fees += fee; // a fee is a real cost even on an internal move
    }
    final mismatched = Sqflite.firstIntValue(await db.rawQuery(
            "SELECT COUNT(*) FROM tx WHERE confirmation = 'mismatched' AND disposition = 'active'")) ??
        0;
    final gaps = (await MatchService(db).balanceGaps()).length;
    return DashboardData(
        list,
        income,
        spend,
        fees,
        pIn,
        pOut,
        pCount,
        mismatched,
        gaps,
        unc,
        Map.fromEntries(byType.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value))));
  }

  /// Transactions waiting for confirmation, newest first.
  Future<List<Map<String, Object?>>> awaiting({int limit = 20}) => db.query(
      'tx',
      where:
          "confirmation = 'awaiting' AND disposition = 'active' AND reverses_tx_id IS NULL",
      orderBy: 'ts DESC',
      limit: limit);

  Future<List<Map<String, Object?>>> latest(
          {int? walletId, int limit = 30, int offset = 0}) =>
      db.query('tx',
          where: walletId == null ? null : 'wallet_account_id = ?',
          whereArgs: walletId == null ? null : [walletId],
          orderBy: 'ts DESC, id DESC',
          limit: limit,
          offset: offset);
}
