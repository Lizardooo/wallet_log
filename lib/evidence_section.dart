import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'evidence_service.dart';
import 'ledger_service.dart';
import 'review_strings.dart';

String originLabel(BuildContext c, String o) => switch (o) {
      EvidenceOrigin.providerSms =>
        reviewText(c, 'رسالة المحفظة', 'Wallet SMS'),
      EvidenceOrigin.walletApp => reviewText(c, 'تطبيق المحفظة', 'Wallet app'),
      EvidenceOrigin.senderWalletApp =>
        reviewText(c, 'تطبيق المرسل', "Sender's wallet app"),
      EvidenceOrigin.instantMessage =>
        reviewText(c, 'رسالة (واتساب...)', 'Instant message'),
      EvidenceOrigin.receipt => reviewText(c, 'إيصال', 'Receipt'),
      _ => reviewText(c, 'أخرى', 'Other'),
    };

String uploaderLabel(BuildContext c, String u) => switch (u) {
      UploadedBy.owner => reviewText(c, 'صاحب المحفظة', 'Wallet owner'),
      UploadedBy.sender => reviewText(c, 'المرسل', 'Sender'),
      _ => reviewText(c, 'شخص آخر', 'Someone else'),
    };

String kindFor(String origin) => switch (origin) {
      EvidenceOrigin.instantMessage => EvidenceKind.instantMessage,
      EvidenceOrigin.receipt => EvidenceKind.receipt,
      EvidenceOrigin.other => EvidenceKind.other,
      EvidenceOrigin.providerSms => EvidenceKind.sms,
      _ => EvidenceKind.walletApp,
    };

bool _isImage(Map<String, Object?> e) =>
    ((e['mime'] as String?) ?? '').startsWith('image/');

/// Proof attached to one transaction: SMS evidence apart from uploaded files,
/// origin and uploader shown separately, an integrity check per file, a
/// full-screen viewer, adding more later, and hide-with-reason (never delete).
/// Having evidence never changes the transaction's confirmation.
class EvidenceSection extends StatefulWidget {
  final EvidenceService service;
  final int txId;

  /// Picks a file to attach; defaults to the system file picker.
  final Future<File?> Function()? pick;

  const EvidenceSection(
      {super.key, required this.service, required this.txId, this.pick});

  @override
  State<EvidenceSection> createState() => _EvidenceSectionState();
}

