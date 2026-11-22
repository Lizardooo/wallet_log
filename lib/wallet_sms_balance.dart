import 'db.dart';
import 'parser.dart';
import 'money_engine.dart';

/// A literal balance from one SMS. It is not a ledger opening, calculated
/// balance, or proof that no later wallet activity occurred.
class SmsWalletBalance {
  final int accountId;
  final String provider;
  final String number;
  final int minor;
  final int ts;
  final bool ambiguous;
  const SmsWalletBalance(
      this.accountId, this.provider, this.number, this.minor, this.ts,
      {this.ambiguous = false});
}

/// A single pass over the raw inbox also catches balance-only messages that
/// parseSms deliberately does not turn into transactions. Never use the
/// counterparty number from the SMS to infer the owner's line.
Map<int, SmsWalletBalance> latestSmsBalances(
    List<RawSms> messages, List<Account> accounts,
    {int? before}) {
  final out = <int, SmsWalletBalance>{};
  for (final sms in messages) {
    if (before != null && sms.ts >= before) continue;
    final provider = detectWallet(sms.sender, sms.body);
    if (provider == null) continue;
    var candidates = accounts.where((a) => a.wallet == provider).toList();
    if (sms.subId != null) {
      final exact = candidates.where((a) => a.subId == sms.subId).toList();
      if (exact.isNotEmpty) {
        candidates = exact;
      } else {
        if (candidates.any((a) => a.subId != null)) continue;
        // Unknown line + several same-provider wallets is not enough evidence.
        candidates = candidates.where((a) => a.subId == null).toList();
      }
    }
    // Without a subscription id, more than one wallet is ambiguous.
    if (candidates.length != 1 || candidates.single.id == null) continue;
    final account = candidates.single;
    final amount = statedWalletBalance(sms.sender, sms.body);
    if (amount == null) continue;
    final minor = parseMinor(amount);
    if (minor == null || minor < 0) continue;
    final prior = out[account.id];
    if (prior == null || sms.ts > prior.ts) {
      out[account.id!] = SmsWalletBalance(
          account.id!, provider, account.number, minor, sms.ts);
    } else if (sms.ts == prior.ts && minor != prior.minor) {
      // No stable ordering can resolve conflicting balances with equal times.
      out[account.id!] = SmsWalletBalance(
          account.id!, provider, account.number, prior.minor, sms.ts,
          ambiguous: true);
    }
  }
  return out..removeWhere((_, balance) => balance.ambiguous);
}
