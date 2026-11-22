import 'package:flutter/material.dart';

/// In-app explanation before Android's SMS permission prompt. This is not a
/// replacement for the system permission or a Play Protect approval.
const smsConsentKey = 'sms_access_disclosure_v1';
const smsDisclosureAr =
    'يقرأ أموالي صندوق الرسائل على هذا الهاتف للعثور على رسائل المحافظ '
    'واستخراج العمليات والأرصدة محلياً. إذن Android يتيح قراءة الصندوق، '
    'وليس رسائل المحافظ وحدها؛ يصفّي التطبيق الرسائل بعد قراءتها. '
    'لا يرسل التطبيق رسائل SMS ولا ينفذ تحويلات مالية.\n\n'
    'تحليل Gemini اختياري: عند تفعيله وطلب التحليل تُرسل مقتطفات من رسائل '
    'المحافظ وسياق العملية إلى Google، مع إخفاء جزئي للأرقام. '
    'هذا الإخفاء ليس ضماناً لإزالة كل البيانات الشخصية. '
    'المزامنة اختيارية وترسل بيانات إلى لوحة التحكم التي تختارها بعد تأكيد منفصل.\n\n'
    'يمكنك الرفض واستخدام الإدخال اليدوي واستيراد الملفات. '
    'يمكن سحب إذن الرسائل من إعدادات Android في أي وقت.';

Future<bool> showSmsDisclosure(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('قراءة رسائل المحافظ'),
        content: const SingleChildScrollView(child: Text(smsDisclosureAr)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('بدون قراءة الرسائل'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('أوافق وأتابع'),
          ),
        ],
      ),
    ) ??
    false;

Future<bool> showSimDisclosure(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('اكتشاف شرائح الهاتف'),
        content: const SingleChildScrollView(
          child: Text(
            'يطلب أموالي حالة الهاتف وأرقام الشرائح لعرض الشرائح النشطة '
            'وربط كل محفظة بالرقم الذي تختاره. تُحفظ الاختيارات على الهاتف، '
            'وتُشارك أرقام حسابات المحافظ مع لوحة التحكم فقط عند تأكيد المزامنة. '
            'لا يجري التطبيق مكالمات ولا يقرأ سجل المكالمات. '
            'قد لا توفر الشبكة الرقم حتى مع الإذن؛ يمكنك إدخاله يدوياً '
            'بدون السماح باكتشاف الشرائح.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إدخال يدوي'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('السماح بالاكتشاف'),
          ),
        ],
      ),
    ) ??
    false;

Future<bool> showSyncDisclosure(
  BuildContext context,
  Uri target, {
  required bool includeMessageText,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('تأكيد إرسال بيانات المحافظ'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('ستُرسل البيانات إلى العنوان التالي فقط:'),
              const SizedBox(height: 8),
              Directionality(
                textDirection: TextDirection.ltr,
                child: SelectableText(target.toString()),
              ),
              const SizedBox(height: 12),
              const Text(
                'المحتوى: أسماء وأرقام حسابات المحافظ، الأرصدة، المبالغ '
                'والرسوم، أوقات العمليات واتجاهها، الطرف الآخر والملاحظات، '
                'ومعرّف لهذا التثبيت. لا تُرسل صور الإيصالات أو الملفات.',
              ),
              const SizedBox(height: 8),
              Text(includeMessageText
                  ? 'اخترت أيضاً إرسال نصوص رسائل المعاملات كاملة، '
                      'بما فيها أي بيانات شخصية أو أرقام واردة فيها.'
                  : 'لن تُرسل نصوص الرسائل. قد تبقى بيانات شخصية '
                      'ضمن الطرف الآخر أو الملاحظات.'),
              const SizedBox(height: 8),
              const Text(
                'تأكد أن لوحة التحكم تخصك أو أنك تثق بمسؤولها. '
                'إلغاء هذا الطلب لا يحذف بيانات أُرسلت سابقاً. '
                'كل مزامنة يدوية وتحتاج هذا التأكيد.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إرسال الآن'),
          ),
        ],
      ),
    ) ??
    false;
