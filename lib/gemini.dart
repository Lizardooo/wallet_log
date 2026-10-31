import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'parser.dart';

/// A failure we can show to the owner as-is (Arabic, actionable).
class GeminiException implements Exception {
  final String message;
  const GeminiException(this.message);

  @override
  String toString() => message;
}

/// One model offered by the API key. [free] marks the ones that run on Google's
/// free tier (flash / flash-lite / gemma families).
class GeminiModel {
  final String id;
  final String displayName;
  final String description;
  final bool free;

  const GeminiModel({
    required this.id,
    required this.displayName,
    this.description = '',
    this.free = false,
  });
}

/// One message as sent to the model.
class AiItem {
  final int id;
  final String wallet;
  final String amount;
  final String guess; // what the SMS parser thought
  final String body;

  const AiItem({
    required this.id,
    required this.wallet,
    required this.body,
    this.amount = '',
    this.guess = '',
  });
}

/// What the model decided about one message.
class AiClass {
  final int id;
  final TxType type;
  final Dir dir;
  final double confidence;
  final String reason;

  const AiClass({
    required this.id,
    required this.type,
    required this.dir,
    required this.confidence,
    this.reason = '',
  });
}

const _base = 'https://generativelanguage.googleapis.com/v1beta';

// Model families that cannot classify text (images, audio, embeddings...) or
// that are not chat models are hidden from the picker.
const _notForText = [
  'embedding',
  'embed',
  'aqa',
  'imagen',
  'image',
  'veo',
  'tts',
  'audio',
  'live',
  'native-audio',
  'computer-use',
  'robotics',
  'deep-research',
  'learnlm',
  'gemma-3n',
];

bool _usable(String id) {
  final l = id.toLowerCase();
  if (!l.startsWith('gemini') && !l.startsWith('gemma')) return false;
  for (final bad in _notForText) {
    if (l.contains(bad)) return false;
  }
  return true;
}

/// Models that include a usable free tier with an AI Studio API key.
bool isFreeModel(String id) {
  final l = id.toLowerCase();
  if (l.startsWith('gemma')) return true;
  if (l.contains('pro') || l.contains('ultra')) return false;
  return l.contains('flash') || l.contains('lite');
}

String _shortErr(http.Response res) {
  try {
    final body = jsonDecode(res.body);
    if (body is Map && body['error'] is Map) {
      final e = body['error'] as Map;
      final msg = (e['message'] ?? '').toString();
      if (msg.isNotEmpty) return msg;
    }
  } catch (_) {
    // not JSON: fall through
  }
  return res.body.length > 200 ? res.body.substring(0, 200) : res.body;
}

Never _fail(http.Response res) {
  final detail = _shortErr(res);
  final msg = switch (res.statusCode) {
    400 => 'جوجل رفضت الطلب. غالباً المفتاح غير صحيح أو الموديل غير متاح له.',
    401 || 403 => 'المفتاح مرفوض. تأكد أنك أنشأته من Google AI Studio وأن '
        'Generative Language API مفعّل عليه.',
    404 => 'الموديل غير موجود لهذا المفتاح. اضغط "جلب الموديلات" واختر موديلاً '
        'من القائمة.',
    429 => 'تجاوزت حدود الاستخدام المجاني أو عدد الطلبات في الدقيقة. انتظر '
        'قليلاً ثم أعد المحاولة.',
    _ => 'خطأ من جوجل (${res.statusCode}).',
  };
  throw GeminiException(detail.isEmpty ? msg : '$msg\n$detail');
}

String _cleanModel(String model) {
  var m = model.trim();
  if (m.startsWith('models/')) m = m.substring('models/'.length);
  return m;
}

/// Asks Google which models this API key can use, keeping the readable ones and
/// marking the free-tier families.
Future<List<GeminiModel>> listGeminiModels(
  String apiKey, {
  http.Client? client,
}) async {
  final key = apiKey.trim();
  if (key.isEmpty) {
    throw const GeminiException('أدخل مفتاح API أولاً.');
  }
  final c = client ?? http.Client();
  try {
    final uri = Uri.parse('$_base/models')
        .replace(queryParameters: {'key': key, 'pageSize': '1000'});
    final res = await c
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) _fail(res);

    final decoded = jsonDecode(res.body);
    if (decoded is! Map) {
      throw const GeminiException('رد غير متوقع من جوجل.');
    }
    final list = decoded['models'];
    final out = <GeminiModel>[];
    if (list is List) {
      for (final e in list) {
        if (e is! Map) continue;
        final name = (e['name'] ?? '').toString();
        final id = _cleanModel(name);
        if (id.isEmpty || !_usable(id)) continue;
        final methods = e['supportedGenerationMethods'];
        if (methods is List &&
            !methods.map((m) => m.toString()).contains('generateContent')) {
          continue;
        }
        out.add(GeminiModel(
          id: id,
          displayName: (e['displayName'] ?? id).toString(),
          description: (e['description'] ?? '').toString(),
          free: isFreeModel(id),
        ));
      }
    }
    if (out.isEmpty) {
      throw const GeminiException(
        'المفتاح لا يملك أي موديل يقرأ النصوص. أنشئ مفتاحاً جديداً من '
        'Google AI Studio ثم أعد المحاولة.',
      );
    }
    out.sort((a, b) {
      if (a.free != b.free) return a.free ? -1 : 1;
      return a.id.compareTo(b.id);
    });
    return out;
  } on GeminiException {
    rethrow;
  } on TimeoutException {
    throw const GeminiException(
        'انتهت مدة الاتصال بجوجل. تحقق من الإنترنت وحاول مرة أخرى.');
  } on SocketException {
    throw const GeminiException(
        'لا يوجد اتصال بالإنترنت. اتصل بالشبكة ثم أعد المحاولة.');
  } on http.ClientException catch (e) {
    throw GeminiException('تعذر الوصول إلى جوجل: ${e.message}');
  } on FormatException {
    throw const GeminiException('رد غير مفهوم من جوجل. حاول مرة أخرى.');
  } finally {
    if (client == null) c.close();
  }
}

