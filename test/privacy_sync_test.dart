import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/wallet_sync_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  setUpAll(() => databaseFactory = databaseFactoryFfi);
  setUp(() async {
    await TxDb.close();
    dir = await Directory.systemTemp.createTemp('privacy-sync-');
    await databaseFactory.setDatabasesPath(dir.path);
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() async {
    await TxDb.close();
    await dir.delete(recursive: true);
  });

  test('HTTPS endpoints normalize without sending anything', () {
    expect(
        WalletSyncService.validatedEndpoint(' https://example.com/ ')
            .toString(),
        'https://example.com/api/wallets/sync');
    expect(WalletSyncService.validatedEndpoint('https://example.com/sub/').path,
        '/sub/api/wallets/sync');
    expect(
        WalletSyncService.validatedEndpoint(
                'https://example.com/api/wallets/sync/')
            .path,
        '/api/wallets/sync');
  });
  for (final url in [
    'http://example.com',
    'example.com',
    'https://',
    'https://user:password@example.com',
    'https://example.com?token=x',
    'https://example.com/#fragment',
    'file:///tmp/a',
  ]) {
    test('unsafe destination rejected: $url', () async {
      var calls = 0;
      final c = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      await expectLater(
          WalletSyncService.sync(
              endpoint: url, token: 'secret', confirmed: true, client: c),
          throwsStateError);
      expect(calls, 0);
    });
  }
  test('no consent means no network or device ID creation', () async {
    var calls = 0;
    final c = MockClient((_) async {
      calls++;
      return http.Response('{}', 200);
    });
    await expectLater(
        WalletSyncService.sync(
            endpoint: 'https://example.com',
            token: 'secret',
            confirmed: false,
            client: c),
        throwsStateError);
    expect(calls, 0);
    expect(await TxDb.setting(WalletSyncService.deviceIdKey), isNull);
  });
  Future<void> seed() async {
    await TxDb.saveAccount(Account(
        name: 'wallet',
        wallet: 'Vodafone Cash',
        number: '01011111111',
        subId: 1,
        slot: 0));
    await TxDb.importSms([
      const RawSms(
          'VF-Cash',
          'You have received 100.00 EGP from 01012345678. Your balance is EGP 500.00',
          1700000000000,
          1)
    ]);
  }

  for (final include in [false, true]) {
    test('message text only sent with explicit inclusion: $include', () async {
      await seed();
      var calls = 0;
      final c = MockClient((request) async {
        calls++;
        expect(request.followRedirects, false);
        expect(request.url.toString(), 'https://example.com/api/wallets/sync');
        final body = jsonDecode(request.body) as Map;
        final row = (body['transactions'] as List).single as Map;
        expect(row.containsKey('body'), include);
        if (include) expect(row['body'], contains('You have received'));
        expect((body['accounts'] as List).single['phone'], '01011111111');
        return http.Response('{"ok":true,"inserted":1}', 200);
      });
      await WalletSyncService.sync(
          endpoint: 'https://example.com',
          token: 'secret',
          confirmed: true,
          includeMessageText: include,
          client: c);
      expect(calls, 1);
    });
  }
  test('redirects rejected without a second request', () async {
    var calls = 0;
    final c = MockClient((request) async {
      calls++;
      expect(request.followRedirects, false);
      return http.Response('', 307,
          headers: {'location': 'https://other.invalid'});
    });
    await expectLater(
        WalletSyncService.sync(
            endpoint: 'https://example.com',
            token: 'secret',
            confirmed: true,
            client: c),
        throwsStateError);
    expect(calls, 1);
  });
  test('server body is not echoed into errors', () async {
    final c = MockClient((_) async => http.Response('private secret', 401));
    try {
      await WalletSyncService.sync(
          endpoint: 'https://example.com',
          token: 'secret',
          confirmed: true,
          client: c);
      fail('expected error');
    } catch (e) {
      expect(e.toString(), isNot(contains('private secret')));
    }
  });
  test('legacy token migrated only after secure write and verification',
      () async {
    await TxDb.setSetting(WalletSyncService.tokenKey, 'legacy-token');
    expect(await TxDb.syncToken(), 'legacy-token');
    expect(await TxDb.setting(WalletSyncService.tokenKey), isNull);
    expect(
        await const FlutterSecureStorage()
            .read(key: WalletSyncService.tokenKey),
        'legacy-token');
    await TxDb.setSyncToken('');
    expect(await TxDb.syncToken(), '');
  });
  test(
      'secure write failure preserves legacy token but never saves a new plaintext token',
      () async {
    FlutterSecureStorage.setMockInitialValues(
        Map<String, String>.unmodifiable({}));
    await expectLater(TxDb.setSyncToken('new-secret'), throwsUnsupportedError);
    expect(await TxDb.setting(WalletSyncService.tokenKey), isNull);
    await TxDb.setSetting(WalletSyncService.tokenKey, 'legacy-preserved');
    await expectLater(TxDb.syncToken(), throwsUnsupportedError);
    expect(await TxDb.setting(WalletSyncService.tokenKey), 'legacy-preserved');
  });
}
