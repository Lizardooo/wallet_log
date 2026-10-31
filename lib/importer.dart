import 'dart:typed_data';

import 'package:excel/excel.dart';

import 'parser.dart';

/// One transaction read from an Excel report, ready to be stored.
class ImportRow {
  final String key; // duplicate-detection key
  final int ts;
  final String wallet;
  final TxType type;
  final Dir dir;
  final double amount;
  final double fee;
  final String? party;
  final String note;
  final String body;

  const ImportRow({
    required this.key,
    required this.ts,
    required this.wallet,
    required this.type,
    required this.dir,
    required this.amount,
    this.fee = 0,
    this.party,
    this.note = '',
    this.body = '',
  });
}

/// What was understood from one sheet, before the owner confirms the import.
class SheetImport {
  final String name;
  final List<ImportRow> rows;
  final List<String> columns; // recognized column titles, in sheet order
  final int total; // data rows under the header
  final int skipped;
  final List<String> preview; // first few rows, human readable

  const SheetImport({
    required this.name,
    required this.rows,
    required this.columns,
    required this.total,
    required this.skipped,
    required this.preview,
  });

  bool get isEmpty => rows.isEmpty;
}

class WorkbookImport {
  final List<SheetImport> sheets;
  final String? error;

  const WorkbookImport(this.sheets, {this.error});

  bool get isEmpty => sheets.every((s) => s.isEmpty);

  int get rows => sheets.fold(0, (a, s) => a + s.rows.length);
}

enum _Field { date, time, amount, fee, type, dir, wallet, party, note }

const _keywords = <_Field, List<String>>{
  _Field.date: ['تاريخ العملية', 'التاريخ', 'تاريخ', 'date', 'اليوم'],
  _Field.time: ['الوقت', 'وقت', 'الساعة', 'time'],
  _Field.amount: ['المبلغ', 'مبلغ', 'القيمة', 'قيمة', 'amount', 'value'],
  _Field.fee: ['الرسوم', 'رسوم', 'العمولة', 'عمولة', 'fee', 'commission'],
  _Field.type: [
    'نوع العملية',
    'نوع الحركة',
    'النوع',
    'نوع',
    'التصنيف',
    'type',
    'category',
    'operation',
    'kind',
  ],
  _Field.dir: ['الاتجاه', 'اتجاه', 'direction', 'in/out', 'داخل/خارج'],
  _Field.wallet: [
    'رقم المحفظة',
    'المحفظة',
    'محفظة',
    'رقم الحساب',
    'الحساب',
    'wallet',
    'account',
  ],
  _Field.party: [
    'الطرف الآخر',
    'طرف آخر',
    'الطرف',
    'رقم الهاتف',
    'الهاتف',
    'رقم الموبايل',
    'party',
    'counterparty',
    'phone',
    'customer',
    'sender',
  ],
  _Field.note: [
    'ملاحظات',
    'ملاحظة',
    'البيان',
    'بيان',
    'الوصف',
    'وصف',
    'التفاصيل',
    'تفاصيل',
    'description',
    'details',
    'note',
    'notes',
    'remark',
  ],
};

/// Ordered on purpose: the first match wins, so "سداد" is a bill before "دفع"
/// is a merchant payment.
const _typeWords = <TxType, List<String>>{
  TxType.refund: ['استرداد', 'إسترداد', 'إرجاع', 'refund', 'reversal'],
  TxType.bill: ['فواتير', 'فاتورة', 'سداد', 'bill'],
  TxType.cashIn: ['ايداع', 'إيداع', 'استلام', 'استلمت', 'ضخ', 'deposit', 'cash in'],
  TxType.cashOut: ['سحب', 'صراف', 'atm', 'withdraw'],
  TxType.topup: ['شحن', 'recharge', 'top up', 'topup'],
  TxType.deduction: ['خصم', 'استقطاع', 'deduct', 'debit'],
  TxType.payment: ['مشتريات', 'تاجر', 'شراء', 'merchant', 'purchase', 'payment'],
  TxType.fee: ['رسوم', 'عمولة', 'fee', 'commission'],
  TxType.transfer: ['تحويل', 'حول', 'transfer', 'sent', 'received'],
};

