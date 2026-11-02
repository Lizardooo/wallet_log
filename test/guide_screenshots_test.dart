// Makes the screenshots of the in-app guide (assets/guide/*.png) from the real
// screens, filled with made-up sample messages, and draws a numbered red ring
// around each place the guide's matching step tells the owner to tap.
//
// It only runs on request:
//   GUIDE_SCREENSHOTS=assets/guide \
//   GUIDE_FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf \
//   GUIDE_ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf \
//   flutter test test/guide_screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wallet_log/db.dart';
import 'package:wallet_log/logic.dart';
import 'package:wallet_log/main.dart';
import 'package:wallet_log/onboarding.dart';
import 'package:wallet_log/tabs.dart';

final _out = Platform.environment['GUIDE_SCREENSHOTS'];
const _boundary = ValueKey('guide-shot');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUpAll(() async {
    databaseFactory = databaseFactoryFfi;
    for (final e in {
      'GuideFont': Platform.environment['GUIDE_FONT'],
      'MaterialIcons': Platform.environment['GUIDE_ICON_FONT'],
    }.entries) {
      if (e.value == null) continue;
      final loader = FontLoader(e.key)
        ..addFont(File(e.value!).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  Widget app(Widget home) => MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF0F766E),
          useMaterial3: true,
          fontFamily: 'GuideFont',
        ),
        home: RepaintBoundary(key: _boundary, child: home),
      );

  Future<void> settle(WidgetTester t, [int rounds = 15]) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump();
    }
    await t.pump(const Duration(seconds: 1));
  }

  /// Saves the screen with numbered rings around [marks] (number -> widget).
  Future<void> shot(WidgetTester t, String id, Map<int, Finder> marks) async {
    final box = t.renderObject<RenderRepaintBoundary>(find.byKey(_boundary));
    final origin = t.getTopLeft(find.byKey(_boundary));
    final rects = {
      for (final e in marks.entries)
        e.key: t.getRect(e.value.first).shift(-origin),
    };
    const ratio = 1.5;
    await t.runAsync(() async {
      final image = await box.toImage(pixelRatio: ratio);
      final rec = ui.PictureRecorder();
      final c = Canvas(rec);
      c.drawImage(image, Offset.zero, Paint());
      c.scale(ratio);
      const red = Color(0xFFE53935);
      for (final e in rects.entries) {
        final r = e.value.inflate(4);
        c.drawRRect(
            RRect.fromRectAndRadius(r, const Radius.circular(10)),
            Paint()
              ..color = red
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3);
        // Keep the number badge inside the picture.
        final center = Offset(
            (r.right - 2).clamp(14.0, image.width / ratio - 14),
            (r.top + 2).clamp(14.0, image.height / ratio - 14));
        c.drawCircle(center, 12, Paint()..color = red);
        c.drawCircle(
            center,
            12,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2);
        final pb = ui.ParagraphBuilder(ui.ParagraphStyle(
            textAlign: TextAlign.center, fontFamily: 'GuideFont'))
          ..pushStyle(ui.TextStyle(
              color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold))
          ..addText('${e.key}');
        final p = pb.build()..layout(const ui.ParagraphConstraints(width: 24));
        c.drawParagraph(p, center - Offset(12, p.height / 2));
      }
      final out = await rec.endRecording().toImage(image.width, image.height);
      final png = await out.toByteData(format: ui.ImageByteFormat.png);
      await File('$_out/$id.png').writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
      out.dispose();
    });
  }

  void phone(WidgetTester t) {
    t.view.physicalSize = const Size(360, 800);
    // Tests draw shadows as black outlines unless told otherwise; the test
    // body puts it back before it ends.
    debugDisableShadows = false;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
  }

  void channel(WidgetTester t, {List<dynamic> sims = const []}) {
    final today = DateTime.now();
    int at(int h, int m) => DateTime(today.year, today.month, today.day, h, m)
        .millisecondsSinceEpoch;
    // Made-up messages and numbers, only for the pictures.
    final inbox = [
      (
        'VF-Cash',
        'تم استلام 1500 جنيه من 01099999999. رصيدك الحالي 3500 جنيه',
        at(9, 15)
      ),
      (
        'VF-Cash',
        'تم تحويل 200 جنيه الى 01112345678 بنجاح. رصيدك الحالي 3300 جنيه',
        at(11, 40)
      ),
      (
        'VF-Cash',
        'تم ايداع 2000 جنيه في محفظتك. رصيدك الحالي 5300 جنيه',
        at(13, 5)
      ),
      (
        'InstaPay',
        'تم تحويل ٥٠٠ جنيه إلى 01112345678. رصيدك الحالي ٢٠٠٠ جنيه',
        at(14, 30)
      ),
      (
        'VF-Cash',
        'تم دفع فاتورة الكهرباء بمبلغ 320.75 جنيه ورسوم 5 جنيه. رصيدك الحالي 4974.25 جنيه',
        at(16, 10)
      ),
    ];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(smsChannel,
        (call) async {
      switch (call.method) {
        case 'requestPermission':
        case 'requestPhoneState':
          return true;
        case 'simInfo':
          return sims;
        case 'readInbox':
          return [
            for (final (a, b, d) in inbox)
              {'address': a, 'body': b, 'date': d, 'subId': 3},
          ];
        case 'getReminder':
          return null;
      }
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(smsChannel, null));
  }

  Future<void> freshDb(WidgetTester t) async {
    final dir = (await t
        .runAsync(() => Directory.systemTemp.createTemp('wallet-guide-')))!;
    await t.runAsync(() async {
      await TxDb.close();
      await databaseFactory.setDatabasesPath(dir.path);
    });
    addTearDown(() async {
      await TxDb.close();
      await dir.delete(recursive: true);
    });
  }

  final skip = _out == null ? 'set GUIDE_SCREENSHOTS to make them' : null;

  testWidgets('setup screens', skip: skip != null, (t) async {
    phone(t);
    await freshDb(t);
    channel(t, sims: [
      {'subId': 3, 'slot': 0, 'carrier': 'Vodafone', 'number': '+201012345678'},
      {'subId': 4, 'slot': 1, 'carrier': 'Orange', 'number': null},
    ]);
    await t.pumpWidget(app(OnboardingPage(onDone: () async {})));
    await settle(t);
    final tick = find.text('الرقم عليه محفظة / محفظة إلكترونية');
    await t.tap(tick.first);
    await settle(t, 3);
    await shot(t, 'setup', {
      2: tick.first,
      3: find.byType(FilterChip).first,
      4: find.byType(TextField).first,
    });

    await t.scrollUntilVisible(find.byKey(const ValueKey('sim-missing-1')), 200,
        scrollable: find.byType(Scrollable).first);
    await t.tap(tick.at(1));
    await settle(t, 3);
    await t.scrollUntilVisible(find.byType(TextField).at(1), 100,
        scrollable: find.byType(Scrollable).first);
    await settle(t, 3);
    await shot(t, 'number', {
      1: find.byKey(const ValueKey('sim-missing-1')),
      2: find.byType(TextField).at(1),
      3: find.text('التالي'),
    });
    await t.pumpWidget(const SizedBox());
    await settle(t, 3);
    debugDisableShadows = true;
  });

  testWidgets('main screens', skip: skip != null, (t) async {
    phone(t);
    await freshDb(t);
    channel(t);
    await t.runAsync(() async {
      await TxDb.setSetting(TxDb.settingsSetupDone, '1');
      for (final w in ['Vodafone Cash', 'InstaPay']) {
        await TxDb.saveAccount(Account(
            name: w == 'InstaPay'
                ? 'إنستاباي · 01012345678'
                : 'فودافون كاش · 01012345678',
            wallet: w,
            number: '01012345678',
            subId: 3,
            slot: 0));
      }
      for (final a in await TxDb.accounts()) {
        await TxDb.setOpening(a.id!, dayKey(DateTime.now()), 2000);
      }
    });
    await t.pumpWidget(app(const HomePage()));
    await settle(t, 30);
    Finder nav(String label) => find.descendant(
        of: find.byType(NavigationBar), matching: find.text(label));

    await shot(t, 'home', {
      1: find.text('مؤكد'),
      2: find.textContaining('معلّق (غير مؤكد').first,
      3: find.byKey(const ValueKey('refresh')),
    });

    await t.tap(nav('المعاملات'));
    await settle(t, 5);
    await shot(t, 'transactions', {
      1: find.text('01099999999'),
      2: find.byTooltip('بحث'),
    });

    await t.tap(nav('المراجعة'));
    await settle(t, 5);
    await shot(t, 'review', {1: nav('المراجعة')});

    await t.tap(nav('التقارير'));
    await settle(t, 5);
    await shot(t, 'reports', {
      1: find.byType(ChoiceChip).first,
      2: find.text('إجمالي الداخل').first,
      3: find.text('استيراد تقرير Excel (.xlsx)'),
    });

    await t.tap(nav('الإعدادات'));
    await settle(t, 5);
    await shot(t, 'settings', {
      1: find.text('محافظي وأرقامي'),
      2: find.text('رصيد اليوم والمتبقي'),
      3: find.text('النسخة الاحتياطية'),
    });
    await t.pumpWidget(const SizedBox());
    await settle(t, 5);
    debugDisableShadows = true;
  });
}
