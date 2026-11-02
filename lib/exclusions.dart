import 'parser.dart';

/// Accounting state is independent of operation type and AI classification.
enum TxDisposition { active, deferred, ignored, duplicate }

/// [template]: the same message text once every number (amount, phone,
/// balance, date, reference) is blanked out. It only ever excludes messages
/// still waiting for review, never a counted transaction.
enum ExclusionMatch { exact, contains, template }

String normalizeExclusionText(String text) =>
    normalizeDigits(text).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// The message with every word that holds a digit replaced by "#", so
/// "تم ايداع 500 جنيه. رصيدك 900" and "تم ايداع 20 جنيه. رصيدك 35.5" are the
/// same text.
String messageTemplate(String body) => normalizeExclusionText(body)
    .replaceAll(RegExp(r'\S*[0-9]\S*'), '#')
    .replaceAll(RegExp(r'#(?:[ ]#)+'), '#');

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

  /// Exact / contains rules, checked wherever a message is read. Template
  /// rules are applied separately, to messages in review only.
  bool matches(String wallet, String body) {
    if (match == ExclusionMatch.template) return false;
    if (this.wallet != wallet) return false;
    final pattern = normalizeExclusionText(text);
    if (pattern.isEmpty) return false;
    final value = normalizeExclusionText(body);
    return match == ExclusionMatch.exact
        ? value == pattern
        : value.contains(pattern);
  }
}

extension ExclusionTemplate on ExclusionRule {
  bool matchesTemplate(String body) =>
      match == ExclusionMatch.template &&
      text.isNotEmpty &&
      messageTemplate(body) == text;
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
