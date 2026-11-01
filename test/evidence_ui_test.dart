import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/evidence_section.dart';
import 'package:wallet_log/evidence_service.dart';

// 1x1 transparent PNG
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);

  for (final locale in ['en', 'ar']) {
    testWidgets(
        'evidence section: list, viewer, add, hide, integrity ($locale)',
        (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory dir;
      late EvidenceService svc;
      late int tx;
      late File extra;
      await tester.runAsync(() async {
        await TxDb.close();
        dir = await Directory.systemTemp.createTemp('evidence-ui-');
        await databaseFactory.setDatabasesPath(dir.path);
        final ws = await TxDb.wallets();
        final w = await ws.addWallet(
            providerId: await ws.providerId('vodafone_cash'),
            phone: '01011111111');
        final led = await TxDb.ledger();
        tx = await led.createManual(
            walletAccountId: w,
            amountMinor: 50000,
            dir: 'in',
            type: 'transfer',
            ts: 1000);
        svc = EvidenceService(ws.db, Directory(p.join(dir.path, 'private')));
        final a = File(p.join(dir.path, 'sender.png'))..writeAsBytesSync(_png);
        await svc.attachFile(tx, a,
            kind: EvidenceKind.walletApp,
            origin: EvidenceOrigin.senderWalletApp,
            uploadedBy: UploadedBy.owner,
            note: 'sent by Ali');
        await svc.attachSms(tx,
            sender: 'VF-Cash', body: 'You have received 500.00 EGP', ts: 2000);
        extra = File(p.join(dir.path, 'receipt.png'))
          ..writeAsBytesSync([..._png, 0]);
      });
      addTearDown(() => tester.runAsync(() async {
            await TxDb.close();
            await dir.delete(recursive: true);
          }));

      await tester.pumpWidget(MaterialApp(
        locale: Locale(locale),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        home: Scaffold(
            body: SingleChildScrollView(
                child: EvidenceSection(
                    service: svc, txId: tx, pick: () async => extra))),
      ));
      Future<void> settle() async {
        for (var i = 0; i < 25; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
          await tester.pump();
        }
      }

      await settle();
      // SMS evidence is shown apart from the uploaded file.
      expect(
          find.textContaining('You have received 500.00 EGP'), findsOneWidget);
      expect(find.text('sender.png'), findsOneWidget);
      // origin and uploader are two separate facts
      expect(
          find.textContaining(originLabel(
              tester.element(find.text('sender.png')),
              EvidenceOrigin.senderWalletApp)),
          findsOneWidget);
      expect(
          find.textContaining(uploaderLabel(
              tester.element(find.text('sender.png')), UploadedBy.owner)),
          findsWidgets);
      expect(find.textContaining('sent by Ali'), findsOneWidget);
      final id = (await tester.runAsync(() => svc.list(tx)))!
          .firstWhere((e) => e['file_path'] != null)['id'];
      expect(tester.widget<Icon>(find.byKey(ValueKey('integrity-$id'))).icon,
          Icons.verified_outlined);

      // full-screen viewer
      await tester.tap(find.byKey(ValueKey('evidence-$id')));
      await tester.pumpAndSettle();
      expect(find.byType(EvidenceViewer), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      Navigator.of(tester.element(find.byType(EvidenceViewer))).pop();
      await tester.pumpAndSettle();

      // add more evidence after creation
      await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      await settle();
      expect(find.text('receipt.png'), findsOneWidget);
      expect((await tester.runAsync(() => svc.list(tx)))!.length, 3);
      // adding evidence never changes the confirmation
      final status = await tester.runAsync(() async =>
          (await (await TxDb.database())
                  .query('tx', where: 'id = ?', whereArgs: [tx]))
              .first['confirmation']);
      expect(status, 'awaiting');

      // hide with a reason: gone from the list, still stored and listed as hidden
      await tester.tap(find.byIcon(Icons.visibility_off_outlined).first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'wrong image');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      await settle();
      expect((await tester.runAsync(() => svc.list(tx)))!.length, 2);
      expect(
          (await tester.runAsync(() => svc.list(tx, includeRemoved: true)))!
              .length,
          3);
      expect(find.textContaining('(1)'), findsOneWidget);
      await tester.tap(find.textContaining('(1)'));
      await tester.pump();
      expect(find.textContaining('wrong image'), findsOneWidget);
    });
  }

  testWidgets('altered file is flagged', (tester) async {
    late Directory dir;
    late EvidenceService svc;
    late int tx, id;
    await tester.runAsync(() async {
      await TxDb.close();
      dir = await Directory.systemTemp.createTemp('evidence-ui2-');
      await databaseFactory.setDatabasesPath(dir.path);
      final ws = await TxDb.wallets();
      final w = await ws.addWallet(
          providerId: await ws.providerId('vodafone_cash'),
          phone: '01011111111');
      tx = await (await TxDb.ledger()).createManual(
          walletAccountId: w,
          amountMinor: 100,
          dir: 'out',
          type: 'transfer',
          ts: 1);
      svc = EvidenceService(ws.db, Directory(p.join(dir.path, 'private')));
      final f = File(p.join(dir.path, 'a.png'))..writeAsBytesSync(_png);
      id = await svc.attachFile(tx, f);
      svc.fileOf((await svc.list(tx)).single)!.writeAsBytesSync([1, 2, 3]);
    });
    addTearDown(() => tester.runAsync(() async {
          await TxDb.close();
          await dir.delete(recursive: true);
        }));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: EvidenceSection(service: svc, txId: tx)))));
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(tester.widget<Icon>(find.byKey(ValueKey('integrity-$id'))).icon,
        Icons.error_outline);
  });
}
