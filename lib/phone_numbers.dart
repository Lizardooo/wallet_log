/// Egyptian mobile numbers: cleaning what the phone or the owner gives us,
/// checking it, and hinting the prefix from the SIM's carrier.
library;

import 'parser.dart';

/// Turns "+20 101 234 5678", "00201012345678", "201012345678" or
/// "١٠١٢٣٤٥٦٧٨" into "01012345678". Returns '' when nothing usable is left.
String normalizeEgyptPhone(String raw) {
  var d = normalizeDigits(raw).replaceAll(RegExp(r'[^0-9]'), '');
  if (d.isEmpty) return '';
  if (d.startsWith('0020')) d = d.substring(4);
  if (d.startsWith('20') && d.length == 12) d = d.substring(2);
  if (d.length == 10 && d.startsWith('1')) d = '0$d';
  return d;
}

/// An Egyptian mobile number: 11 digits, 010 / 011 / 012 / 015.
bool isValidEgyptMobile(String number) =>
    RegExp(r'^01[0125][0-9]{8}$').hasMatch(number);

/// What is wrong with a typed number, in plain Arabic, or null when it is fine.
String? phoneProblem(String raw) {
  final n = normalizeEgyptPhone(raw);
  if (n.isEmpty) return 'اكتب الرقم';
  if (isValidEgyptMobile(n)) return null;
  if (n.length != 11) return 'الرقم لازم يكون 11 رقم ويبدأ بـ 01';
  return 'الرقم لازم يبدأ بـ 010 أو 011 أو 012 أو 015';
}

/// The usual prefix for a carrier name as Android reports it, or null.
String? carrierPrefix(String carrier) {
  final c = carrier.toLowerCase();
  if (c.contains('vodafone') || c.contains('فودافون')) return '010';
  if (c.contains('etisalat') || c.contains('e&') || c.contains('اتصالات')) {
    return '011';
  }
  if (c.contains('orange') || c.contains('mobinil') || c.contains('أورنج')) {
    return '012';
  }
  if (c == 'we' || c.contains('we ') || c.contains('telecom egypt')) {
    return '015';
  }
  return null;
}
