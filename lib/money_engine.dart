/// Exact money arithmetic, configurable fee rules and balance reconciliation.
///
/// All amounts are integer minor units (piasters for EGP); no doubles are used
/// in any calculation. Nothing here knows about a specific provider: tariffs
/// are data ([FeeRule]), so a rule change never alters stored history because
/// each result carries a [FeeCalc] snapshot of what was applied.
library;

/// Converts a pounds amount read from a message or sheet to piasters.
int toMinor(num pounds) => (pounds * 100).round();

/// Parses what a person typed ("1,250.5", "١٢٫٥٠") into piasters without any
/// floating-point step. Null for empty, negative, non-numeric or sub-piaster
/// input (more than two decimals) so nothing is silently rounded.
int? parseMinor(String input) {
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  final t = input
      .split('')
      .map((c) => arabic.contains(c) ? arabic.indexOf(c).toString() : c)
      .join()
      .replaceAll('٫', '.')
      .replaceAll(RegExp(r'[,\s٬]'), '');
  final m = RegExp(r'^(\d{1,12})(?:\.(\d{1,2}))?$').firstMatch(t);
  if (m == null) return null;
  return int.parse(m.group(1)!) * 100 +
      int.parse((m.group(2) ?? '').padRight(2, '0'));
}

/// Formats piasters as "1,234.50" without floating-point arithmetic.
String formatMinor(int minor) {
  final neg = minor < 0;
  final abs = minor.abs();
  final whole = (abs ~/ 100)
      .toString()
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  final frac = (abs % 100).toString().padLeft(2, '0');
  return '${neg ? '-' : ''}$whole.$frac';
}

enum Rounding { nearest, up, down }

/// One band of a tiered tariff: amounts in [fromMinor, toMinor) (open-ended
/// when [toMinor] is null).
class FeeTier {
  final int fromMinor;
  final int? toMinor;
  final int fixedMinor;
  final int percentBp; // basis points: 100 bp = 1 %

  const FeeTier({
    required this.fromMinor,
    this.toMinor,
    this.fixedMinor = 0,
    this.percentBp = 0,
  });

  bool covers(int amount) =>
      amount >= fromMinor && (toMinor == null || amount < toMinor!);
}

class FeeRule {
  final int id;
  final int version;
  final String provider; // provider code, e.g. 'vodafone_cash'
  final String kind; // transaction type, e.g. 'cash_out'
  final String? channel; // 'atm', 'agent', 'ussd', ... null = any channel
  final int fixedMinor;
  final int percentBp;
  final int? minMinor;
  final int? maxMinor;
  final List<FeeTier> tiers;
  final Rounding rounding;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final bool active;

  const FeeRule({
    required this.id,
    this.version = 1,
    required this.provider,
    required this.kind,
    this.channel,
    this.fixedMinor = 0,
    this.percentBp = 0,
    this.minMinor,
    this.maxMinor,
    this.tiers = const [],
    this.rounding = Rounding.nearest,
    required this.effectiveFrom,
    this.effectiveTo,
    this.active = true,
  });

  bool appliesTo(String provider, String kind, String? channel, DateTime at) =>
      active &&
      this.provider == provider &&
      this.kind == kind &&
      (this.channel == null || this.channel == channel) &&
      !at.isBefore(effectiveFrom) &&
      (effectiveTo == null || at.isBefore(effectiveTo!));
}

/// What was applied, kept with the transaction so later tariff edits do not
/// change history.
class FeeCalc {
  final int feeMinor;
  final int ruleId;
  final int ruleVersion;
  final String detail;

  const FeeCalc(this.feeMinor, this.ruleId, this.ruleVersion, this.detail);
}

int _divide(int num, int den, Rounding r) {
  final q = num ~/ den;
  final rem = num % den;
  if (rem == 0) return q;
  return switch (r) {
    Rounding.down => q,
    Rounding.up => q + 1,
    Rounding.nearest => rem * 2 >= den ? q + 1 : q,
  };
}

/// Fee for [amountMinor] under [rule], or null when a tiered rule has no tier
/// for the amount (the fee is then unknown, not zero).
FeeCalc? computeFee(FeeRule rule, int amountMinor) {
  var fixed = rule.fixedMinor;
  var bp = rule.percentBp;
  if (rule.tiers.isNotEmpty) {
    final tier = rule.tiers.where((t) => t.covers(amountMinor)).firstOrNull;
    if (tier == null) return null;
    fixed = tier.fixedMinor;
    bp = tier.percentBp;
  }
  var fee = fixed + _divide(amountMinor * bp, 10000, rule.rounding);
  if (rule.minMinor != null && fee < rule.minMinor!) fee = rule.minMinor!;
  if (rule.maxMinor != null && fee > rule.maxMinor!) fee = rule.maxMinor!;
  return FeeCalc(fee, rule.id, rule.version,
      'fixed=$fixed bp=$bp amount=$amountMinor -> $fee');
}

