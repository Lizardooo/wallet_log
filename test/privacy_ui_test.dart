import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/main.dart';
import 'package:wallet_log/onboarding.dart';
import 'package:wallet_log/privacy_disclosures.dart';
import 'package:wallet_log/settings_screen.dart';
import 'package:wallet_log/tabs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  setUpAll(() async {
    databaseFactory = databaseFactoryFfi;
    if (Platform.environment['CAPTURE_PRIVACY'] == '1') {
      for (final font in {
        'PreviewArabic': '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
        'MaterialIcons':
            '/tmp/flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(font.key)
              ..addFont(
                  File(font.value).readAsBytes().then(ByteData.sublistView)))
            .load();
      }
    }
  });
  setUp(() async {
    await TxDb.close();
    dir = await Directory.systemTemp.createTemp('privacy-ui-');
    await databaseFactory.setDatabasesPath(dir.path);
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(smsChannel, null);
    await TxDb.close();
    await dir.delete(recursive: true);
  });
  Widget app(Widget home, {double scale = 1}) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF0F766E),
            fontFamily: Platform.environment['CAPTURE_PRIVACY'] == '1'
                ? 'PreviewArabic'
                : null),
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: home,
      );
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (Platform.environment['CAPTURE_PRIVACY'] == '1') {
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('visual/privacy-$name.png'));
    }
    expect(tester.takeException(), isNull);
  }

  for (final width in [320.0, 390.0]) {
    for (final type in ['sms', 'sim', 'sync']) {
      testWidgets(
          '$type disclosure is scrollable with accessible actions at $width',
          (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        bool? choice;
        await tester.pumpWidget(app(
            Builder(
                builder: (ctx) => Scaffold(
                        body: Center(
                      child: TextButton(
                          onPressed: () async {
                            choice = switch (type) {
                              'sms' => await showSmsDisclosure(ctx),
                              'sim' => await showSimDisclosure(ctx),
                              _ => await showSyncDisclosure(
                                  ctx,
                                  Uri.parse(
                                      'https://dashboard.example/api/wallets/sync'),
                                  includeMessageText: false),
                            };
                          },
                          child: const Text('open')),
                    ))),
            scale: width == 320 ? 1.3 : 1));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await capture(tester, '$type-${width.toInt()}');
        if (type != 'sim' && width == 320) {
          await tester.drag(
              find.byType(SingleChildScrollView).last, const Offset(0, -900));
          await tester.pumpAndSettle();
          await capture(tester, '$type-320-bottom');
        }
        final cancel = switch (type) {
          'sms' => 'بدون قراءة الرسائل',
          'sim' => 'إدخال يدوي',
          _ => 'إلغاء',
        };
        await tester.tap(find.text(cancel));
        await tester.pumpAndSettle();
        expect(choice, false);
      });
    }
  }
  testWidgets('declining SIM disclosure makes no phone permission call',
      (tester) async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(smsChannel, (_) async {
      calls++;
      return null;
    });
    await tester.pumpWidget(app(OnboardingPage(onDone: () async {})));
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, 0);
    await tester.tap(find.text('إدخال يدوي'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.byType(TextField), findsOneWidget);
  });
  testWidgets(
      'SMS system prompt waits for informed consent and decline keeps manual access',
      (tester) async {
    await tester
        .runAsync(() async => TxDb.setSetting(TxDb.settingsSetupDone, '1'));
    var smsCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(smsChannel, (call) async {
      if (call.method == 'requestPermission') {
        smsCalls++;
        return true;
      }
      if (call.method == 'readInbox') return <dynamic>[];
      if (call.method == 'getReminder') return null;
      return null;
    });
    await tester.pumpWidget(app(const HomePage()));
    await drain(tester);
    expect(find.text('قراءة رسائل المحافظ'), findsOneWidget);
    expect(smsCalls, 0);
    await tester.tap(find.text('بدون قراءة الرسائل'));
    await drain(tester);
    expect(smsCalls, 0);
    expect(
        await tester.runAsync(() => TxDb.setting(smsConsentKey)), 'declined');
    await tester.tap(find.text('متابعة بدون رسائل'));
    await drain(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.byTooltip('إعادة قراءة الرسائل'));
    await drain(tester);
    await tester.tap(find.text('أوافق وأتابع'));
    await drain(tester);
    expect(smsCalls, 1);
    expect(
        await tester.runAsync(() => TxDb.setting(smsConsentKey)), 'accepted');
    expect(tester.takeException(), isNull);
  });
  testWidgets('sync review cancel does not save credentials or submit',
      (tester) async {
    await tester.pumpWidget(app(SettingsScreen(onRestored: () async {})));
    await drain(tester);
    await tester.scrollUntilVisible(find.text('مراجعة وإرسال'), 350,
        scrollable: find.byType(Scrollable).first);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'https://dashboard.example');
    await tester.enterText(fields.at(1), 'test-token');
    await tester.tap(find.text('مراجعة وإرسال'));
    await drain(tester);
    expect(find.text('تأكيد إرسال بيانات المحافظ'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await drain(tester);
    expect(await tester.runAsync(() => TxDb.syncToken()), '');
    expect(await tester.runAsync(() => TxDb.setting('wallet_sync_endpoint')),
        isNull);
    expect(tester.takeException(), isNull);
  });
}
