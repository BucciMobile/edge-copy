// "Report an issue": what goes in the archive, how it is built, sent and
// later deleted. The screen is lib/ui2/profile/report_issue.dart.
//
// ONE list of files ([reportPaths]) feeds the archive's manifest.json AND the
// "What's included" section, so the two cannot say different things. Each
// file's description is an ARB string: the manifest uses the English text,
// the screen the user's language.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../compute/derivation_engine.dart' show kAlgoVersion;
import '../data/db.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../sync/file_log.dart';
import '../telemetry/telemetry_service.dart';

/// The report service. One constant; the Worker answers under /v1.
const String kReportBaseUrl = 'https://reports.openstrap.site';

/// Server limits (bytes of the sealed blob). UPLOAD limits only: a local
/// share has no size cap.
const int kReportMaxBytes = 2 * 1024 * 1024;
const int kReportMaxBytesWithDb = 15 * 1024 * 1024;

/// Recent logs ride along up to this many bytes (they zip about 10:1).
const int kReportLogBytes = 1500 * 1024;

enum ReportCategory { sync, sleep, recovery, workout, pairing, other }

/// Every file in the archive, in order. [screenshotExt] is the picked image's
/// extension ("png", "jpg"), null when no screenshot is attached.
List<String> reportPaths({String? screenshotExt, bool database = false}) => [
      'manifest.json',
      'meta.json',
      'device.json',
      'state.json',
      'logs/sync.log',
      'logs/telemetry.json',
      'user.txt',
      if (screenshotExt != null) 'screenshot.$screenshotExt',
      if (database) 'database.db.gz',
    ];

/// One plain line per file, in [l]'s language.
String describeReportFile(AppLocalizations l, String path) => switch (path) {
      'manifest.json' => l.reportFileManifest,
      'meta.json' => l.reportFileMeta,
      'device.json' => l.reportFileDevice,
      'state.json' => l.reportFileState,
      'logs/sync.log' => l.reportFileSyncLog,
      'logs/telemetry.json' => l.reportFileTelemetry,
      'user.txt' => l.reportFileUser,
      'database.db.gz' => l.reportFileDatabase,
      _ => l.reportFileScreenshot,
    };

/// What the user typed and picked.
class ReportDraft {
  final ReportCategory category;
  final String title, description;
  final String? screenshotPath;
  final bool includeDatabase;
  const ReportDraft({
    required this.category,
    required this.title,
    required this.description,
    this.screenshotPath,
    this.includeDatabase = false,
  });

  String? get screenshotExt {
    final s = screenshotPath;
    if (s == null) return null;
    final dot = s.lastIndexOf('.');
    final ext = dot < 0 ? '' : s.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext) ? ext : 'img';
  }
}

