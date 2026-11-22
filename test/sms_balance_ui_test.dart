import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/opening_dialog.dart';
import 'package:wallet_log/wallet_sms_balance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (Platform.environment['CAPTURE_UI'] == '1') {
      for (final entry in {
        'PreviewArabic': '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
        'MaterialIcons':
            '/tmp/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final loader = FontLoader(entry.key)
          ..addFont(Future.value(
              ByteData.sublistView(await File(entry.value).readAsBytes())));
        await loader.load();
      }
    }
  });
  const account = Account(
      id: 1,
      name: 'فودافون كاش',
      wallet: 'Vodafone Cash',
      number: '01011111111',
      subId: 11);
  final time = DateTime(2026, 11, 22, 12).millisecondsSinceEpoch;
  final prior = DateTime(2026, 11, 21, 23, 30).millisecondsSinceEpoch;

  for (final hasPrior in [true, false]) {
    testWidgets('opening remains separate from latest SMS, prior=$hasPrior',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Map<int, double>? saved;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            colorSchemeSeed: const Color(0xFF0F766E),
            fontFamily: Platform.environment['CAPTURE_UI'] == '1'
                ? 'PreviewArabic'
                : null,
            useMaterial3: true),
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
            body: Builder(
                builder: (ctx) => TextButton(
                    onPressed: () async {
                      saved = await showSmsOpeningDialog(ctx, '2026-11-22', [
                        account
                      ], {
                        1: hasPrior ? 100.0 : null
                      }, latestSms: {
                        1: SmsWalletBalance(
                            1, account.wallet, account.number, 29590, time)
                      }, openingSms: {
                        if (hasPrior)
                          1: SmsWalletBalance(
                              1, account.wallet, account.number, 10000, prior)
                      });
                    },
                    child: const Text('open')))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('295.90 EGP'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, hasPrior ? '100.00' : '');
      expect(tester.takeException(), isNull);
      if (Platform.environment['CAPTURE_UI'] == '1') {
        await expectLater(
            find.byType(AlertDialog),
            matchesGoldenFile(
                'visual/opening-${hasPrior ? 'known' : 'unknown'}.png'));
      }
      await tester.tap(find.text('حفظ'));
      await tester.pumpAndSettle();
      expect(saved, hasPrior ? {1: 100.0} : <int, double>{});
    });
  }
}
