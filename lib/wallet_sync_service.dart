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
    final value = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    await TxDb.setSetting(deviceIdKey, value);
    return value;
  }

  static String providerCode(String name) => name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');

  static Future<Map<String, dynamic>> sync({
    required String endpoint,
    required String token,
  }) async {
    final url = endpoint.trim().endsWith('/api/wallets/sync')
        ? endpoint.trim()
        : '${endpoint.trim().replaceAll(RegExp(r'/+$'), '')}/api/wallets/sync';
    if (endpoint.trim().isEmpty || token.trim().isEmpty) {
      throw StateError('أدخل رابط لوحة التحكم ورمز المزامنة أولاً.');
    }

    final accounts = await TxDb.accounts();
    final transactions = (await TxDb.allTx()).where((t) => !t.isExcluded).toList();
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
        'occurred_at': DateTime.fromMillisecondsSinceEpoch(tx.ts).toUtc().toIso8601String(),
        'direction': tx.isIn ? 'in' : tx.isOut ? 'out' : 'unknown',
        'type': tx.type.name,
        'amount_minor': (tx.amount * 100).round(),
        'fee_minor': (tx.fee * 100).round(),
        'balance_after_minor': tx.balance == null ? null : (tx.balance! * 100).round(),
        'party': tx.party,
        'note': tx.note,
        'body': tx.body,
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

    final response = await http.post(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer ${token.trim()}', 'Content-Type': 'application/json'},
      body: jsonEncode({
        'device_id': await deviceId(),
        'accounts': accountRows,
        'transactions': txRows,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('فشلت المزامنة (${response.statusCode}): ${response.body}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['ok'] != true) {
      throw StateError('استجابة غير صالحة من لوحة التحكم.');
    }
    return decoded;
  }
}
