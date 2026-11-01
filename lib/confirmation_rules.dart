/// Decides from the text alone whether a provider SMS reports a *completed*
/// transaction. A trusted sender is not enough: failed, pending, rejected and
/// OTP messages must never count as confirmed money.
library;

import 'parser.dart';

enum SmsOutcome { completed, failed, pending, unclear }

/// How a confirmation was reached; stored beside the status, never instead.
class ConfirmMethod {
  static const smsContent = 'sms_content';
  static const providerCheck = 'provider_check';
  static const balanceCheck = 'balance_check';
  static const smsMatch = 'sms_match';
}

final _failed = RegExp(
    r'فشل|فاشل|لم تتم|لم يتم|تعذر|مرفوض|رفض|ملغ|غير ناجح|غير كاف|رصيد غير|خطأ|'
    r'fail|declin|reject|unsuccess|insufficient|cancel|error|not (?:completed|successful)|could not|unable',
    caseSensitive: false);
final _pending = RegExp(
    r'قيد المعالج|قيد التنفيذ|جاري|جارى|سيتم|انتظر|معلق|يرجى الانتظار|'
    r'pending|processing|in progress|will be|awaiting|please wait',
    caseSensitive: false);
final _otp = RegExp(r'otp|رمز التحقق|كود التحقق|verification code|one.time',
    caseSensitive: false);
final _done = RegExp(
    r'تم\s+(?:ال)?(?:استلام|تحويل|إرسال|ارسال|سحب|إيداع|ايداع|دفع|شحن|خصم|اضافة|إضافة|سداد|استرداد)|'
    r'تم بنجاح|بنجاح|لقد استلمت|استلمت|received|you have sent|has been (?:sent|credited|debited|deposited|withdrawn)|'
    r'successful(?:ly)?|completed|paid|withdrawn|deposited|credited|debited|sent',
    caseSensitive: false);

SmsOutcome classifySmsCompletion(String body) {
  final t = normalizeDigits(body);
  if (_otp.hasMatch(t)) return SmsOutcome.unclear;
  if (_failed.hasMatch(t)) return SmsOutcome.failed;
  if (_pending.hasMatch(t)) return SmsOutcome.pending;
  return _done.hasMatch(t) ? SmsOutcome.completed : SmsOutcome.unclear;
}
