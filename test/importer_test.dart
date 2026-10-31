import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wallet_log/importer.dart';
import 'package:wallet_log/parser.dart';

// A workbook shaped like a trader's own report, not a wallet template.
Uint8List sample() {
  final excel = Excel.createExcel();
  final sheet = excel['تقرير'];
  sheet.appendRow([
    TextCellValue('التاريخ'),
    TextCellValue('نوع العملية'),
    TextCellValue('المبلغ'),
    TextCellValue('رقم المحفظة'),
    TextCellValue('البيان'),
  ]);
  sheet.appendRow([
    TextCellValue('2026-10-01'),
    TextCellValue('تحويل'),
    TextCellValue('1,250.50'),
    TextCellValue('01012345678'),
    TextCellValue('استلام من عميل'),
  ]);
  sheet.appendRow([
    TextCellValue('02/10/2026 14:30'),
    TextCellValue('سحب'),
    TextCellValue('-300'),
    TextCellValue('01012345678'),
    TextCellValue('سحب نقدي'),
  ]);
  sheet.appendRow([
    TextCellValue('٣/١٠/٢٠٢٦'),
    TextCellValue('فاتورة'),
    TextCellValue('(320.75) جنيه'),
    TextCellValue('01098765432'),
    TextCellValue('فاتورة كهرباء'),
  ]);
  sheet.appendRow([
    TextCellValue('2026-10-04'),
    TextCellValue('إجمالي'),
    TextCellValue('2000'),
    TextCellValue(''),
    TextCellValue('الإجمالي'),
  ]);
  sheet.appendRow([
    DateCellValue(year: 2026, month: 10, day: 6),
    TextCellValue('خصم'),
    DoubleCellValue(75.25),
    TextCellValue('01011111111'),
    TextCellValue('رسوم'),
  ]);
  return Uint8List.fromList(excel.encode()!);
}

void main() {
  test('reads a report sheet and maps its columns', () {
    final wb = readWorkbook(sample());
    expect(wb.error, isNull);
    expect(wb.sheets, hasLength(1));

    final s = wb.sheets.first;
    expect(s.columns.join(','), 'التاريخ,نوع العملية,المبلغ,المحفظة,البيان');
    expect(s.total, 5);
    expect(s.skipped, 1); // the "إجمالي" row
    expect(s.rows, hasLength(4));
  });

  test('dates, amounts and directions', () {
    final rows = readWorkbook(sample()).sheets.first.rows;
    DateTime day(int i) =>
        DateTime.fromMillisecondsSinceEpoch(rows[i].ts);

    // The type column wins over words in the description.
    expect(rows[0].type, TxType.transfer);
    expect(rows[0].dir, Dir.inFlow);
    expect(rows[0].amount, 1250.5);
    expect(rows[0].party, '01012345678');
    expect(day(0), DateTime(2026, 10, 1));

    expect(rows[1].type, TxType.cashOut);
    expect(rows[1].dir, Dir.outFlow);
    expect(rows[1].amount, 300);
    expect(day(1), DateTime(2026, 10, 2, 14, 30)); // time is kept

    expect(rows[2].amount, 320.75); // Arabic digits + parentheses
    expect(rows[2].type, TxType.bill);
    expect(day(2), DateTime(2026, 10, 3));

    expect(rows[3].type, TxType.deduction);
    expect(rows[3].amount, 75.25); // real date cell
    expect(day(3), DateTime(2026, 10, 6));
  });

  test('keys are stable so a second import adds nothing', () {
    final a = readWorkbook(sample()).sheets.first.rows.map((r) => r.key);
    final b = readWorkbook(sample()).sheets.first.rows.map((r) => r.key);
    expect(a.toList(), b.toList());
  });

  test('a file that is not xlsx is reported, not thrown', () {
    final wb = readWorkbook(Uint8List.fromList([1, 2, 3, 4]));
    expect(wb.error, isNotNull);
    expect(wb.sheets, isEmpty);
  });

  test('rows without a recognizable date use the previous row date', () {
    final excel = Excel.createExcel();
    final sheet = excel['ورقة'];
    sheet.appendRow([TextCellValue('date'), TextCellValue('amount')]);
    sheet.appendRow([TextCellValue('2026-01-05'), TextCellValue('10')]);
    sheet.appendRow([TextCellValue(''), TextCellValue('20')]);
    final rows =
        readWorkbook(Uint8List.fromList(excel.encode()!)).sheets.first.rows;
    expect(rows, hasLength(2));
    expect(
      DateTime.fromMillisecondsSinceEpoch(rows[1].ts),
      DateTime(2026, 1, 5),
    );
  });
}
