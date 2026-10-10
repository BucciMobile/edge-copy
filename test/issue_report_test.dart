// Report an issue: the OSR1 seal, the archive's manifest, and the screen's
// defaults.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/support/issue_report.dart';
import 'package:openstrap_edge/support/report_crypto.dart';
import 'package:openstrap_edge/ui2/profile/report_issue.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

Uint8List _zip({bool shot = false, bool db = false}) => buildReportZip(
      draft: ReportDraft(
        category: ReportCategory.sync,
        title: 'Sync stuck',
        description: 'It never finishes',
        screenshotPath: shot ? '/tmp/x/Shot.PNG' : null,
        includeDatabase: db,
      ),
      meta: {'installId': '00000000-0000-4000-8000-000000000000'},
      device: {'band': {}},
      state: {'syncStatus': 'idle'},
      syncLog: 'line one\n',
      telemetry: const [],
      screenshot: shot ? Uint8List.fromList([1, 2, 3]) : null,
      databaseGz: db ? Uint8List.fromList([4, 5]) : null,
    );

void main() {
  group('OSR1', () {
    test('layout against the shipped public key', () {
      final plain = Uint8List.fromList(utf8.encode('hello report'));
      final blob = osr1Encrypt(plain);
      expect(String.fromCharCodes(blob.sublist(0, 4)), 'OSR1');
      expect(blob[4], 0x04, reason: 'uncompressed P-256 point');
      expect(blob.length, 4 + 65 + 12 + plain.length + 16);
      // Fresh ephemeral key and nonce every time.
      expect(osr1Encrypt(plain).sublist(4, 81), isNot(blob.sublist(4, 81)));
    });

    test('round trip with a test keypair; a flipped byte fails the tag', () {
      final pair = osr1TestKeyPair();
      final pub = (pair.publicKey as ECPublicKey).Q!.getEncoded(false);
      final priv = pair.privateKey as ECPrivateKey;
      final plain = _zip();
      final blob = osr1Encrypt(plain, publicKeyB64: base64Encode(pub));
      expect(osr1Decrypt(blob, priv), plain);
      final bad = Uint8List.fromList(blob)..[blob.length - 1] ^= 1;
      expect(() => osr1Decrypt(bad, priv), throwsA(anything));
    });
  });

  test('manifest lists exactly the files in the archive, same as the screen',
      () {
    for (final (shot, db) in [(false, false), (true, false), (true, true)]) {
      final a = ZipDecoder().decodeBytes(_zip(shot: shot, db: db));
      final manifest = jsonDecode(
              utf8.decode(a.findFile('manifest.json')!.content as List<int>))
          as Map<String, dynamic>;
      final listed = [
        for (final f in manifest['files'] as List) (f as Map)['path'] as String
      ];
      final expected =
          reportPaths(screenshotExt: shot ? 'png' : null, database: db);
      expect(listed, expected);
      expect([for (final f in a.files) f.name], expected);
      for (final f in manifest['files'] as List) {
        expect((f as Map)['description'], isNotEmpty);
      }
    }
    // No health data unless the database is ticked.
    expect(reportPaths(), isNot(contains('database.db.gz')));
  });

  testWidgets('database switch is off and the list matches the manifest',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390 * 3, 3000 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const ReportIssueScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Include my health database'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('On'), findsNothing);
    for (final path in reportPaths()) {
      expect(find.text(path), findsOneWidget, reason: path);
    }
    expect(find.text('database.db.gz'), findsNothing);

    await tester.tap(find.text('Include my health database'));
    await tester.pumpAndSettle();
    expect(find.text('On'), findsOneWidget);
    expect(find.text('database.db.gz'), findsOneWidget);
  });
}
