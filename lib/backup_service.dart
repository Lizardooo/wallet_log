/// Full backup and restore: database snapshot, evidence files and a manifest
/// of content hashes in one zip. An Excel export is not a backup.
///
/// The Gemini API key is deliberately left out of the snapshot; it is a
/// secret, not wallet data, and is entered again after a restore.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'ledger_service.dart';
import 'schema.dart';

const backupFormat = 1;
const _secretSettings = ['gemini_api_key'];

class BackupService {
  final Database db;

  /// Same private directory the evidence service uses.
  final Directory root;
  const BackupService(this.db, this.root);

  /// Writes the backup zip to [dest] and returns the manifest.
  Future<Map<String, Object?>> create(File dest) async {
    final tmp = await Directory.systemTemp.createTemp('wallet-backup-');
    try {
      final snap = p.join(tmp.path, 'wallet.db');
      await db.execute("VACUUM INTO '${snap.replaceAll("'", "''")}'");
      final copy = await openDatabase(snap, singleInstance: false);
      for (final k in _secretSettings) {
        await copy.delete('settings', where: 'key = ?', whereArgs: [k]);
      }
      final active = await copy.rawQuery(
          'SELECT file_path FROM evidence WHERE file_path IS NOT NULL');
      await copy.close();

      final files = <String, String>{};
      final archive = Archive();
      void add(String name, List<int> bytes) {
        files[name] = sha256.convert(bytes).toString();
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }

      add('wallet.db', await File(snap).readAsBytes());
      // Every evidence file, including ones hidden from the active list.
      for (final r in active) {
        final rel = r['file_path']! as String;
        final f = File(p.join(root.path, rel));
        if (!await f.exists()) continue;
        add(p.posix.joinAll(p.split(rel)), await f.readAsBytes());
      }
      final manifest = <String, Object?>{
        'format': backupFormat,
        'schema_version': schemaVersion,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'files': files,
      };
      final mb = utf8.encode(jsonEncode(manifest));
      archive.addFile(ArchiveFile('manifest.json', mb.length, mb));
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(ZipEncoder().encode(archive)!, flush: true);
      return manifest;
    } finally {
      await tmp.delete(recursive: true);
    }
  }
}

class BackupInfo {
  final int format, schemaVersion, createdAt, fileCount;
  const BackupInfo(
      this.format, this.schemaVersion, this.createdAt, this.fileCount);
}

class _Opened {
  final Map<String, ArchiveFile> byName;
  final Map<String, String> files;
  final BackupInfo info;
  _Opened(this.byName, this.files, this.info);
}

Future<_Opened> _open(File zip) async {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
  } catch (_) {
    throw const LedgerException('not a wallet backup');
  }
  final byName = {
    for (final f in archive.files)
      if (f.isFile) f.name: f
  };
  final mf = byName['manifest.json'];
  if (mf == null || byName['wallet.db'] == null) {
    throw const LedgerException('not a wallet backup');
  }
  final manifest =
      jsonDecode(utf8.decode(mf.content as List<int>)) as Map<String, dynamic>;
  if ((manifest['format'] as int?) != backupFormat ||
      (manifest['schema_version'] as int) > schemaVersion) {
    throw const LedgerException('backup is from a newer or unknown version');
  }
  final files = (manifest['files'] as Map).cast<String, String>();
  for (final e in files.entries) {
    if (p.isAbsolute(e.key) || e.key.split('/').contains('..')) {
      throw const LedgerException('backup contains an unsafe path');
    }
    final f = byName[e.key];
    if (f == null ||
        sha256.convert(f.content as List<int>).toString() != e.value) {
      throw LedgerException('backup is damaged: ${e.key}');
    }
  }
  return _Opened(
      byName,
      files,
      BackupInfo(manifest['format'] as int, manifest['schema_version'] as int,
          manifest['created_at'] as int, files.length));
}

/// Reads and fully validates a backup (every file hash) without touching any
/// live data. Throws [LedgerException] when it is unusable.
Future<BackupInfo> inspectBackup(File zip) async => (await _open(zip)).info;

