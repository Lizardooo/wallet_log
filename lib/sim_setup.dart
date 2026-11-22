import 'parser.dart';

/// Preserve international numbers, but use the local form for Egyptian mobile
/// numbers so automatic and manual entries have the same identity.
String normalizeSimNumber(String raw) {
  var n = normalizeDigits(raw).replaceAll(RegExp(r'[\s()\-]'), '');
  if (n.startsWith('0020')) n = '+20${n.substring(4)}';
  if (RegExp(r'^\+201[0125]\d{8}$').hasMatch(n)) {
    n = '0${n.substring(3)}';
  }
  if (!RegExp(r'^\+?\d{7,15}$').hasMatch(n)) return '';
  return n;
}

String defaultWalletKey(int? subId, String number) =>
    'default_wallet:${subId == null ? 'phone:$number' : 'sub:$subId'}';
