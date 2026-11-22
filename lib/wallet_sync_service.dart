import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'db.dart';
import 'logic.dart';

class WalletSyncService {
  static const endpointKey = 'wallet_sync_endpoint';
  static const tokenKey = 'wallet_sync_token';
  static const deviceIdKey = 'wallet_sync_device_id';

  static Future<String> deviceId() async {
    final existing = await TxDb.setting(deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final value = List.generate(
            16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    await TxDb.setSetting(deviceIdKey, value);
    return value;
  }

  static String providerCode(String name) => name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');

  /// Resolve and validate before any credential is saved or network call made.
  static Uri validatedEndpoint(String endpoint) {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw StateError(
          'استخدم رابط HTTPS صحيحاً بدون بيانات دخول أو استعلام أو جزء #.');
    }
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    return uri.replace(
        path: path.endsWith('/api/wallets/sync')
            ? path
            : '$path/api/wallets/sync');
  }

  static Future<Map<String, dynamic>> sync({
    required String endpoint,
    required String token,
    required bool confirmed,
    bool includeMessageText = false,
    http.Client? client,
  }) async {
    final url = validatedEndpoint(endpoint);
    if (!confirmed) {
      throw StateError('يلزم تأكيد البيانات والوجهة قبل كل مزامنة.');
    }
    if (token.trim().isEmpty) {
      throw StateError('أدخل رمز المزامنة أولاً.');
    }

    final accounts = await TxDb.accounts();
    final transactions =
        (await TxDb.allTx()).where((t) => !t.isExcluded).toList();
    final accountRows = <Map<String, dynamic>>[];
    final accountKeys = <int, String>{};
    final latestBalances = <String, Tx>{};
    for (final account in accounts) {
      if (account.id == null) continue;
      final code = providerCode(account.wallet);
      final key = '$code|${account.number}';
      accountKeys[account.id!] = key;
      accountRows.add({
        'key': key,
        'provider_code': code,
        'provider_name': account.wallet,
        'phone': account.number,
        'name': account.name,
      });
    }

    final txRows = <Map<String, dynamic>>[];
    for (final tx in transactions) {
      final account = accountFor(tx, accounts);
      if (account == null) continue;
      final key = accountKeys[account.id];
      if (key == null) continue;
      final prior = latestBalances[key];
      if (tx.balance != null && (prior == null || tx.ts > prior.ts)) {
        latestBalances[key] = tx;
      }
      txRows.add({
        'source_key': '${await deviceId()}:${tx.id}',
        'account_key': key,
        'local_id': tx.id,
        'occurred_at': DateTime.fromMillisecondsSinceEpoch(tx.ts)
            .toUtc()
            .toIso8601String(),
        'direction': tx.isIn
            ? 'in'
            : tx.isOut
                ? 'out'
                : 'unknown',
        'type': tx.type.name,
        'amount_minor': (tx.amount * 100).round(),
        'fee_minor': (tx.fee * 100).round(),
        'balance_after_minor':
            tx.balance == null ? null : (tx.balance! * 100).round(),
        'party': tx.party,
        'note': tx.note,
        if (includeMessageText) 'body': tx.body,
        'needs_review': tx.review || tx.isUnknown,
        'source': tx.source,
      });
    }
    for (final row in accountRows) {
      final latest = latestBalances[row['key']];
      if (latest != null) {
        row['last_balance_minor'] = (latest.balance! * 100).round();
        row['last_balance_ts'] = latest.ts;
      }
    }

    final c = client ?? http.Client();
    try {
      final request = http.Request('POST', url)
        ..followRedirects = false
        ..headers.addAll({
          'Authorization': 'Bearer ${token.trim()}',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode({
          'device_id': await deviceId(),
          'accounts': accountRows,
          'transactions': txRows,
        });
      final response =
          await c.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw StateError(
            'رفضت إعادة التوجيه لحماية بياناتك. تحقق من رابط لوحة التحكم.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
            'فشلت المزامنة (${response.statusCode}). تحقق من الرابط والرمز.');
      }
      // Cap the response body so an endpoint cannot fill device memory.
      final bytes = <int>[];
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) {
          throw StateError('استجابة لوحة التحكم أكبر من الحد المسموح.');
        }
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
        throw StateError('استجابة غير صالحة من لوحة التحكم.');
      }
      return decoded;
    } on TimeoutException {
      throw StateError(
          'انتهت مهلة الاتصال. قد يكون الخادم استلم البيانات؛ تحقق قبل إعادة المحاولة.');
    } finally {
      if (client == null) c.close();
    }
  }
}