/// Restores [zip] over the current data without ever leaving it half-replaced:
///
/// 1. validate the archive, 2. write a pre-restore backup of the live data
/// (when [live] is given), 3. extract into a staging folder and check database
/// integrity and every evidence hash there, 4. close the live database and
/// swap by renaming, 5. reopen and verify. Any failure after step 4 renames
/// the old data back and reopens it. The old files stay as `*.pre-restore`.
///
/// Returns the pre-restore backup file (null when there was nothing to save).
Future<File?> restoreOver(
  File zip,
  String targetDbPath,
  Directory targetRoot, {
  Database? live,
  Future<void> Function()? closeDb,
  Future<void> Function()? reopenDb,
  Future<void> Function()? verifyAfterSwitch,
}) async {
  final opened = await _open(zip);
  final stamp = DateTime.now().millisecondsSinceEpoch;

  File? pre;
  if (live != null) {
    pre = File(p.join(targetRoot.path, 'pre-restore', 'before-$stamp.zip'));
    await BackupService(live, targetRoot).create(pre);
  }

  final staging = Directory(p.join(targetRoot.path, '.restore-staging-$stamp'));
  try {
    await staging.create(recursive: true);
    final stagedDb = File(p.join(staging.path, 'wallet.db'));
    await stagedDb.writeAsBytes(
        opened.byName['wallet.db']!.content as List<int>,
        flush: true);
    for (final e in opened.files.entries) {
      if (e.key == 'wallet.db') continue;
      final out = File(p.joinAll([staging.path, ...e.key.split('/')]));
      await out.parent.create(recursive: true);
      await out.writeAsBytes(opened.byName[e.key]!.content as List<int>,
          flush: true);
    }
    // Staged database: bring older schemas up to date, then check it.
    final sdb = await openDatabase(stagedDb.path,
        version: schemaVersion,
        singleInstance: false,
        onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: migrate);
    try {
      final problems = await integrityProblems(sdb);
      if (problems.isNotEmpty) {
        throw LedgerException(
            'restored database failed checks: ${problems.first}');
      }
      for (final r in await sdb.rawQuery(
          'SELECT file_path, sha256 FROM evidence WHERE file_path IS NOT NULL')) {
        final f = File(p.join(staging.path, r['file_path']! as String));
        if (!await f.exists() ||
            sha256.convert(await f.readAsBytes()).toString() != r['sha256']) {
          throw LedgerException(
              'evidence file missing or altered: ${r['file_path']}');
        }
      }
    } finally {
      await sdb.close();
    }

    // Swap. Everything replaced is renamed, never deleted.
    await closeDb?.call();
    final dbFile = File(targetDbPath);
    final oldDb = File('$targetDbPath.pre-restore-$stamp');
    final evDir = Directory(p.join(targetRoot.path, 'evidence'));
    final oldEv =
        Directory(p.join(targetRoot.path, 'evidence.pre-restore-$stamp'));
    final movedWal = <File>[];
    var movedDb = false, movedEv = false, placedDb = false;
    try {
      if (await dbFile.exists()) {
        await dbFile.rename(oldDb.path);
        movedDb = true;
      }
      for (final ext in ['-wal', '-shm']) {
        final w = File('$targetDbPath$ext');
        if (await w.exists()) {
          await w.rename('${oldDb.path}$ext');
          movedWal.add(w);
        }
      }
      if (await evDir.exists()) {
        await evDir.rename(oldEv.path);
        movedEv = true;
      }
      await dbFile.parent.create(recursive: true);
      await stagedDb.rename(targetDbPath);
      placedDb = true;
      final stagedEv = Directory(p.join(staging.path, 'evidence'));
      if (await stagedEv.exists()) await stagedEv.rename(evDir.path);
      await reopenDb?.call();
      await verifyAfterSwitch?.call();
    } catch (e) {
      // Roll back to exactly what was there before.
      try {
        await closeDb?.call();
      } catch (_) {}
      if (placedDb && await dbFile.exists()) await dbFile.delete();
      if (await evDir.exists()) await evDir.delete(recursive: true);
      if (movedDb) await oldDb.rename(targetDbPath);
      for (final w in movedWal) {
        final ext = w.path.endsWith('-wal') ? '-wal' : '-shm';
        final saved = File('${oldDb.path}$ext');
        if (await saved.exists()) await saved.rename(w.path);
      }
      if (movedEv) await oldEv.rename(evDir.path);
      await reopenDb?.call();
      throw LedgerException('restore failed and was rolled back: $e');
    }
    return pre;
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}

/// Restore into a location that has no database yet (clean install).
Future<void> restoreBackup(
    File zip, String targetDbPath, Directory targetRoot) async {
  if (await File(targetDbPath).exists()) {
    throw const LedgerException('a database already exists here');
  }
  await restoreOver(zip, targetDbPath, targetRoot);
}
