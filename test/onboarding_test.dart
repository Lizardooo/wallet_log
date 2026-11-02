import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/onboarding.dart';
import 'package:wallet_log/tabs.dart';

void main() {
  test('Egyptian mobile numbers are normalised and validated', () {
    expect(normalizeEgyptMobile('01012345678'), '01012345678');
    expect(normalizeEgyptMobile('+201112345678'), '01112345678');
    expect(normalizeEgyptMobile('00201212345678'), '01212345678');
    expect(normalizeEgyptMobile('201512345678'), '01512345678');
    expect(normalizeEgyptMobile('1012345678'), '01012345678');
    expect(normalizeEgyptMobile('٠١٠ ١٢٣٤ ٥٦٧٨'), '01012345678');
    expect(normalizeEgyptMobile('0101234567'), isNull);
    expect(normalizeEgyptMobile('01312345678'), isNull);
    expect(normalizeEgyptMobile(''), isNull);
  });

  test('wallet is guessed from the carrier, then the number prefix', () {
    expect(walletForSim('', 'Vodafone EG'), 'Vodafone Cash');
    expect(walletForSim('', 'Orange EG'), 'Orange Cash');
    expect(walletForSim('', 'etisalat'), 'Etisalat Cash / Fawry');
    expect(walletForSim('', 'WE'), 'WE Pay');
    expect(walletForSim('01212345678', ''), 'Orange Cash');
    expect(walletForSim('01512345678', ''), 'WE Pay');
    expect(walletForSim('', ''), isNull);
  });

  Future<void> clearSnack(WidgetTester tester) async {
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();
  }

  Future<void> pumpSetup(WidgetTester tester, List<Map<String, Object?>> sims,
      {bool granted = true}) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(smsChannel,
        (call) async {
      switch (call.method) {
        case 'requestPhoneState':
          return granted;
        case 'simInfo':
          return sims;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(smsChannel, null));
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: OnboardingPage(onDone: () async {}),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('two detected SIMs: number read on one, asked on the other',
      (tester) async {
    await pumpSetup(tester, [
      {'subId': 3, 'slot': 0, 'carrier': 'Vodafone', 'number': '+201012345678'},
      {'subId': 4, 'slot': 1, 'carrier': 'Orange', 'number': null},
    ]);
    expect(find.textContaining('تم اكتشاف 2 شرائح'), findsOneWidget);
    // Both SIMs are pre-selected, the read number is filled in.
    expect(find.text('01012345678'), findsOneWidget);
    expect(find.text('تم اكتشاف الرقم تلقائياً، عدّله لو مش صحيح'),
        findsOneWidget);
    expect(
        find.text('الهاتف لم يُظهر رقم الشريحة، اكتبه يدوياً'), findsOneWidget);
    // The SIM step cannot be skipped.
    expect(find.text('تخطي'), findsNothing);

    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();
    expect(find.textContaining('شريحة 2 · Orange'), findsWidgets);
    expect(find.text('الذكاء الاصطناعي'), findsNothing);

    await clearSnack(tester);
    await tester.enterText(find.byType(TextField).at(1), '01212345678');
    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();
    expect(find.textContaining('الذكاء الاصطناعي'), findsWidgets);
  });

  testWidgets('one SIM chosen out of two only shows that SIM', (tester) async {
    await pumpSetup(tester, [
      {'subId': 3, 'slot': 0, 'carrier': 'Vodafone', 'number': '01012345678'},
      {'subId': 4, 'slot': 1, 'carrier': 'Orange', 'number': '01212345678'},
    ]);
    await tester.tap(find.text('شريحة واحدة'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('أي شريحة عليها المحفظة؟'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'شريحة 2 · Orange'));
    await tester.pumpAndSettle();
    expect(find.text('01212345678'), findsOneWidget);
    expect(find.text('01012345678'), findsNothing);
  });

  testWidgets('no permission: manual entry is required', (tester) async {
    await pumpSetup(tester, const [], granted: false);
    expect(find.textContaining('لم يتم السماح بقراءة الشرائح'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();
    expect(find.textContaining('رقم غير صحيح'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '01112345678');
    await tester.pumpAndSettle();
    // Prefix 011 pre-selects Etisalat Cash.
    final chip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'اتصالات كاش / فوري'));
    expect(chip.selected, isTrue);
    await clearSnack(tester);
    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();
    expect(find.textContaining('الذكاء الاصطناعي'), findsWidgets);
  });
}
