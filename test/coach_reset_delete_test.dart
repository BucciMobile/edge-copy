import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _DocumentsProvider extends PathProviderPlatform {
  _DocumentsProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  test('deleteAllSavedSessions removes every coach chat file and nothing else',
      () async {
    final dir = await Directory.systemTemp.createTemp('coach-reset-');
    final original = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _DocumentsProvider(dir.path);
    addTearDown(() async {
      PathProviderPlatform.instance = original;
      await dir.delete(recursive: true);
    });

    final chats = [
      'coach_s_local_1700000000000.json',
      'coach_s_local_1700000000001.json',
      'coach_idx_local.json',
      'coach_s_other_1.json',
      'coach_idx_other.json',
    ];
    final keep = ['edge_sync.log', 'coach_notes.txt', 'backup.json'];
    for (final n in [...chats, ...keep]) {
      await File('${dir.path}/$n').writeAsString('{}');
    }

    expect(await CoachEngine.deleteAllSavedSessions(), 0);

    for (final n in chats) {
      expect(await File('${dir.path}/$n').exists(), isFalse, reason: n);
    }
    for (final n in keep) {
      expect(await File('${dir.path}/$n').exists(), isTrue, reason: n);
    }
  });
}