const _systemPrompt = '''
أنت محلل مالي خبير في المحافظ الإلكترونية المصرية (فودافون كاش، إنستاباي،
أورنج كاش، اتصالات كاش / فوري). تقرأ رسائل SMS الحقيقية لتاجر عملات وتصنّف كل
رسالة بدقة محاسبية، بدون تخمين.

لكل رسالة استخرج:
- type (نوع العملية): transfer تحويل، deduction خصم رصيد، cashIn إيداع نقدي،
  cashOut سحب نقدي، topup شحن رصيد موبايل، bill فواتير وخدمات، payment دفع لتاجر،
  refund استرداد، fee رسوم فقط، other غير معروفة.
- dir (الاتجاه): in دخل للمحفظة، out خرج من المحفظة، unknown غير محدد.
- confidence من 0 إلى 1، و reason سبب قصير بالعربية.

قواعد إلزامية:
1. رسالة "وخصم X من محفظتك" تعني دائماً خروج X من المحفظة، ويكون X هو المبلغ
   المسحوب حتى لو ذكرت الرسالة تحويلاً أو شحناً بقيمة أقل (الفرق رسوم/ضريبة).
2. رسالة OTP أو رمز تحقق أو عملية فاشلة/مرفوضة/ملغاة/قيد المعالجة أو رسالة
   عرض ترويجي أو رسالة رصيد فقط: type = other و dir = unknown و confidence عالية.
3. رسالة الرصيد المتبقي ليست عملية. مبلغ الحد الأقصى أو الرسوم وحده ليس مبلغ
   العملية إذا كانت الرسالة تذكر عملية أخرى.
4. التحويل المستلم من رقم آخر = transfer + in. المرسل إلى رقم آخر = transfer + out.
5. لا تخترع أرقاماً غير موجودة في نص الرسالة.
''';

String _buildPrompt(List<AiItem> items) {
  final rows = <String>[];
  for (final i in items) {
    rows.add(jsonEncode({
      'id': i.id,
      'wallet': i.wallet,
      'parser_said': i.guess,
      'sms': i.body.length > 600 ? i.body.substring(0, 600) : i.body,
    }));
  }
  return 'صنّف هذه الرسائل. أعد JSON فقط: مصفوفة بنفس عدد الرسائل وبنفس id، '
      'كل عنصر: '
      '{"id": رقم, "type": "transfer|deduction|cashIn|cashOut|topup|bill|payment|refund|fee|other", '
      '"dir": "in|out|unknown", "confidence": 0.0-1.0, "reason": "سبب قصير"}\n\n'
      '${rows.join('\n')}';
}

/// Classifies one batch of messages. [model] is an id from [listGeminiModels].
Future<List<AiClass>> classifyMessages({
  required String apiKey,
  required String model,
  required List<AiItem> items,
  http.Client? client,
}) async {
  final key = apiKey.trim();
  final id = _cleanModel(model);
  if (key.isEmpty) throw const GeminiException('أدخل مفتاح API أولاً.');
  if (id.isEmpty) {
    throw const GeminiException('اختر موديلاً من قائمة الموديلات أولاً.');
  }
  if (items.isEmpty) return const [];

  final c = client ?? http.Client();
  try {
    final uri =
        Uri.parse('$_base/models/${Uri.encodeComponent(id)}:generateContent')
            .replace(queryParameters: {'key': key});
    final body = jsonEncode({
      'systemInstruction': {
        'role': 'system',
        'parts': [
          {'text': _systemPrompt}
        ],
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': _buildPrompt(items)}
          ],
        }
      ],
      'generationConfig': {
        'temperature': 0.1,
        'responseMimeType': 'application/json',
      },
    });
    final res = await c
        .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
        .timeout(const Duration(seconds: 120));
    if (res.statusCode != 200) _fail(res);

    final decoded = jsonDecode(res.body);
    final text = _textOf(decoded);
    if (text == null || text.trim().isEmpty) {
      throw const GeminiException(
          'الموديل لم يرجع نصاً. جرّب موديلاً آخر من القائمة.');
    }
    return parseAiResponse(text, items);
  } on GeminiException {
    rethrow;
  } on TimeoutException {
    throw const GeminiException(
        'الموديل تأخر في الرد. قلّل عدد الرسائل أو اختر موديلاً أسرع.');
  } on SocketException {
    throw const GeminiException(
        'لا يوجد اتصال بالإنترنت. اتصل بالشبكة ثم أعد المحاولة.');
  } on http.ClientException catch (e) {
    throw GeminiException('تعذر الوصول إلى جوجل: ${e.message}');
  } on FormatException {
    throw const GeminiException('رد غير مفهوم من الموديل. حاول مرة أخرى.');
  } finally {
    if (client == null) c.close();
  }
}

