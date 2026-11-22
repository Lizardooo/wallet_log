import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'backup_service.dart';
import 'db.dart';
import 'onboarding.dart';
import 'ledger_service.dart';
import 'review_strings.dart';
import 'wallet_sync_service.dart';
import 'privacy_disclosures.dart';

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
  bool _includeMessageText = false;
  final _endpoint = TextEditingController();
  final _token = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSyncSettings();
  }

  Future<void> _loadSyncSettings() async {
    try {
      final endpoint = await TxDb.setting(WalletSyncService.endpointKey) ?? '';
      final token = await TxDb.syncToken();
      if (!mounted) return;
      setState(() {
        _endpoint.text = endpoint;
        _token.text = token;
      });
    } catch (_) {
      if (mounted)
        setState(() => _message =
            'تعذر فتح التخزين الآمن. لن يُحفظ رمز المزامنة في قاعدة البيانات.');
    }
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    if (_busy) return;
    final endpoint = _endpoint.text.trim();
    final token = _token.text.trim();
    final includeMessageText = _includeMessageText;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final target = WalletSyncService.validatedEndpoint(endpoint);
      if (token.isEmpty) throw StateError('أدخل رمز المزامنة أولاً.');
      if (!mounted) return;
      final confirmed = await showSyncDisclosure(context, target,
          includeMessageText: includeMessageText);
      if (!confirmed || !mounted) return;
      await TxDb.setSyncToken(token);
      await TxDb.setSetting(WalletSyncService.endpointKey, endpoint);
      final result = await WalletSyncService.sync(
        endpoint: target.toString(),
        token: token,
        confirmed: true,
        includeMessageText: includeMessageText,
      );
      if (mounted) {
        setState(() => _message =
            'تمت المزامنة: ${result['inserted'] ?? 0} جديدة، ${result['updated'] ?? 0} محدثة.');
      }
    } catch (_) {
      // Do not display server bodies, credentials or arbitrary exception text.
      if (mounted)
        setState(() => _message =
            'لم تكتمل المزامنة. استخدم HTTPS وتحقق من الرابط والرمز والتخزين الآمن. '
                'قد يكون الخادم استلم البيانات إذا انقطع الاتصال؛ تحقق قبل إعادة المحاولة.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetSyncToken() async {
    try {
      await TxDb.setSyncToken('');
      if (mounted)
        setState(() {
          _token.clear();
          _message =
              'حُذف رمز المزامنة من هذا الهاتف. لا يحذف ذلك بيانات الخادم.';
        });
    } catch (_) {
      if (mounted)
        setState(() => _message = 'تعذر حذف الرمز من التخزين الآمن.');
    }
  }

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
        ListTile(
          leading: const Icon(Icons.sim_card_outlined),
          title: Text(t(context, 'اكتشاف وإضافة الشرائح والمحافظ',
              'Detect SIMs and add wallets')),
          subtitle: Text(t(context, 'بدون حذف الحسابات أو تغيير إعداد الذكاء',
              'Keeps existing accounts and AI settings')),
          onTap: _busy
              ? null
              : () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                          builder: (ctx) => OnboardingPage(
                              simOnly: true,
                              onDone: () async {
                                Navigator.pop(ctx);
                              })));
                  await widget.onRestored();
                },
        ),
        Text(t(context, 'النسخ الاحتياطي', 'Backup & restore'),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(t(
            context,
            'النسخة تشمل قاعدة البيانات وكل ملفات الإثبات وسجل التدقيق. لا تشمل مفتاح Gemini أو رمز المزامنة. ملف Excel ليس نسخة احتياطية.',
            'A backup holds the database, every evidence file and the audit history. It excludes your Gemini key and sync token. An Excel export is not a backup.')),
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
        const SizedBox(height: 28),
        Text(t(context, 'مزامنة لوحة التحكم', 'Dashboard sync'),
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(t(
            context,
            'المزامنة إرسال خارجي اختياري وليست معالجة محلية. استخدم رابط HTTPS للوحة تثق بها. ستراجع الوجهة والبيانات قبل كل إرسال؛ لا تتم مزامنة تلقائية.',
            'Sync is optional external sharing. Use an HTTPS dashboard you trust. Review the destination and data before every manual sync.')),
        const SizedBox(height: 8),
        TextField(
          controller: _endpoint,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
              labelText: t(context, 'رابط لوحة التحكم', 'Dashboard URL'),
              hintText: 'https://example.com'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _token,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          obscureText: true,
          decoration: InputDecoration(
              labelText: t(context, 'رمز المزامنة', 'Sync token')),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _includeMessageText,
          onChanged: _busy
              ? null
              : (value) => setState(() => _includeMessageText = value ?? false),
          title: const Text('تضمين نصوص رسائل المعاملات كاملة'),
          subtitle: const Text(
              'اختياري ومتوقف افتراضياً. قد تحتوي الرسائل على بيانات شخصية. '
              'بيانات الحسابات والمبالغ والطرف الآخر تُرسل حتى بدون النصوص.'),
        ),
        TextButton.icon(
          onPressed: _busy ? null : _forgetSyncToken,
          icon: const Icon(Icons.key_off),
          label: const Text('حذف رمز المزامنة المحفوظ'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _sync,
          icon: const Icon(Icons.sync),
          label: Text(t(context, 'مراجعة وإرسال', 'Review & send')),
        ),
      ]),
    );
  }
}
