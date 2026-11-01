import 'parser.dart';

/// Accounting state is independent of operation type and AI classification.
enum TxDisposition { active, deferred, ignored, duplicate }

enum ExclusionMatch { exact, contains }

String normalizeExclusionText(String text) =>
    normalizeDigits(text).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

class ExclusionRule {
  final int id;
  final String wallet;
  final ExclusionMatch match;
  final String text;

  const ExclusionRule(
      {required this.id,
      required this.wallet,
      required this.match,
      required this.text});

  bool matches(String wallet, String body) {
    if (this.wallet != wallet) return false;
    final pattern = normalizeExclusionText(text);
    if (pattern.isEmpty) return false;
    final value = normalizeExclusionText(body);
    return match == ExclusionMatch.exact
        ? value == pattern
        : value.contains(pattern);
  }
}

TxDisposition dispositionFromString(String? value) => TxDisposition.values
    .firstWhere((d) => d.name == value, orElse: () => TxDisposition.active);

ExclusionRule? matchingExclusionRule(
    Iterable<ExclusionRule> rules, String wallet, String body) {
  for (final rule in rules) {
    if (rule.matches(wallet, body)) return rule;
  }
  return null;
}
