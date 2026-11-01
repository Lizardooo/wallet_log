import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'db.dart';
import 'logic.dart';
import 'parser.dart';

TextCellValue _t(String s) => TextCellValue(s);

/// Builds the report workbook: every transaction, a daily summary and a
/// summary per wallet number. Column names match what the importer reads, so
/// an exported file can be imported back.
List<int>? buildReportXlsx(List<Tx> txs, List<Account> accounts) {
  final excel = Excel.createExcel();
  final first = excel.getDefaultSheet() ?? 'Sheet1';
  excel.rename(first, 'المعاملات');
  excel.setDefaultSheet('المعاملات');

  final sheet = excel['المعاملات'];
  sheet.appendRow([
    _t('التاريخ'),
    _t('الوقت'),
    _t('المحفظة'),
    _t('نوع العملية'),
    _t('الاتجاه'),
    _t('المبلغ'),
    _t('الرسوم'),
    _t('الطرف الآخر'),
    _t('الرصيد'),
    _t('الحالة'),
    _t('ملاحظات'),
  ]);
  final sorted = List<Tx>.from(txs)..sort((a, b) => b.ts.compareTo(a.ts));
  for (final t in sorted) {
    final acc = accountFor(t, accounts);
    final d = DateTime.fromMillisecondsSinceEpoch(t.ts);
    sheet.appendRow([
      _t(dayKey(d)),
      _t('${two(d.hour)}:${two(d.minute)}'),
      _t(acc == null ? t.wallet : accountLabel(acc)),
      _t(t.type.label),
      _t(t.dir.label),
      DoubleCellValue(t.amount),
      DoubleCellValue(t.fee),
      _t(t.party ?? ''),
      t.balance == null ? null : DoubleCellValue(t.balance!),
      _t(t.review || t.isUnknown ? 'تحتاج مراجعة' : 'محسوبة'),
      _t(t.note),
    ]);
  }

  final days = <String, List<Tx>>{};
  for (final t in sorted) {
    days.putIfAbsent(dayKeyTs(t.ts), () => []).add(t);
  }
  final daily = excel['ملخص يومي'];
  daily.appendRow([
    _t('التاريخ'),
    _t('داخل'),
    _t('خارج'),
    _t('رسوم'),
    _t('الصافي'),
    _t('عدد المعاملات'),
  ]);
  days.forEach((day, list) {
    final tot = totalsOf(list);
    daily.appendRow([
      _t(day),
      DoubleCellValue(tot.inSum),
      DoubleCellValue(tot.outSum),
      DoubleCellValue(tot.fee),
      DoubleCellValue(tot.net),
      IntCellValue(tot.count),
    ]);
  });

  final byAccount = <String, List<Tx>>{};
  for (final t in sorted) {
    final acc = accountFor(t, accounts);
    byAccount
        .putIfAbsent(acc == null ? 'غير مربوط بحساب' : accountLabel(acc), () => [])
        .add(t);
  }
  final accSheet = excel['ملخص الأرقام'];
  accSheet.appendRow([
    _t('الرقم'),
    _t('داخل'),
    _t('خارج'),
    _t('رسوم'),
    _t('الصافي'),
    _t('عدد المعاملات'),
    _t('تحتاج مراجعة'),
  ]);
  byAccount.forEach((label, list) {
    final tot = totalsOf(list);
    accSheet.appendRow([
      _t(label),
      DoubleCellValue(tot.inSum),
      DoubleCellValue(tot.outSum),
      DoubleCellValue(tot.fee),
      DoubleCellValue(tot.net),
      IntCellValue(tot.count),
      IntCellValue(tot.pending + tot.unknown),
    ]);
  });

  return excel.encode();
}

/// Writes the report to a temporary .xlsx and opens the system share sheet, so
/// the owner can save it to Files / Drive or send it from any app.
Future<void> exportExcelReport(
  BuildContext context, {
  required List<Tx> txs,
  required List<Account> accounts,
}) async {
  void snack(String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  if (txs.isEmpty) {
    snack('لا توجد معاملات لتصديرها');
    return;
  }
  try {
    final bytes = buildReportXlsx(txs, accounts);
    if (bytes == null) {
      snack('تعذر إنشاء ملف Excel');
      return;
    }
    final dir = await getTemporaryDirectory();
    final now = DateTime.now();
    final name = 'amwali_${dayKey(now)}_${two(now.hour)}${two(now.minute)}.xlsx';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    await Share.shareXFiles(
      [
        XFile(
          file.path,
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ),
      ],
      subject: 'تقرير أموالي',
    );
  } catch (e) {
    snack('تعذر تصدير الملف: $e');
  }
}