String? _textOf(dynamic decoded) {
  if (decoded is! Map) return null;
  final candidates = decoded['candidates'];
  if (candidates is! List || candidates.isEmpty) return null;
  final first = candidates.first;
  if (first is! Map) return null;
  final content = first['content'];
  if (content is! Map) return null;
  final parts = content['parts'];
  if (parts is! List) return null;
  final buffer = StringBuffer();
  for (final p in parts) {
    if (p is Map && p['text'] != null) buffer.write(p['text'].toString());
  }
  final out = buffer.toString();
  return out.isEmpty ? null : out;
}

/// Parses the model's JSON answer. Kept public so it can be tested without
/// touching the network.
List<AiClass> parseAiResponse(String raw, List<AiItem> items) {
  final start = raw.indexOf('[');
  final end = raw.lastIndexOf(']');
  if (start < 0 || end <= start) {
    throw const GeminiException(
        'رد الموديل لم يكن JSON صالحاً. جرّب موديلاً آخر أو أعد المحاولة.');
  }
  final dynamic decoded;
  try {
    decoded = jsonDecode(raw.substring(start, end + 1));
  } on FormatException {
    throw const GeminiException(
        'رد الموديل لم يكن JSON صالحاً. جرّب موديلاً آخر أو أعد المحاولة.');
  }
  if (decoded is! List) {
    throw const GeminiException('رد الموديل غير متوقع.');
  }

  final known = {for (final i in items) i.id};
  final out = <AiClass>[];
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final id = _asInt(entry['id']);
    if (id == null || !known.contains(id)) continue;
    final type = _asType(entry['type']);
    final dir = _asDir(entry['dir']);
    var conf = _asDouble(entry['confidence']) ?? 0;
    if (conf < 0) conf = 0;
    if (conf > 1) conf = 1;
    out.add(AiClass(
      id: id,
      type: type,
      dir: dir,
      confidence: conf,
      reason: (entry['reason'] ?? '').toString().trim(),
    ));
  }
  if (out.isEmpty) {
    throw const GeminiException(
        'لم يتعرف الموديل على أي رسالة من الدفعة. جرّب موديلاً آخر.');
  }
  return out;
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.replaceAll(RegExp(r'[^0-9]'), ''));
  return null;
}

double? _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

TxType _asType(dynamic v) {
  final s = (v ?? '').toString().toLowerCase().trim();
  if (s.isEmpty) return TxType.other;
  for (final t in TxType.values) {
    if (t.name.toLowerCase() == s) return t;
    if (t.label == s) return t;
  }
  for (final t in TxType.values) {
    if (s.contains(t.name.toLowerCase())) return t;
  }
  if (s.contains('تحويل') || s.contains('transfer')) return TxType.transfer;
  if (s.contains('خصم') || s.contains('deduct')) return TxType.deduction;
  if (s.contains('ايداع') || s.contains('إيداع') || s.contains('deposit')) {
    return TxType.cashIn;
  }
  if (s.contains('سحب') || s.contains('withdraw')) return TxType.cashOut;
  if (s.contains('شحن') || s.contains('top')) return TxType.topup;
  if (s.contains('فاتور') || s.contains('bill')) return TxType.bill;
  if (s.contains('رسوم') || s.contains('fee')) return TxType.fee;
  if (s.contains('استرداد') || s.contains('refund')) return TxType.refund;
  if (s.contains('دفع') || s.contains('payment') || s.contains('شراء')) {
    return TxType.payment;
  }
  return TxType.other;
}

Dir _asDir(dynamic v) {
  final s = (v ?? '').toString().toLowerCase().trim();
  if (s == 'in' || s.contains('داخل') || s.contains('وارد') || s.contains('credit')) {
    return Dir.inFlow;
  }
  if (s == 'out' ||
      s.contains('خارج') ||
      s.contains('صادر') ||
      s.contains('debit')) {
    return Dir.outFlow;
  }
  return Dir.unknown;
}