/// The archive, from already-gathered parts. Pure: the tests call it directly.
/// [meta], [device] and [state] become JSON files; [syncLog] is UTF-8 text.
Uint8List buildReportZip({
  required ReportDraft draft,
  required Map<String, Object?> meta,
  required Map<String, Object?> device,
  required Map<String, Object?> state,
  required String syncLog,
  required List<Map<String, dynamic>> telemetry,
  Uint8List? screenshot,
  Uint8List? databaseGz,
}) {
  final en = lookupAppLocalizations(const Locale('en'));
  final paths = reportPaths(
      screenshotExt: screenshot == null ? null : draft.screenshotExt,
      database: databaseGz != null);
  const pretty = JsonEncoder.withIndent('  ');
  final bodies = <String, List<int>>{
    'manifest.json': utf8.encode(pretty.convert({
      'v': 1,
      'files': [
        for (final p in paths) {'path': p, 'description': describeReportFile(en, p)}
      ],
    })),
    'meta.json': utf8.encode(pretty.convert(meta)),
    'device.json': utf8.encode(pretty.convert(device)),
    'state.json': utf8.encode(pretty.convert(state)),
    'logs/sync.log': utf8.encode(syncLog),
    'logs/telemetry.json': utf8.encode(pretty.convert(telemetry)),
    'user.txt': utf8.encode('Category: ${draft.category.name}\n'
        'Title: ${draft.title}\n\n${draft.description}\n'),
    'screenshot.${draft.screenshotExt}': ?screenshot,
    'database.db.gz': ?databaseGz,
  };
  final archive = Archive();
  for (final p in paths) {
    archive.addFile(ArchiveFile.bytes(p, bodies[p]!));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// The plaintext `meta` field the Worker shows in the tracker. Nothing in it
/// is health data.
Map<String, Object?> reportServerMeta(
        ReportDraft d, Map<String, Object?> meta) =>
    {
      'v': 1,
      'installId': meta['installId'],
      'category': d.category.name,
      'title': _clip(d.title, 120),
      'description': _clip(d.description, 4000),
      'appVersion': meta['appVersion'],
      'platform': meta['platform'],
      'osVersion': meta['osVersion'],
      'deviceModel': meta['deviceModel'],
      'hasDatabase': d.includeDatabase,
      'hasScreenshot': d.screenshotPath != null,
    };

String _clip(String s, int n) => s.length <= n ? s : s.substring(0, n);

String? _iso(DateTime? t) => t?.toUtc().toIso8601String();

/// The steps [collectReport] reports, in order (the database step only runs
/// when it is attached).
enum ReportStage { collecting, logs, database, packing }

/// Gzip [path], reading it from disk in chunks (the raw file is never held in
/// memory). No size cap: callers that upload check the result themselves.
Future<Uint8List> gzipFile(String path) async {
  final out = BytesBuilder(copy: false);
  await for (final c in File(path).openRead().transform(gzip.encoder)) {
    out.add(c);
  }
  return out.takeBytes();
}

/// Gather everything from the running app and build the archive. No size
/// limit here; the upload path enforces [kReportMaxBytes] and
/// [kReportMaxBytesWithDb].
///
/// ponytail: the compressed database and the zip are held in memory; a
/// multi-hundred-MB database would need a streamed zip to a temp file.
Future<({Uint8List zip, Map<String, Object?> meta})> collectReport(
    AppState app, ReportDraft draft,
    {void Function(ReportStage)? onStage}) async {
  onStage?.call(ReportStage.collecting);
  final t = TelemetryService.instance;
  final s = await t.staticDevice();
  final now = DateTime.now();
  final build = s['app_build'];
  final meta = <String, Object?>{
    'appVersion': '${s['app_version'] ?? '?'}${build == null ? '' : '+$build'}',
    'algoVersion': kAlgoVersion,
    'schemaVersion': LocalDb.schemaVersion,
    'platform': s['platform'] ?? Platform.operatingSystem,
    'osVersion': s['os_version'] ?? Platform.operatingSystemVersion,
    'deviceModel': s['model'],
    'deviceMaker': s['oem'],
    'locale': Platform.localeName,
    'timezone': now.timeZoneName,
    'tzOffsetMinutes': now.timeZoneOffset.inMinutes,
    'installId': app.deviceId,
    'createdAt': _iso(now),
  };
  final d = app.device;
  final device = <String, Object?>{
    'band': {
      'paired': app.isPaired,
      'generation': app.paired?.generation ?? d.generation,
      'connection': d.connection,
      'batteryPct': d.batteryPct,
      'charging': d.charging,
      'batteryPackPct': d.batteryPackPct,
      'wristOn': d.wristOn,
      'lastSyncedRecord': app.lastSynced?.tsEpoch,
      'bandDataOldest': d.dataRangeOldest,
      'bandDataNewest': d.dataRangeNewest,
      // Firmware is not held in app state; the HELLO lines in logs/sync.log
      // carry it.
    },
    'sensors': [
      for (final r in app.sensors)
        {
          for (final k in const [
            'adapter_id', 'label', 'tier', 'role', 'wearing',
            'first_seen', 'last_seen'
          ])
            k: r[k],
        }
    ],
  };
  final weekAgo = now.millisecondsSinceEpoch ~/ 1000 - 7 * 86400;
  final records = [
    for (final r in t.outboxSnapshot)
      if ((r['ts'] as int? ?? 0) >= weekAgo) r
  ];
  final state = <String, Object?>{
    'syncStatus': app.status,
    'syncingNow': app.syncingNow,
    'busy': app.busy,
    'lastDataAt': _iso(app.lastDataAt),
    'lastRecordAt': _iso(app.lastRecordAt),
    'deriving': app.deriving,
    'derivePending': app.derivePending,
    'standardHrFallback': d.standardHrFallback,
    'needsRepairGuide': d.needsRepairGuide,
    'bondRefusals': d.bondRefusals,
    'autoReconnectPaused': d.autoReconnectPaused,
    'syncClockLost': d.syncClockLost,
    'strapNeedsReboot': d.strapNeedsReboot,
    'syncChunkQuarantined': d.syncChunkQuarantined,
    'initError': app.initError,
    'importRollupError': app.importRollupError,
    'lastBackupError': app.lastBackupError,
    'recentErrors': [
      for (final r in records)
        if (r['kind'] == 'error' || r['kind'] == 'crash') r
    ].reversed.take(20).toList(),
  };
  onStage?.call(ReportStage.logs);
  final syncLog = await _recentLog();
  final shot = draft.screenshotPath == null
      ? null
      : await File(draft.screenshotPath!).readAsBytes();
  Uint8List? dbGz;
  if (draft.includeDatabase) {
    onStage?.call(ReportStage.database);
    // The existing export path: a VACUUM INTO snapshot, not a file copy.
    final path = await LocalDb.exportCopy(includeSubstrateArchive: false);
    try {
      dbGz = await gzipFile(path);
    } finally {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }
  onStage?.call(ReportStage.packing);
  final zip = buildReportZip(
    draft: draft,
    meta: meta,
    device: device,
    state: state,
    syncLog: syncLog,
    telemetry: records,
    screenshot: shot,
    databaseGz: dbGz,
  );
  return (zip: zip, meta: meta);
}

/// The newest [kReportLogBytes] of the sync log, across its one rotation.
///
/// ponytail: capped by size, not by a 7-day cut; the log lines carry no
/// parseable date, and 1.5 MB is already well past a week of normal syncing.
Future<String> _recentLog() async {
  final path = await FileLog.path();
  if (path == null) return '';
  final parts = <List<int>>[];
  var left = kReportLogBytes;
  for (final f in [File(path), File('$path.1')]) {
    if (left <= 0) break;
    try {
      if (!await f.exists()) continue;
      final b = await f.readAsBytes();
      final take = b.length < left ? b.length : left;
      parts.insert(0, b.sublist(b.length - take));
      left -= take;
    } catch (_) {}
  }
  return utf8.decode(parts.expand((e) => e).toList(), allowMalformed: true);
}

/// A report the Worker accepted, kept on this phone so it can be deleted.
class SentReport {
  final String id, deleteToken;
  final DateTime expiresAt;
  const SentReport(this.id, this.deleteToken, this.expiresAt);

  Map<String, Object?> toJson() => {
        'id': id,
        'deleteToken': deleteToken,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };

  static SentReport fromJson(Map<String, dynamic> j) => SentReport(
      j['id'] as String,
      j['deleteToken'] as String,
      DateTime.parse(j['expiresAt'] as String));
}

/// A non-201 answer. [status] 0 means the request never got an answer.
class ReportSendError implements Exception {
  final int status;
  final String? error;
  const ReportSendError(this.status, [this.error]);
  @override
  String toString() => 'ReportSendError($status${error == null ? '' : ', $error'})';
}

/// POST the sealed archive. Throws [ReportSendError] on anything but 201.
Future<SentReport> sendReport(Map<String, Object?> serverMeta, Uint8List blob,
    {http.Client? client}) async {
  final req = http.MultipartRequest('POST', Uri.parse('$kReportBaseUrl/v1/reports'))
    ..fields['meta'] = jsonEncode(serverMeta)
    ..files.add(http.MultipartFile.fromBytes('blob', blob,
        filename: 'report.osr1'));
  final c = client ?? http.Client();
  try {
    final res = await http.Response.fromStream(
        await c.send(req).timeout(const Duration(seconds: 90)));
    if (res.statusCode != 201) {
      String? err;
      try {
        err = (jsonDecode(res.body) as Map)['error'] as String?;
      } catch (_) {}
      throw ReportSendError(res.statusCode, err);
    }
    final sent = SentReport.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
    // The Worker has the report: a local bookkeeping failure must not look
    // like a failed send (a retry would burn another daily slot).
    try {
      await _store([...await loadSentReports(), sent]);
    } catch (_) {}
    return sent;
  } on ReportSendError {
    rethrow;
  } catch (e) {
    throw ReportSendError(0, '$e');
  } finally {
    if (client == null) c.close();
  }
}

/// DELETE a report this phone sent. A 404 counts as gone (it expired).
Future<void> deleteReport(SentReport r, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    final res = await c.delete(Uri.parse('$kReportBaseUrl/v1/reports/${r.id}'),
        headers: {'X-Delete-Token': r.deleteToken}).timeout(
        const Duration(seconds: 30));
    if (res.statusCode != 204 && res.statusCode != 404) {
      throw ReportSendError(res.statusCode);
    }
  } on ReportSendError {
    rethrow;
  } catch (e) {
    throw ReportSendError(0, '$e');
  } finally {
    if (client == null) c.close();
  }
  await _store([
    for (final s in await loadSentReports())
      if (s.id != r.id) s
  ]);
}

const String _kSentReports = 'issue_reports_sent';

/// Reports sent from this phone that have not expired yet, newest last.
Future<List<SentReport>> loadSentReports() async {
  final prefs = await SharedPreferences.getInstance();
  final now = DateTime.now();
  try {
    final list = jsonDecode(prefs.getString(_kSentReports) ?? '[]') as List;
    return [
      for (final e in list)
        if (SentReport.fromJson((e as Map).cast()).expiresAt.isAfter(now))
          SentReport.fromJson(e.cast())
    ];
  } catch (_) {
    return [];
  }
}

Future<void> _store(List<SentReport> list) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      _kSentReports, jsonEncode([for (final s in list) s.toJson()]));
}