class _EvidenceSectionState extends State<EvidenceSection> {
  List<Map<String, Object?>> _items = [];
  final Map<int, bool> _intact = {};
  bool _showRemoved = false, _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await widget.service.list(widget.txId, includeRemoved: true);
    final ok = <int, bool>{};
    for (final e in items) {
      if (e['removed_at'] == null)
        ok[e['id']! as int] = await widget.service.verify(e['id']! as int);
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _intact
        ..clear()
        ..addAll(ok);
      _loaded = true;
    });
  }

  Future<File?> _pick() async {
    if (widget.pick != null) return widget.pick!();
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(
          label: 'proof',
          extensions: ['jpg', 'jpeg', 'png', 'webp', 'heic', 'pdf'])
    ]);
    return f == null ? null : File(f.path);
  }

  Future<void> _add() async {
    final file = await _pick();
    if (file == null || !mounted) return;
    var origin = EvidenceOrigin.walletApp, by = UploadedBy.owner;
    final note = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(reviewText(ctx, 'إضافة إثبات', 'Add evidence')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(file.path.split('/').last, overflow: TextOverflow.ellipsis),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: origin,
                decoration: InputDecoration(
                    labelText:
                        reviewText(ctx, 'مصدر الإثبات', 'Where it came from')),
                items: [
                  for (final o in EvidenceOrigin.all
                      .where((o) => o != EvidenceOrigin.providerSms))
                    DropdownMenuItem(
                        value: o, child: Text(originLabel(ctx, o))),
                ],
                onChanged: (v) => set(() => origin = v ?? origin),
              ),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: by,
                decoration: InputDecoration(
                    labelText: reviewText(ctx, 'رفعه', 'Uploaded by')),
                items: [
                  for (final u in UploadedBy.all)
                    DropdownMenuItem(
                        value: u, child: Text(uploaderLabel(ctx, u))),
                ],
                onChanged: (v) => set(() => by = v ?? by),
              ),
              TextField(
                  controller: note,
                  decoration: InputDecoration(
                      labelText: reviewText(
                          ctx, 'ملاحظة (اختياري)', 'Note (optional)'))),
              const SizedBox(height: 8),
              Text(
                  reviewText(ctx, 'الإثبات لا يؤكد وصول المال بنفسه.',
                      'Evidence does not confirm the money arrived.'),
                  style: Theme.of(ctx).textTheme.bodySmall),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(reviewText(ctx, 'إلغاء', 'Cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(reviewText(ctx, 'إضافة', 'Add'))),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    final msg = ScaffoldMessenger.of(context);
    try {
      await widget.service.attachFile(widget.txId, file,
          kind: kindFor(origin),
          origin: origin,
          uploadedBy: by,
          note: note.text.trim());
    } on LedgerException catch (e) {
      msg.showSnackBar(SnackBar(content: Text(e.message)));
    }
    await _load();
  }

  Future<void> _remove(Map<String, Object?> e) async {
    final reason = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(reviewText(ctx, 'إخفاء الإثبات', 'Hide evidence')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(reviewText(ctx, 'يبقى الملف محفوظاً في السجل ولا يُحذف.',
              'The file stays stored in the record; nothing is deleted.')),
          TextField(
              controller: reason,
              decoration: InputDecoration(
                  labelText: reviewText(ctx, 'السبب', 'Reason'))),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(reviewText(ctx, 'إلغاء', 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(reviewText(ctx, 'إخفاء', 'Hide'))),
        ],
      ),
    );
    if (go != true || reason.text.trim().isEmpty) return;
    await widget.service.remove(e['id']! as int, reason: reason.text.trim());
    await _load();
  }

  void _view(List<Map<String, Object?>> files, int start) {
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => EvidenceViewer(
                service: widget.service, items: files, initial: start)));
  }

  String _when(Object? ms) => DateTime.fromMillisecondsSinceEpoch(ms! as int)
      .toString()
      .substring(0, 16);

  @override
  Widget build(BuildContext context) {
    final active = _items.where((e) => e['removed_at'] == null).toList();
    final removed = _items.where((e) => e['removed_at'] != null).toList();
    final sms = active.where((e) => e['kind'] == EvidenceKind.sms).toList();
    final files = active.where((e) => e['kind'] != EvidenceKind.sms).toList();
    final viewable = files.where((e) => e['file_path'] != null).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
            child: Text(reviewText(context, 'الإثبات', 'Evidence'),
                style: Theme.of(context).textTheme.titleMedium)),
        TextButton.icon(
            onPressed: _add,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(reviewText(context, 'إضافة', 'Add'))),
      ]),
      if (_loaded && active.isEmpty)
        Text(reviewText(context, 'لا يوجد إثبات. يمكن إضافته الآن أو لاحقاً.',
            'No evidence yet. You can add it now or later.')),
      if (sms.isNotEmpty) ...[
        Text(reviewText(context, 'رسائل المحفظة', 'Wallet SMS'),
            style: Theme.of(context).textTheme.labelLarge),
        for (final e in sms)
          Card(
            child: ListTile(
              leading: const Icon(Icons.sms_outlined),
              title: Text('${e['sms_body']}',
                  maxLines: 4, overflow: TextOverflow.ellipsis),
              subtitle: Text([
                if (e['sms_sender'] != null) '${e['sms_sender']}',
                if (e['sms_ts'] != null) _when(e['sms_ts']),
                if (e['reference'] != null) '#${e['reference']}',
              ].join(' · ')),
            ),
          ),
      ],
      if (files.isNotEmpty) ...[
        Text(reviewText(context, 'ملفات مرفوعة', 'Uploaded files'),
            style: Theme.of(context).textTheme.labelLarge),
        for (final e in files)
          Card(
            child: ListTile(
              key: ValueKey('evidence-${e['id']}'),
              leading: SizedBox(
                width: 48,
                height: 48,
                child: _isImage(e) && widget.service.fileOf(e) != null
                    ? Image.file(widget.service.fileOf(e)!,
                        fit: BoxFit.cover,
                        cacheWidth: 96,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image_outlined))
                    : const Icon(Icons.description_outlined),
              ),
              title: Text('${e['file_name']}', overflow: TextOverflow.ellipsis),
              subtitle: Text([
                '${reviewText(context, 'المصدر', 'Origin')}: ${originLabel(context, '${e['origin']}')}',
                '${reviewText(context, 'رفعه', 'Uploaded by')}: ${uploaderLabel(context, '${e['uploaded_by']}')}',
                _when(e['created_at']),
                if ((e['note'] as String? ?? '').isNotEmpty) '${e['note']}',
              ].join('\n')),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(
                    _intact[e['id']] == false
                        ? Icons.error_outline
                        : Icons.verified_outlined,
                    key: ValueKey('integrity-${e['id']}'),
                    color:
                        _intact[e['id']] == false ? Colors.red : Colors.green,
                    semanticLabel: _intact[e['id']] == false
                        ? reviewText(context, 'الملف مفقود أو تغيّر',
                            'File missing or altered')
                        : reviewText(
                            context, 'سلامة الملف مؤكدة', 'File intact')),
                IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: reviewText(context, 'إخفاء', 'Hide'),
                    icon: const Icon(Icons.visibility_off_outlined, size: 18),
                    onPressed: () => _remove(e)),
              ]),
              onTap: viewable.isEmpty
                  ? null
                  : () => _view(viewable, viewable.indexOf(e)),
            ),
          ),
      ],
      if (removed.isNotEmpty)
        TextButton(
            onPressed: () => setState(() => _showRemoved = !_showRemoved),
            child: Text(reviewText(context, 'مخفي (${removed.length})',
                'Hidden (${removed.length})'))),
      if (_showRemoved)
        for (final e in removed)
          ListTile(
            dense: true,
            leading: const Icon(Icons.history),
            title: Text('${e['file_name'] ?? e['sms_body']}',
                overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${reviewText(context, 'أُخفي', 'Hidden')} ${_when(e['removed_at'])}: ${e['removed_reason']}'),
          ),
    ]);
  }
}

/// Full-screen, swipeable, pinch-to-zoom viewer. Shows the stored original.
class EvidenceViewer extends StatelessWidget {
  final EvidenceService service;
  final List<Map<String, Object?>> items;
  final int initial;
  const EvidenceViewer(
      {super.key,
      required this.service,
      required this.items,
      this.initial = 0});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar:
          AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: PageView.builder(
        controller: PageController(initialPage: initial < 0 ? 0 : initial),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final e = items[i];
          final f = service.fileOf(e);
          if (f == null || !_isImage(e)) {
            return Center(
                child: Text('${e['file_name']}',
                    style: const TextStyle(color: Colors.white)));
          }
          return InteractiveViewer(
              maxScale: 6,
              child: Center(
                  child: Image.file(f,
                      key: ValueKey('full-${e['id']}'),
                      errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white))));
        },
      ),
    );
  }
}
