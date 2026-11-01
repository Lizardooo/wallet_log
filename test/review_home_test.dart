import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/main.dart';
import 'package:wallet_log/review_tab.dart';
import 'package:wallet_log/tabs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() async {
    databaseFactory = databaseFactoryFfi;
    for (final entry in {
      'ReviewTest': Platform.environment['REVIEW_TEST_FONT'],
      'ReviewLatin': Platform.environment['REVIEW_TEST_LATIN_FONT'],
      'MaterialIcons': Platform.environment['REVIEW_ICON_FONT'],
    }.entries) {
      if (entry.value == null) continue;
      final loader = FontLoader(entry.key);
      loader
          .addFont(File(entry.value!).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  for (final locale in ['ar', 'en']) {
    testWidgets('home exposes review safely at 320px in $locale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = await tester
          .runAsync(() => Directory.systemTemp.createTemp('review-home-'));
      await tester.runAsync(() async {
        await TxDb.close();
        await databaseFactory.setDatabasesPath(dir!.path);
        await TxDb.setSetting(TxDb.settingsSetupDone, '1');
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(smsChannel,
          (call) async {
        if (call.method == 'requestPermission') return true;
        if (call.method == 'readInbox') return <dynamic>[];
        if (call.method == 'getReminder') return null;
        throw PlatformException(code: 'unexpected', message: call.method);
      });
      addTearDown(() async {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(smsChannel, null);
        await TxDb.close();
        await dir!.delete(recursive: true);
      });
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(
            fontFamily: Platform.environment['REVIEW_TEST_FONT'] == null
                ? null
                : 'ReviewTest',
            fontFamilyFallback: const ['ReviewLatin']),
        locale: Locale(locale),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!),
        home: const RepaintBoundary(
            key: ValueKey('review-preview'), child: HomePage()),
      ));
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      final destination = find.byType(NavigationDestination).last;
      await tester.tap(destination);
      await tester.pumpAndSettle();
      expect(find.byType(ReviewTab), findsOneWidget);
      expect(
          tester
              .widget<IconButton>(find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == 'تصدير تقرير Excel'))
              .onPressed,
          isNull);
      expect(tester.takeException(), isNull);
      final screenshotDir = Platform.environment['REVIEW_SCREENSHOTS'];
      if (screenshotDir != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('review-preview')));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$screenshotDir/review-home-$locale.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .selectedIndex,
          5);
    });
  }
}
