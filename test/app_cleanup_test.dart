import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/guide_screen.dart';
import 'package:wallet_log/logic.dart';
import 'package:wallet_log/main.dart';
import 'package:wallet_log/onboarding.dart';
import 'package:wallet_log/phone_numbers.dart';
import 'package:wallet_log/tabs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);

  group('phone numbers', () {
    test('what the phone reports is cleaned to 01xxxxxxxxx', () {
      expect(normalizeEgyptPhone('+20 101 234 5678'), '01012345678');
      expect(normalizeEgyptPhone('00201112345678'), '01112345678');
      expect(normalizeEgyptPhone('201212345678'), '01212345678');
      expect(normalizeEgyptPhone('1512345678'), '01512345678');
      expect(normalizeEgyptPhone('٠١٠١٢٣٤٥٦٧٨'), '01012345678');
      expect(normalizeEgyptPhone(''), '');
    });

    test('typed numbers are checked in plain Arabic', () {
      expect(phoneProblem('01012345678'), isNull);
      expect(phoneProblem(''), isNotNull);
      expect(phoneProblem('0101234'), contains('11 رقم'));
      expect(phoneProblem('01312345678'), contains('010'));
    });

    test('the carrier hints the prefix', () {
      expect(carrierPrefix('Vodafone EG'), '010');
      expect(carrierPrefix('Etisalat'), '011');
      expect(carrierPrefix('Orange EG'), '012');
      expect(carrierPrefix('WE'), '015');
      expect(carrierPrefix(''), isNull);
    });
  });

  late Directory dir;
  Future<void> openDb(WidgetTester tester) async {
    await tester.runAsync(() async {
      await TxDb.close();
      dir = await Directory.systemTemp.createTemp('wallet-cleanup-');
      await databaseFactory.setDatabasesPath(dir.path);
    });
    addTearDown(() async {
      await TxDb.close();
      await dir.delete(recursive: true);
    });
  }

  void mockChannel(WidgetTester tester, {List<dynamic> sims = const []}) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(smsChannel,
        (call) async {
      switch (call.method) {
        case 'requestPermission':
        case 'requestPhoneState':
          return true;
        case 'readInbox':
          return <dynamic>[];
        case 'simInfo':
          return sims;
        case 'getReminder':
          return null;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(smsChannel, null));
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  /// Unmounts the app and lets pending loads finish before the db closes.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  }

  testWidgets('home is the first tab, on the right in Arabic', (tester) async {
    await openDb(tester);
    mockChannel(tester);
    await tester.runAsync(() => TxDb.setSetting(TxDb.settingsSetupDone, '1'));
    await tester.pumpWidget(const WalletLogApp());
    await settle(tester);

    final labels = [
      'الرئيسية',
      'المعاملات',
      'المراجعة',
      'التقارير',
      'الإعدادات'
    ];
    final xs = [
      for (final l in labels)
        tester
            .getCenter(find.descendant(
                of: find.byType(NavigationBar), matching: find.text(l)))
            .dx
    ];
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i], lessThan(xs[i - 1]),
          reason: '${labels[i]} is left of '
              '${labels[i - 1]}');
    }
    expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        0);
    // No wallets yet: home says so and points to the fix.
    expect(find.byKey(const ValueKey('notice-no-accounts')), findsOneWidget);
    expect(find.byKey(const ValueKey('notice-guide')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('a wallet without a number is flagged until it is typed',
      (tester) async {
    await openDb(tester);
    mockChannel(tester);
    await tester.runAsync(() async {
      await TxDb.setSetting(TxDb.settingsSetupDone, '1');
      await TxDb.saveAccount(const Account(
          name: 'فودافون كاش · شريحة 1',
          wallet: 'Vodafone Cash',
          number: '',
          subId: 3,
          slot: 0));
      // Today's opening is known, so no opening dialog covers the screen.
      final id = (await TxDb.accounts()).single.id!;
      await TxDb.setOpening(id, dayKey(DateTime.now()), 0);
    });
    await tester.pumpWidget(const WalletLogApp());
    await settle(tester);
    expect(find.byKey(const ValueKey('notice-missing-number')), findsOneWidget);

    // Settings tab -> the guide opens with every step.
    await tester.tap(find.text('الإعدادات'));
    await tester.pumpAndSettle();
    expect(find.textContaining('رقم مش مكتوب'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('more-guide')));
    await tester.pumpAndSettle();
    expect(find.byType(GuideScreen), findsOneWidget);
    expect(
        find.byKey(ValueKey('guide-${guideSteps.first.id}')), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('setup asks for the number when the phone cannot read it',
      (tester) async {
    await openDb(tester);
    mockChannel(tester, sims: [
      {'subId': 3, 'slot': 0, 'carrier': 'Vodafone', 'number': null},
      {'subId': 4, 'slot': 1, 'carrier': 'Orange', 'number': '+201212345678'},
    ]);
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: OnboardingPage(onDone: () async {}),
      ),
    ));
    await settle(tester);

    // The second SIM's number was read and cleaned; the first was not.
    expect(find.text('01212345678'), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-missing-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-missing-1')), findsNothing);

    // Tick the first SIM: Vodafone Cash is suggested from the carrier.
    await tester.tap(find.text('الرقم عليه محفظة / محفظة إلكترونية').first);
    await tester.pump();
    await tester.tap(find.text('التالي'));
    await tester.pump();
    expect(find.textContaining('ما قالناش رقم شريحة 1'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '0101234');
    await tester.pump();
    expect(find.textContaining('11 رقم'), findsWidgets);
    await tester.enterText(find.byType(TextField).first, '01012345678');
    await tester.pump();
    await tester.tap(find.text('التالي'));
    await tester.pumpAndSettle();
    expect(find.textContaining('الذكاء الاصطناعي'), findsWidgets);
  });

  testWidgets('the account editor refuses a wrong number', (tester) async {
    Account? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              saved = await editAccount(context, null, const []),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ'));
    await tester.pump();
    expect(find.text('اكتب الرقم'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('account-number')), '+20 100 000 0000');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(saved?.number, '01000000000');
    expect(saved?.name, contains('01000000000'));
  });
}
