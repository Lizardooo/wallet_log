import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/dashboard_tab.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/tx_detail_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 80; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump();
    }
  }

  Widget app(Widget home, String locale) => MaterialApp(
        locale: Locale(locale),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        builder: (c, child) => MediaQuery(
            data: MediaQuery.of(c)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!),
        home: home,
      );

  for (final width in [320.0, 390.0]) {
    for (final locale in ['ar', 'en']) {
      testWidgets(
          'dashboard separates confirmed and pending at $width in $locale',
          (tester) async {
        tester.view.physicalSize = Size(width, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Directory dir;
        late int confirmed, pendingIn, reversed;
        await tester.runAsync(() async {
          await TxDb.close();
          dir = await Directory.systemTemp.createTemp('dash-ui-');
          await databaseFactory.setDatabasesPath(dir.path);
          final ws = await TxDb.wallets();
          final w = await ws.addWallet(
              providerId: await ws.providerId('vodafone_cash'),
              phone: '01011111111',
              nickname: 'Main',
              openingMinor: 100000);
          final led = await TxDb.ledger();
          final now = DateTime.now().millisecondsSinceEpoch;
          confirmed = await led.createManual(
              walletAccountId: w,
              amountMinor: 25000,
              dir: 'in',
              type: 'transfer',
              ts: now - 2000);
          await (await TxDb.confirmations())
              .confirmByProvider(confirmed, reason: 'saw it');
          pendingIn = await led.createManual(
              walletAccountId: w,
              amountMinor: 77700,
              dir: 'in',
              type: 'transfer',
              ts: now - 1000);
          final r = await led.createManual(
              walletAccountId: w,
              amountMinor: 1000,
              dir: 'out',
              type: 'topup',
              ts: now - 500);
          await (await TxDb.confirmations()).confirmByProvider(r, reason: 'ok');
          reversed = await led.reverse(r, reason: 'failed recharge');
        });
        addTearDown(() => tester.runAsync(() async {
              await TxDb.close();
              await dir.delete(recursive: true);
            }));
        await tester
            .pumpWidget(app(const Scaffold(body: DashboardTab()), locale));
        await settle(tester);
        expect(tester.takeException(), isNull);
        // confirmed balance = opening 1,000.00 + 250.00 (the pending 777.00 is NOT in it)
        expect(find.textContaining('1,250.00'), findsWidgets);
        expect(find.text('777.00'), findsWidgets); // shown as pending
        expect(find.textContaining('2,027.00'), findsNothing); // never mixed
        expect(
            find.textContaining('Pending').evaluate().isNotEmpty ||
                find.textContaining('معلّق').evaluate().isNotEmpty,
            isTrue);
        expect(pendingIn, isNonZero);
        expect(reversed, isNonZero);
      });
    }
  }

  testWidgets('transaction detail: manual, awaiting, reversal card, actions',
      (tester) async {
    tester.view.physicalSize = const Size(360, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory dir;
    late int orig, manualId;
    await tester.runAsync(() async {
      await TxDb.close();
      dir = await Directory.systemTemp.createTemp('detail-ui-');
      // path_provider has no platform side in tests: point it at the temp dir.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => dir.path);
      await databaseFactory.setDatabasesPath(dir.path);
      final ws = await TxDb.wallets();
      final w = await ws.addWallet(
          providerId: await ws.providerId('vodafone_cash'),
          phone: '01011111111');
      final led = await TxDb.ledger();
      manualId = await led.createManual(
          walletAccountId: w,
          amountMinor: 50000,
          dir: 'in',
          type: 'transfer',
          ts: 1000,
          counterparty: '01099999999');
      orig = await led.createManual(
          walletAccountId: w,
          amountMinor: 10000,
          dir: 'out',
          type: 'bill',
          feeMinor: 200,
          ts: 2000);
      await led.reverse(orig, reason: 'paid twice');
    });
    addTearDown(() => tester.runAsync(() async {
          await TxDb.close();
          await dir.delete(recursive: true);
        }));

    await tester.pumpWidget(app(TxDetailScreen(txId: manualId), 'en'));
    await settle(tester);
    expect(find.text('Awaiting confirmation'), findsOneWidget);
    expect(find.textContaining('not independently verified'), findsOneWidget);
    expect(find.textContaining('Confirm (checked wallet)'), findsOneWidget);
    expect(find.text('No evidence yet. You can add it now or later.'),
        findsOneWidget);

    await tester
        .pumpWidget(app(TxDetailScreen(key: ValueKey(orig), txId: orig), 'en'));
    await settle(tester);
    expect(find.text('Reversed'), findsWidgets);
    expect(find.textContaining('Reversed transaction'), findsOneWidget);
    expect(find.textContaining('Net wallet impact: 0.00'), findsOneWidget);
    expect(find.textContaining('Counted as neither spending nor income'),
        findsOneWidget);
    expect(find.text('Reverse'),
        findsNothing); // a reversed record offers no more actions
  });
}