/// Reads every sheet of an .xlsx workbook and turns the rows it understands into
/// [ImportRow]s. Nothing is written to the database here.
WorkbookImport readWorkbook(Uint8List bytes) {
  final Excel excel;
  try {
    excel = Excel.decodeBytes(bytes);
  } catch (_) {
    return const WorkbookImport(
      [],
      error: 'الملف غير مقروء. لازم يكون ملف Excel بصيغة .xlsx '
          '(مش .xls ولا CSV). افتحه في Excel أو Google Sheets وصدّره xlsx.',
    );
  }
  final sheets = <SheetImport>[];
  for (final entry in excel.tables.entries) {
    final sheet = entry.value;
    if (sheet.maxRows < 1 || sheet.maxColumns < 1) continue;
    final parsed = _readSheet(entry.key, sheet);
    if (parsed.total > 0) sheets.add(parsed);
  }
  if (sheets.isEmpty) {
    return const WorkbookImport(
      [],
      error: 'لم أجد أي صفوف في الملف. تأكد أن الصفحة الأولى فيها بيانات '
          'تحت عناوين الأعمدة.',
    );
  }
  return WorkbookImport(sheets);
}

String _text(Data? cell) {
  final v = cell?.value;
  if (v == null) return '';
  if (v is TextCellValue) return v.value.toString().trim();
  if (v is IntCellValue) return v.value.toString();
  if (v is DoubleCellValue) return _numText(v.value);
  if (v is BoolCellValue) return v.value ? 'true' : 'false';
  if (v is DateCellValue) {
    return '${v.year}-${_two(v.month)}-${_two(v.day)}';
  }
  if (v is DateTimeCellValue) {
    return '${v.year}-${_two(v.month)}-${_two(v.day)} '
        '${_two(v.hour)}:${_two(v.minute)}';
  }
  if (v is TimeCellValue) {
    return '${_two(v.hour)}:${_two(v.minute)}';
  }
  if (v is FormulaCellValue) return v.formula;
  return v.toString();
}

