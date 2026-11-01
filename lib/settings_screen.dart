import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'backup_service.dart';
import 'db.dart';
import 'ledger_service.dart';
import 'review_strings.dart';

/// Backup and restore. A backup is the database plus every evidence file plus
/// a hash manifest; the Gemini key is never included. Excel export is not a
/// backup and is labelled as such.
class SettingsScreen extends StatefulWidget {
  /// Called after a successful restore so the rest of the app reloads.
  final Future<void> Function() onRestored;
  const SettingsScreen({super.key, required this.onRestored});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  String? _message;

  Future<void> _backup() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final root = await TxDb.storageRoot();
      final stamp = DateTime.now()
          .toIso8601String()
          .substring(0, 19)
          .replaceAll(RegExp(r'[:T]'), '-');
      final file =
          File(p.join(root.path, 'backups', 'wallet-backup-$stamp.zip'));
      final manifest =
          await BackupService(await TxDb.database(), root).create(file);
      if (!mounted) return;
      setState(() => _message = reviewText(
          context,
          'تم إنشاء النسخة (${(manifest['files'] as Map).length} ملف): ${file.path}',
          'Backup created (${(manifest['files'] as Map).length} files): ${file.path}'));
      await Share.shareXFiles([XFile(file.path)], subject: 'Wallet backup');
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final picked = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'backup', extensions: ['zip'])
    ]);
    if (picked == null || !mounted) return;
    final zip = File(picked.path);
    final BackupInfo info;
    try {
      info = await inspectBackup(zip);
    } on LedgerException catch (e) {
      setState(() => _message = e.message);
      return;
    }
    if (!mounted) return;
    final when = DateTime.fromMillisecondsSinceEpoch(info.createdAt)
        .toString()
        .substring(0, 16);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(reviewText(ctx, 'استعادة نسخة احتياطية', 'Restore backup')),
        content: Text(reviewText(
            ctx,
            'نسخة بتاريخ $when · إصدار قاعدة البيانات ${info.schemaVersion} · ${info.fileCount} ملف.\n'
                'ستحل محل البيانات الحالية. تُحفظ نسخة من بياناتك الحالية أولاً ويمكن الرجوع إليها.',
            'Backup from $when · database v${info.schemaVersion} · ${info.fileCount} files.\n'
                'It replaces the current data. A copy of your current data is saved first.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(reviewText(ctx, 'إلغاء', 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(reviewText(ctx, 'استعادة', 'Restore'))),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final pre = await restoreOver(
          zip, await TxDb.dbPath(), await TxDb.storageRoot(),
          live: await TxDb.database(), closeDb: TxDb.close, reopenDb: () async {
        await TxDb.database();
      }, verifyAfterSwitch: () async {
        final db = await TxDb.database();
        await db.rawQuery('SELECT COUNT(*) FROM tx');
      });
      await widget.onRestored();
      if (mounted) {
        setState(() => _message = reviewText(
            context,
            'تمت الاستعادة. نسخة بياناتك السابقة: ${pre?.path ?? '-'}',
            'Restored. Your previous data was saved at: ${pre?.path ?? '-'}'));
      }
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = reviewText;
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'الإعدادات', 'Settings'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(t(context, 'النسخ الاحتياطي', 'Backup & restore'),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(t(
            context,
            'النسخة تشمل قاعدة البيانات وكل ملفات الإثبات وسجل التدقيق. لا تشمل مفتاح Gemini. ملف Excel ليس نسخة احتياطية.',
            'A backup holds the database, every evidence file and the audit history. It does not include your Gemini key. An Excel export is not a backup.')),
        const SizedBox(height: 12),
        FilledButton.icon(
            onPressed: _busy ? null : _backup,
            icon: const Icon(Icons.save_alt),
            label: Text(
                t(context, 'إنشاء نسخة ومشاركتها', 'Create backup & share'))),
        const SizedBox(height: 8),
        OutlinedButton.icon(
            onPressed: _busy ? null : _restore,
            icon: const Icon(Icons.restore),
            label: Text(t(context, 'استعادة من ملف', 'Restore from file'))),
        if (_busy)
          const Padding(
              padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
        if (_message != null)
          Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText(_message!)),
      ]),
    );
  }
}
