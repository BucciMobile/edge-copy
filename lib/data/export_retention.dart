import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where the manual "Export database" / "Export encrypted" snapshots go.
///
/// Their own folder, not the temp root: automatic backups, issue reports and
/// the health upload also write `openstrap_export_*.db` snapshots to temp and
/// delete them when done, so a sweep over the temp root could remove one of
/// those mid-flight. Inside this folder every file belongs to a manual export.
Future<Directory> sharedExportDir() async {
  final tmp = await getTemporaryDirectory();
  final dir = Directory(p.join(tmp.path, 'db_share'));
  await dir.create(recursive: true);
  return dir;
}

/// How many manual exports survive a sweep.
///
/// Two, for the same reason the CSV export keeps two runs: the share target
/// reads the file lazily, so the previous export's file may still be open in a
/// share sheet when the next one starts. Each export is a full copy of the
/// health record (often 100+ MB, plaintext unless encrypted), and nothing else
/// ever removed them, so every tap added one more.
const kSharedExportsKept = 2;

final _exportName = RegExp(r'^openstrap_export_(\d+)\.db(\.osbk)?$');

/// Delete all but the [keep] newest manual exports in [dir].
///
/// An export is identified by the millisecond stamp in its name, so the
/// plaintext `.db` and its `.osbk` count as one export. Files that do not
/// match the export name are left alone.
Future<void> pruneSharedExports(
  Directory dir, {
  int keep = kSharedExportsKept,
}) async {
  try {
    final byStamp = <int, List<File>>{};
    for (final f in dir.listSync().whereType<File>()) {
      final m = _exportName.firstMatch(p.basename(f.path));
      if (m == null) continue;
      byStamp.putIfAbsent(int.parse(m.group(1)!), () => []).add(f);
    }
    final stamps = byStamp.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final s in stamps.skip(keep)) {
      for (final f in byStamp[s]!) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  } catch (_) {
    // Housekeeping only — a failure here must never fail the export itself.
  }
}

/// Remove manual-export copies that earlier versions left in the temp root.
///
/// Before [sharedExportDir] existed, manual exports went straight into temp
/// and were never deleted. Other features still create (and delete) their own
/// snapshots there, so only files older than [minAge] are touched: an
/// in-flight snapshot is minutes old, a leaked one is not.
Future<void> pruneLegacyRootExports(
  Directory tmpRoot, {
  Duration minAge = const Duration(days: 1),
  DateTime? now,
}) async {
  try {
    final cutoff = (now ?? DateTime.now()).subtract(minAge);
    for (final f in tmpRoot.listSync().whereType<File>()) {
      if (!_exportName.hasMatch(p.basename(f.path))) continue;
      try {
        if (f.lastModifiedSync().isBefore(cutoff)) await f.delete();
      } catch (_) {}
    }
  } catch (_) {
    // Housekeeping only.
  }
}