String _numText(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

String _two(int n) => n.toString().padLeft(2, '0');

/// Best column match for one header cell: the longest keyword wins, so
/// "رقم المحفظة" is the wallet column and not the party-phone column.
_Field? _headerField(String cell) {
  final s = normalizeDigits(cell).toLowerCase().trim();
  if (s.isEmpty) return null;
  _Field? best;
  var bestLen = 0;
  for (final e in _keywords.entries) {
    for (final kw in e.value) {
      if (kw.length > bestLen && s.contains(kw)) {
        best = e.key;
        bestLen = kw.length;
      }
    }
  }
  return best;
}

Map<_Field, int> _mapHeader(List<String> header) {
  final out = <_Field, int>{};
  for (var i = 0; i < header.length; i++) {
    final f = _headerField(header[i]);
    if (f != null && !out.containsKey(f)) out[f] = i;
  }
  return out;
}

Map<_Field, int> _positional(int columns) {
  if (columns >= 4) {
    return {
      _Field.date: 0,
      _Field.amount: 1,
      _Field.type: 2,
      _Field.note: 3,
    };
  }
  if (columns >= 2) {
    return {_Field.date: 0, _Field.amount: 1};
  }
  return {};
}

bool _looksLikeTotal(String s) {
  final t = s
      .replaceAll('إ', 'ا')
      .replaceAll('أ', 'ا')
      .replaceAll('ٱ', 'ا')
      .toLowerCase();
  return t.contains('اجمالي') ||
      t.contains('مجموع') ||
      t.contains('total') ||
      t.contains('balance b/f') ||
      t.contains('carried');
}

SheetImport _readSheet(String name, Sheet sheet) {
  final grid = <List<String>>[
    for (final row in sheet.rows) [for (final cell in row) _text(cell)],
  ];

  var headerIdx = -1;
  var bestCols = <_Field, int>{};
  for (var i = 0; i < grid.length && i < 10; i++) {
    final cols = _mapHeader(grid[i]);
    if (cols.length >= 2 &&
        (cols.containsKey(_Field.date) || cols.containsKey(_Field.amount)) &&
        cols.length > bestCols.length) {
      bestCols = cols;
      headerIdx = i;
    }
  }

  final columns = <String>[];
  final Map<_Field, int> map;
  if (headerIdx >= 0) {
    map = bestCols;
    final byIndex = <int, String>{};
    map.forEach((f, i) => byIndex[i] = _fieldLabel(f));
    for (var i = 0; i < grid[headerIdx].length; i++) {
      if (byIndex.containsKey(i)) columns.add(byIndex[i]!);
    }
  } else {
    map = _positional(sheet.maxColumns);
    for (final f in map.keys) {
      columns.add(_fieldLabel(f));
    }
  }

  final start = headerIdx < 0 ? 0 : headerIdx + 1;
  final rows = <ImportRow>[];
  final preview = <String>[];
  var total = 0;
  var skipped = 0;
  DateTime? lastDate;

  String cellAt(List<String> row, _Field f) {
    final i = map[f];
    if (i == null || i >= row.length) return '';
    return row[i].trim();
  }

  for (var r = start; r < grid.length; r++) {
    final cells = grid[r];
    final raw = cells.where((c) => c.isNotEmpty).join(' | ').trim();
    if (raw.isEmpty) continue;
    total++;

    if (_looksLikeTotal(
        '${cellAt(cells, _Field.type)} ${cellAt(cells, _Field.note)}')) {
      skipped++;
      continue;
    }

    final amount = _money(cellAt(cells, _Field.amount));
    if (amount == null || amount == 0) {
      skipped++;
      continue;
    }

    final date = _date('${cellAt(cells, _Field.date)} '
            '${cellAt(cells, _Field.time)} ${cellAt(cells, _Field.note)}') ??
        lastDate;
    if (date != null) lastDate = date;
    final when = date ?? DateTime.now();
    final ts = when.millisecondsSinceEpoch;

    final typeText = cellAt(cells, _Field.type);
    final noteText = cellAt(cells, _Field.note);
    final type = _type(typeText, noteText);
    var dir = _dir(cellAt(cells, _Field.dir)) ??
        _dir(typeText) ??
        _defaultDir(type);
    dir ??= amount < 0 ? Dir.outFlow : Dir.inFlow;

    final fee = _money(cellAt(cells, _Field.fee))?.abs() ?? 0;
    final wallet = cellAt(cells, _Field.wallet);
    final party = _phone('${cellAt(cells, _Field.party)} $raw');

    rows.add(ImportRow(
      key: 'xlsx|${stableHash('$name|$ts|${amount.abs()}|${type.name}|$raw')}',
      ts: ts,
      wallet: wallet.isEmpty ? 'من Excel' : wallet,
      type: type,
      dir: dir,
      amount: amount.abs(),
      fee: fee,
      party: party,
      note: 'استيراد Excel · ${name.isEmpty ? 'صفحة' : name}'
          '${noteText.isEmpty ? '' : ' · $noteText'}',
      body: raw,
    ));
    if (preview.length < 4) {
      preview.add('${_dayText(when)} · ${type.label} · ${dir.label} · '
          '${amount.abs().toStringAsFixed(2)}');
    }
  }

  return SheetImport(
    name: name,
    rows: rows,
    columns: columns,
    total: total,
    skipped: skipped,
    preview: preview,
  );
}

String _fieldLabel(_Field f) => switch (f) {
      _Field.date => 'التاريخ',
      _Field.time => 'الوقت',
      _Field.amount => 'المبلغ',
      _Field.fee => 'الرسوم',
      _Field.type => 'نوع العملية',
      _Field.dir => 'الاتجاه',
      _Field.wallet => 'المحفظة',
      _Field.party => 'الطرف الآخر',
      _Field.note => 'البيان',
    };

String _dayText(DateTime d) =>
    '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// "1,250.50 EGP" / "١٢٥٠٫٥" / "(300)" / "-300" -> number.
double? _money(String raw) {
  var s = normalizeDigits(raw).trim();
  if (s.isEmpty) return null;
  final negative = s.startsWith('(') && s.endsWith(')') || s.contains('-');
  s = s.replaceAll(RegExp(r'[^\d.,]'), '');
  if (s.isEmpty) return null;
  if (s.contains(',') && !s.contains('.')) {
    final parts = s.split(',');
    // "1,250" is a thousands separator; "1250,50" is a decimal comma.
    s = (parts.length == 2 && parts[1].length != 3)
        ? '${parts[0]}.${parts[1]}'
        : s.replaceAll(',', '');
  } else {
    s = s.replaceAll(',', '');
  }
  final v = double.tryParse(s);
  if (v == null) return null;
  return negative ? -v : v;
}

({int hour, int minute})? _clock(String s) {
  final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch(normalizeDigits(s));
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final mi = int.parse(m.group(2)!);
  if (h > 23 || mi > 59) return null;
  return (hour: h, minute: mi);
}

/// Excel stores dates as days since 1899-12-30 (with the 1900 leap-year bug).
DateTime _serialDate(double n) {
  final days = n.floor();
  final ms = ((n - days) * 86400000).round();
  return DateTime(1899, 12, 30)
      .add(Duration(days: days, milliseconds: ms));
}

DateTime? _date(String raw) {
  final s = normalizeDigits(raw).trim();
  if (s.isEmpty) return null;

  final m = RegExp(r'(\d{1,4})\s*[\/\-\.]\s*(\d{1,2})\s*[\/\-\.]\s*(\d{2,4})')
      .firstMatch(s);
  if (m != null) {
    final a = int.parse(m.group(1)!);
    final b = int.parse(m.group(2)!);
    final c = int.parse(m.group(3)!);
    int year, month, day;
    if (a > 31) {
      year = a;
      month = b;
      day = c;
    } else {
      day = a;
      month = b;
      year = c;
    }
    if (year < 100) year += 2000;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final clock = _clock(s);
    return DateTime(year, month, day, clock?.hour ?? 0, clock?.minute ?? 0);
  }

  final n = double.tryParse(s);
  if (n != null && n >= 1 && n <= 90000) return _serialDate(n);
  return null;
}

/// The explicit type column wins; the description is only a fallback, so
/// "تحويل" in the type column is not overridden by "استلام" in the remark.
TxType _type(String typeText, String noteText) =>
    _typeMatch(typeText) ?? _typeMatch(noteText) ?? TxType.other;

TxType? _typeMatch(String raw) {
  final hay = normalizeDigits(raw).toLowerCase().trim();
  if (hay.isEmpty) return null;
  for (final t in TxType.values) {
    if (t.name.toLowerCase() == hay || t.label == hay) return t;
  }
  for (final e in _typeWords.entries) {
    for (final w in e.value) {
      if (hay.contains(w)) return e.key;
    }
  }
  return null;
}

Dir? _dir(String raw) {
  final s = normalizeDigits(raw).toLowerCase().trim();
  if (s.isEmpty) return null;
  if (s == 'out' ||
      s.contains('خارج') ||
      s.contains('صادر') ||
      s.contains('debit') ||
      s.contains('ارسال') ||
      s.contains('إرسال')) {
    return Dir.outFlow;
  }
  if (s == 'in' ||
      s.contains('داخل') ||
      s.contains('وارد') ||
      s.contains('credit') ||
      s.contains('استلام') ||
      s.contains('ايداع') ||
      s.contains('إيداع')) {
    return Dir.inFlow;
  }
  return null;
}

Dir? _defaultDir(TxType t) => switch (t) {
      TxType.cashIn || TxType.refund => Dir.inFlow,
      TxType.cashOut ||
      TxType.bill ||
      TxType.payment ||
      TxType.fee ||
      TxType.deduction =>
        Dir.outFlow,
      TxType.transfer || TxType.topup || TxType.other => null,
    };

String? _phone(String raw) {
  final s = normalizeDigits(raw);
  final m = RegExp(r'01\d{9}').firstMatch(s);
  if (m != null) return m.group(0);
  final m2 = RegExp(r'\b\d{8,15}\b').firstMatch(s);
  return m2?.group(0);
}
