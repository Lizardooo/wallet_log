import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/onboarding.dart';
import 'package:wallet_log/sim_setup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('wallet_log/sms');
  List<Map<String, Object?>> sims = [];
  bool granted = true;

  setUpAll(() async {
    if (Platform.environment['CAPTURE_UI'] == '1') {
      final text = FontLoader('PreviewArabic')
        ..addFont(Future.value(ByteData.sublistView(
            await File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')
                .readAsBytes())));
      final icons = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(await File(
                '/tmp/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
            .readAsBytes())));
      await text.load();
      await icons.load();
    }
  });
  setUp(() {
    granted = true;
    sims = [
      {
        'subId': 11,
        'slot': 0,
        'carrier': 'Vodafone',
        'number': '+20 1011111111'
      },
      {'subId': 22, 'slot': 1, 'carrier': 'Orange', 'number': ''},
      {'subId': 33, 'slot': 2, 'carrier': 'eSIM', 'number': ''},
    ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'requestPhoneState') return granted;
      if (call.method == 'simInfo') return sims;
      throw MissingPluginException();
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget app() => MaterialApp(
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
        home: OnboardingPage(onDone: () async {}),
      );

  test('SIM number normalization is conservative', () {
    expect(normalizeSimNumber('+20 1011111111'), '01011111111');
    expect(normalizeSimNumber('٠١٢١١١١١١١١'), '01211111111');
    expect(normalizeSimNumber('00201011111111'), '01011111111');
    expect(normalizeSimNumber('+968 9000 0000'), '+96890000000');
    expect(normalizeSimNumber('unknown'), '');
    expect(normalizeSimNumber('123'), '');
  });

  testWidgets(
      'all reported SIMs remain reachable and missing numbers are manual',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('السماح بالاكتشاف'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '01011111111'), findsOneWidget);
    expect(find.text('شريحة 1'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('شريحة 3'), 220,
        scrollable: find
            .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable))
            .first);
    expect(find.text('شريحة 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permission denial shows one manual number, not fictitious SIMs',
      (tester) async {
    granted = false;
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('السماح بالاكتشاف'));
    await tester.pumpAndSettle();
    expect(find.text('رقم إضافي'), findsOneWidget);
    expect(find.text('شريحة 2'), findsOneWidget); // slot choice only
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('إضافة رقم آخر'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual number required even if subscription was detected',
      (tester) async {
    sims = [
      {'subId': 22, 'slot': 1, 'carrier': 'Orange', 'number': ''}
    ];
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('السماح بالاكتشاف'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الرقم عليه محفظة / محفظة إلكترونية'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'أورنج كاش'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();
    expect(find.text('اكتب رقم المحفظة للرقم اللي اخترته.'), findsOneWidget);
  });

  testWidgets('multi-SIM layout scrolls at narrow phone width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('السماح بالاكتشاف'));
    await tester.pumpAndSettle();
    if (Platform.environment['CAPTURE_UI'] == '1') {
      await expectLater(find.byType(OnboardingPage),
          matchesGoldenFile('visual/multi-sim-top.png'));
    }
    await tester.scrollUntilVisible(find.text('شريحة 3'), 180,
        scrollable: find
            .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable))
            .first);
    await tester.pumpAndSettle();
    expect(find.text('شريحة 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (Platform.environment['CAPTURE_UI'] == '1') {
      await expectLater(find.byType(OnboardingPage),
          matchesGoldenFile('visual/multi-sim-scrolled.png'));
    }
  });

  testWidgets('RTL onboarding at phone size has visible default wallet control',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    sims = [
      {'subId': 11, 'slot': 0, 'carrier': 'Vodafone', 'number': '+201011111111'}
    ];
    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('السماح بالاكتشاف'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الرقم عليه محفظة / محفظة إلكترونية'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'فودافون كاش'));
    await tester.pumpAndSettle();
    expect(find.text('المحفظة الافتراضية لهذا الرقم'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (Platform.environment['CAPTURE_UI'] == '1') {
      await expectLater(find.byType(OnboardingPage),
          matchesGoldenFile('visual/onboarding-phone.png'));
    }
  });
}