/// Most specific active rule: an exact channel beats a channel-less rule, then
/// the latest effective date wins. Null when no rule is configured.
FeeRule? selectRule(List<FeeRule> rules, String provider, String kind,
    String? channel, DateTime at) {
  final hits = rules.where((r) => r.appliesTo(provider, kind, channel, at));
  if (hits.isEmpty) return null;
  return hits.reduce((a, b) {
    final sa = a.channel == null ? 0 : 1;
    final sb = b.channel == null ? 0 : 1;
    if (sa != sb) return sa > sb ? a : b;
    return a.effectiveFrom.isAfter(b.effectiveFrom) ? a : b;
  });
}

enum FeeSource { explicitSms, rule, inferred, manual, unexplained }

class DebitExplanation {
  final FeeSource source;
  final int feeMinor; // the part explained as a fee
  final int unexplainedMinor; // difference nothing accounts for
  final FeeCalc? calc;

  const DebitExplanation(this.source, this.feeMinor, this.unexplainedMinor,
      [this.calc]);

  bool get needsReview => unexplainedMinor != 0;
}

/// Compares the wallet debit with the amount received and says how much of the
/// difference a stated fee or the configured [rule] explains. A difference that
/// matches nothing is reported as unexplained, never silently called a fee.
DebitExplanation explainDebit({
  required int walletDebitMinor,
  required int receivedMinor,
  int? statedFeeMinor,
  FeeRule? rule,
}) {
  final diff = walletDebitMinor - receivedMinor;
  if (statedFeeMinor != null) {
    return DebitExplanation(
        FeeSource.explicitSms, statedFeeMinor, diff - statedFeeMinor);
  }
  if (rule != null) {
    final calc = computeFee(rule, receivedMinor);
    if (calc != null) {
      return DebitExplanation(
          FeeSource.rule, calc.feeMinor, diff - calc.feeMinor, calc);
    }
  }
  return DebitExplanation(
      diff == 0 ? FeeSource.rule : FeeSource.unexplained, 0, diff);
}

enum ReconStatus {
  matched,
  mismatched,
  missingOpening,
  insufficientEvidence,
}

/// Balance after a movement. [creditMinor] and [debitMinor] are the actual
/// wallet impact (debit includes any fee).
int expectedAfter(int beforeMinor, {int creditMinor = 0, int debitMinor = 0}) =>
    beforeMinor + creditMinor - debitMinor;

class LedgerEntry {
  final int creditMinor;
  final int debitMinor;
  final int? statedBalanceMinor; // balance printed in the SMS, if any

  const LedgerEntry({
    this.creditMinor = 0,
    this.debitMinor = 0,
    this.statedBalanceMinor,
  });
}

class ReconResult {
  final ReconStatus status;
  final int? firstDivergence; // index of the earliest mismatching entry
  final int? expectedMinor;
  final int? observedMinor;

  const ReconResult(this.status,
      [this.firstDivergence, this.expectedMinor, this.observedMinor]);
}

/// Walks entries (oldest first) from a known [openingMinor], comparing the
/// running balance with each stated balance. It never rewrites a balance to
/// force a match: after a mismatch the running value is kept, and only the
/// earliest divergence is reported.
ReconResult reconcile(int? openingMinor, List<LedgerEntry> entries) {
  if (openingMinor == null)
    return const ReconResult(ReconStatus.missingOpening);
  var running = openingMinor;
  var compared = false;
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    running = expectedAfter(running,
        creditMinor: e.creditMinor, debitMinor: e.debitMinor);
    final stated = e.statedBalanceMinor;
    if (stated == null) continue;
    compared = true;
    if (stated != running) {
      return ReconResult(ReconStatus.mismatched, i, running, stated);
    }
  }
  return ReconResult(
      compared ? ReconStatus.matched : ReconStatus.insufficientEvidence);
}

/// Converts a legacy REAL pounds value to piasters only when it is exactly a
/// whole number of piasters (allowing for binary representation error). A value
/// with sub-piaster precision returns null so the caller keeps it unconverted
/// and reports it; nothing is rounded silently.
int? exactMinor(num? pounds) {
  if (pounds == null || !pounds.isFinite) return null;
  final scaled = pounds * 100;
  final r = scaled.round();
  if ((scaled - r).abs() > 1e-6) return null;
  return r;
}

/// Effect of a transaction on its wallet balance, in piasters. A fee the owner
/// pays is a charge: incoming = +amount - fee, outgoing = -(amount + fee); a fee
/// paid by someone else does not move the wallet. Null when the
/// direction or an amount is unknown (the impact is then not guessed).
int? walletImpactMinor(String dir, int? amountMinor, int? feeMinor,
    {String feeOwner = 'owner'}) {
  if (amountMinor == null) return null;
  // Only a fee the wallet owner pays moves the wallet. A fee paid by the
  // sender or another party is not deducted, and an unknown owner is not
  // guessed: it stays out of the impact and shows up as an uncertain amount.
  final fee = feeOwner == 'owner' ? (feeMinor ?? 0) : 0;
  return switch (dir) {
    'in' => amountMinor - fee,
    'out' => -(amountMinor + fee),
    _ => null,
  };
}

/// Who pays a fee.
class FeeOwner {
  static const owner = 'owner';
  static const sender = 'sender';
  static const other = 'other';
  static const unknown = 'unknown';
  static const all = {owner, sender, other, unknown};
}
