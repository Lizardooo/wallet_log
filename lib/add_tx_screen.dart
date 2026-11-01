import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'db.dart';
import 'evidence_service.dart';
import 'money_engine.dart';
import 'parser.dart';
import 'review_strings.dart';
import 'wallet_store.dart';

/// Records a transaction by hand (before or without the wallet SMS) and lets
/// proof be attached straight away or later. Nothing here confirms anything:
/// the record starts as "awaiting wallet confirmation".
class AddTransactionScreen extends StatefulWidget {
  const AddTransactionScreen({super.key});

  @override
  State<AddTransactionScreen> createState() => _AddTransactionScreenState();
}

class _Pick {
  final File file;
  String origin;
  String uploadedBy;
  _Pick(this.file, this.origin, this.uploadedBy);
}

class _AddTransactionScreenState extends State<AddTransactionScreen> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _fee = TextEditingController();
  final _party = TextEditingController();
  final _ref = TextEditingController();
  final _note = TextEditingController();
  List<WalletRow> _wallets = [];
  int? _wallet;
  String _dir = 'in';
  TxType _type = TxType.transfer;
  DateTime _when = DateTime.now();
  final _picks = <_Pick>[];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    () async {
      final w = await (await TxDb.wallets()).wallets();
      if (!mounted) return;
      setState(() {
        _wallets = w;
        if (w.length == 1) _wallet = w.first.id;
      });
    }();
  }

  @override
  void dispose() {
    for (final c in [_amount, _fee, _party, _ref, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickFile() async {
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(
          label: 'proof',
          extensions: ['jpg', 'jpeg', 'png', 'webp', 'heic', 'pdf'])
    ]);
    if (f == null) return;
    setState(() => _picks
        .add(_Pick(File(f.path), EvidenceOrigin.walletApp, UploadedBy.owner)));
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
        context: context,
        initialDate: _when,
        firstDate: DateTime(2015),
        lastDate: DateTime.now());
    if (d == null || !mounted) return;
    final t = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(_when));
    if (t == null) return;
    setState(() => _when = DateTime(d.year, d.month, d.day, t.hour, t.minute));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || _wallet == null) {
      if (_wallet == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text(reviewText(context, 'اختر المحفظة', 'Choose a wallet'))));
      }
      return;
    }
    setState(() => _saving = true);
    final msg = ScaffoldMessenger.of(context);
    try {
      final led = await TxDb.ledger();
      final id = await led.createManual(
        walletAccountId: _wallet!,
        amountMinor: parseMinor(_amount.text)!,
        feeMinor: parseMinor(_fee.text) ?? 0,
        dir: _dir,
        type: _type.name,
        ts: _when.millisecondsSinceEpoch,
        counterparty: _party.text.trim().isEmpty ? null : _party.text.trim(),
        reference: _ref.text,
        description: _note.text.trim(),
      );
      final ev = await TxDb.evidence();
      for (final p in _picks) {
        await ev.attachFile(id, p.file,
            kind: switch (p.origin) {
              EvidenceOrigin.instantMessage => EvidenceKind.instantMessage,
              EvidenceOrigin.receipt => EvidenceKind.receipt,
              EvidenceOrigin.other => EvidenceKind.other,
              _ => EvidenceKind.walletApp,
            },
            origin: p.origin,
            uploadedBy: p.uploadedBy);
      }
      await (await TxDb.matches()).suggestAll();
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      msg.showSnackBar(SnackBar(content: Text('$e')));
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _money(String? v, {bool optional = false}) {
    if ((v ?? '').trim().isEmpty) {
      return optional
          ? null
          : reviewText(context, 'أدخل المبلغ', 'Enter an amount');
    }
    final m = parseMinor(v!);
    if (m == null || (!optional && m == 0)) {
      return reviewText(context, 'مبلغ غير صحيح (حتى رقمين عشريين)',
          'Invalid amount (max 2 decimals)');
    }
    return null;
  }

  String _originLabel(String o) => switch (o) {
        EvidenceOrigin.providerSms =>
          reviewText(context, 'رسالة المحفظة', 'Wallet SMS'),
        EvidenceOrigin.walletApp =>
          reviewText(context, 'تطبيق المحفظة', 'Wallet app'),
        EvidenceOrigin.senderWalletApp =>
          reviewText(context, 'تطبيق المرسل', "Sender's wallet app"),
        EvidenceOrigin.instantMessage =>
          reviewText(context, 'رسالة (واتساب...)', 'Instant message'),
        EvidenceOrigin.receipt => reviewText(context, 'إيصال', 'Receipt'),
        _ => reviewText(context, 'أخرى', 'Other'),
      };

  @override
  Widget build(BuildContext context) {
    final t = reviewText;
    return Scaffold(
      appBar:
          AppBar(title: Text(t(context, 'تسجيل معاملة', 'Add transaction'))),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (_wallets.isEmpty)
            Text(t(context, 'أضف محفظة أولاً.', 'Add a wallet first.')),
          DropdownButtonFormField<int>(
            initialValue: _wallet,
            decoration:
                InputDecoration(labelText: t(context, 'المحفظة', 'Wallet')),
            items: [
              for (final w in _wallets)
                DropdownMenuItem(
                    value: w.id,
                    child: Text(
                        '${w.providerName} ${w.nickname.isEmpty ? w.phone : w.nickname}',
                        overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _wallet = v),
          ),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                  value: 'in', label: Text(t(context, 'وارد', 'Incoming'))),
              ButtonSegment(
                  value: 'out', label: Text(t(context, 'صادر', 'Outgoing'))),
            ],
            selected: {_dir},
            onSelectionChanged: (s) => setState(() => _dir = s.first),
          ),
          TextFormField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration:
                  InputDecoration(labelText: t(context, 'المبلغ', 'Amount')),
              validator: _money),
          TextFormField(
              controller: _fee,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                  labelText: t(context, 'الرسوم (اختياري)', 'Fee (optional)')),
              validator: (v) => _money(v, optional: true)),
          DropdownButtonFormField<TxType>(
            initialValue: _type,
            decoration:
                InputDecoration(labelText: t(context, 'النوع', 'Category')),
            items: [
              for (final x in TxType.values)
                DropdownMenuItem(value: x, child: Text(x.name)),
            ],
            onChanged: (v) => setState(() => _type = v ?? _type),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t(context, 'التاريخ والوقت', 'Date and time')),
            subtitle: Text(_when.toString().substring(0, 16)),
            trailing: const Icon(Icons.edit_calendar),
            onTap: _pickDate,
          ),
          TextFormField(
              controller: _party,
              decoration: InputDecoration(
                  labelText: t(context, 'الطرف الآخر (اختياري)',
                      'Counterparty (optional)'))),
          TextFormField(
              controller: _ref,
              decoration: InputDecoration(
                  labelText: t(context, 'رقم المرجع (اختياري)',
                      'Reference no. (optional)'))),
          TextFormField(
              controller: _note,
              decoration: InputDecoration(
                  labelText:
                      t(context, 'وصف (اختياري)', 'Description (optional)'))),
          const Divider(height: 32),
          Text(
              t(context, 'الإثبات (اختياري، يمكن إضافته لاحقاً)',
                  'Evidence (optional, can be added later)'),
              style: Theme.of(context).textTheme.titleSmall),
          for (final p in _picks)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(p.file.path.split('/').last,
                                overflow: TextOverflow.ellipsis)),
                        IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() => _picks.remove(p))),
                      ]),
                      DropdownButton<String>(
                        isExpanded: true,
                        value: p.origin,
                        items: [
                          for (final o in EvidenceOrigin.all
                              .where((o) => o != EvidenceOrigin.providerSms))
                            DropdownMenuItem(
                                value: o, child: Text(_originLabel(o))),
                        ],
                        onChanged: (v) =>
                            setState(() => p.origin = v ?? p.origin),
                      ),
                      DropdownButton<String>(
                        isExpanded: true,
                        value: p.uploadedBy,
                        items: [
                          DropdownMenuItem(
                              value: UploadedBy.owner,
                              child: Text(t(context, 'رفعه: صاحب المحفظة',
                                  'Uploaded by: wallet owner'))),
                          DropdownMenuItem(
                              value: UploadedBy.sender,
                              child: Text(t(context, 'رفعه: المرسل',
                                  'Uploaded by: sender'))),
                          DropdownMenuItem(
                              value: UploadedBy.other,
                              child: Text(t(context, 'رفعه: شخص آخر',
                                  'Uploaded by: someone else'))),
                        ],
                        onChanged: (v) =>
                            setState(() => p.uploadedBy = v ?? p.uploadedBy),
                      ),
                    ]),
              ),
            ),
          OutlinedButton.icon(
              onPressed: _pickFile,
              icon: const Icon(Icons.attach_file),
              label: Text(t(context, 'إرفاق ملف', 'Attach file'))),
          const SizedBox(height: 8),
          Text(
              t(
                  context,
                  'ستُسجَّل كمعاملة يدوية بانتظار تأكيد المحفظة، ولا تُحتسب في الرصيد المؤكد.',
                  'Saved as a manual record awaiting wallet confirmation; it is not counted in the confirmed balance.'),
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(t(context, 'حفظ', 'Save'))),
        ]),
      ),
    );
  }
}
