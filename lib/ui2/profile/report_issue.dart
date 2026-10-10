// Report an issue: category, title, what happened, an optional screenshot and
// an optional database. Sent only when the user taps Send, sealed on the phone
// (lib/support/report_crypto.dart). "Save instead" writes the same archive to
// the share sheet with no network at all.

import 'dart:io';
import 'dart:isolate';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../support/issue_report.dart';
import '../../support/report_crypto.dart';
import '../activity/share.dart' show shareOrigin;
import '../ui2.dart';
import 'profile.dart';

class ReportIssueScreen extends StatefulWidget {
  const ReportIssueScreen({super.key});

  @override
  State<ReportIssueScreen> createState() => _ReportIssueScreenState();
}

class _ReportIssueScreenState extends State<ReportIssueScreen> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  ReportCategory _category = ReportCategory.other;
  String? _shot;
  bool _db = false; // OFF by default: it is the user's whole health record
  bool _busy = false;
  SentReport? _sent;
  int? _error; // HTTP status of a failed send, 0 = no answer, -1 = no title, -2 = save failed
  List<SentReport> _reports = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final r = await loadSentReports();
    if (mounted) setState(() => _reports = r);
  }

  ReportDraft _draft() => ReportDraft(
        category: _category,
        title: _title.text.trim(),
        description: _body.text.trim(),
        screenshotPath: _shot,
        includeDatabase: _db,
      );

  Future<void> _send() async {
    if (_title.text.trim().isEmpty) {
      setState(() => _error = -1);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _sent = null;
    });
    try {
      final draft = _draft();
      final r = await collectReport(context.read<AppState>(), draft);
      final zip = r.zip;
      final blob = await Isolate.run(() => osr1Encrypt(zip));
      if (blob.length >
          (draft.includeDatabase ? kReportMaxBytesWithDb : kReportMaxBytes)) {
        throw const ReportSendError(413);
      }
      final sent = await sendReport(reportServerMeta(draft, r.meta), blob);
      if (mounted) setState(() => _sent = sent);
      await _reload();
    } on ReportSendError catch (e) {
      if (mounted) setState(() => _error = e.status);
    } catch (_) {
      if (mounted) setState(() => _error = 0);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final origin = shareOrigin(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await collectReport(context.read<AppState>(), _draft());
      final dir = await getTemporaryDirectory();
      final f = File(
          '${dir.path}/openstrap_report_${DateTime.now().millisecondsSinceEpoch}.zip');
      await f.writeAsBytes(r.zip);
      await Share.shareXFiles([XFile(f.path)],
          subject: 'OpenStrap issue report', sharePositionOrigin: origin);
    } catch (e) {
      if (mounted) setState(() => _error = e is ReportSendError ? e.status : -2);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickShot() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = picked?.files.single.path;
    if (path != null && mounted) setState(() => _shot = path);
  }

  Future<void> _delete(SentReport r) async {
    final l = _l(context);
    final messenger = ScaffoldMessenger.of(context);
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await deleteReport(r);
      await _reload();
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(l.reportDeleteFailed)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static AppLocalizations _l(BuildContext c) =>
      AppLocalizations.of(c) ?? lookupAppLocalizations(const Locale('en'));

  String _why(AppLocalizations l, int status) => switch (status) {
        -1 => l.reportNeedTitle,
        413 => l.reportTooLarge,
        429 => l.reportRateLimited,
        507 => l.reportStorageFull,
        _ => l.reportSendFailed,
      };

  Widget _field(BuildContext c, TextEditingController ctl, String label,
      String hint, {int lines = 1, int? max}) {
    final p = P.of(c);
    return Padding(
      padding: const EdgeInsets.only(bottom: S.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: F.over.copyWith(color: p.ink3)),
        TextField(
          controller: ctl,
          minLines: lines,
          maxLines: lines == 1 ? 1 : null,
          maxLength: max,
          style: F.body.copyWith(color: p.ink),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: F.body.copyWith(color: p.ink3),
            isDense: true,
            counterText: '',
            contentPadding: const EdgeInsets.symmetric(vertical: S.x3),
            enabledBorder:
                UnderlineInputBorder(borderSide: BorderSide(color: p.line)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: p.on(C.green))),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = _l(c);
    final draft = _draft();
    final names = {
      ReportCategory.sync: l.reportCategorySync,
      ReportCategory.sleep: l.reportCategorySleep,
      ReportCategory.recovery: l.reportCategoryRecovery,
      ReportCategory.workout: l.reportCategoryWorkout,
      ReportCategory.pairing: l.reportCategoryPairing,
      ReportCategory.other: l.reportCategoryOther,
    };
    final err = _error;
    final sent = _sent;
    final date = MaterialLocalizations.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: NavBar(l.reportNavTitle),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x10),
              children: [
                Text(l.reportCategoryGroup,
                    style: F.over.copyWith(color: p.ink3)),
                const SizedBox(height: S.x2),
                Wrap(spacing: S.x2, runSpacing: S.x2, children: [
                  for (final e in names.entries)
                    Pressable(
                      onTap: () => setState(() => _category = e.key),
                      semanticLabel: e.value,
                      child: Pill(e.value,
                          e.key == _category ? C.green : C.n500,
                          icon: e.key == _category ? LucideIcons.check : null),
                    ),
                ]),
                const SizedBox(height: S.x5),
                _field(c, _title, l.reportTitleLabel, l.reportTitleHint,
                    max: 120),
                _field(c, _body, l.reportDescriptionLabel,
                    l.reportDescriptionHint,
                    lines: 4, max: 4000),
                settingsGroup(c, l.reportAttachGroup, [
                  SetRow(LucideIcons.image, C.blue,
                      _shot == null
                          ? l.reportScreenshotRow
                          : l.reportScreenshotRemove,
                      sub: _shot?.split(Platform.pathSeparator).last ?? '',
                      onTap: _busy
                          ? null
                          : _shot == null
                              ? _pickShot
                              : () => setState(() => _shot = null)),
                  SetRow(LucideIcons.database, C.red, l.reportDatabaseRow,
                      sub: l.reportDatabaseWarning,
                      value: _db ? l.stateOn : l.stateOff,
                      chevron: false,
                      onTap: _busy ? null : () => setState(() => _db = !_db)),
                ]),
                const SizedBox(height: S.x5),
                settingsGroup(c, l.reportIncludedGroup, [
                  for (final path in reportPaths(
                      screenshotExt: draft.screenshotExt,
                      database: draft.includeDatabase))
                    SetRow(LucideIcons.fileText, C.n500, path,
                        sub: describeReportFile(l, path), chevron: false),
                ]),
                const SizedBox(height: S.x2),
                Text(l.reportIncludedNote,
                    style: F.cap.copyWith(color: p.ink2, height: 1.5)),
                const SizedBox(height: S.x5),
                BigButton(l.reportSend,
                    icon: LucideIcons.send, onTap: _busy ? null : _send),
                const SizedBox(height: S.x3),
                BigButton(l.reportSaveInstead,
                    icon: LucideIcons.download,
                    soft: true,
                    onTap: _busy ? null : _save),
                if (_busy) ...[
                  const SizedBox(height: S.x6),
                  Center(child: CircularProgressIndicator(color: p.on(C.blue))),
                ],
                if (sent != null) ...[
                  const SizedBox(height: S.x5),
                  StatusCard(l.reportSentTitle, l.reportSentBody(sent.id),
                      icon: LucideIcons.check,
                      fix: l.reportCopyId,
                      onFix: () =>
                          Clipboard.setData(ClipboardData(text: sent.id))),
                ],
                if (err != null) ...[
                  const SizedBox(height: S.x5),
                  StatusCard(
                      err == -2 ? l.reportSaveFailedTitle : l.reportNotSentTitle,
                      err == -2 ? l.reportSaveFailedBody : _why(l, err),
                      icon: LucideIcons.triangleAlert,
                      fix: err == -1
                          ? ''
                          : err == -2
                              ? l.reportSaveRetry
                              : err == 507
                                  ? l.reportSendWithoutDb
                                  : l.reportSaveInstead,
                      onFix: err == -1
                          ? null
                          : err == 507
                              ? () {
                                  setState(() => _db = false);
                                  _send();
                                }
                              : _save),
                ],
                if (_reports.isNotEmpty) ...[
                  const SizedBox(height: S.x5),
                  settingsGroup(c, l.reportMyReportsGroup, [
                    for (final r in _reports.reversed)
                      SetRow(LucideIcons.fileText, C.n500, r.id,
                          sub: l.reportMyReportsSub(
                              date.formatMediumDate(r.expiresAt.toLocal())),
                          value: l.reportDelete,
                          chevron: false,
                          onTap: _busy ? null : () => _delete(r)),
                  ]),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
