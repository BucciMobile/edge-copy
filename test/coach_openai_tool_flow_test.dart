import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRepo extends LocalRepository {}

// Flutter's test binding replaces HttpClient; this override's base factory
// creates a real client. The transport below sends only to our loopback server.
class _RealHttpOverrides extends HttpOverrides {}

class _LoopbackClient extends http.BaseClient {
  _LoopbackClient(this.endpoint)
    : _inner = IOClient(_RealHttpOverrides().createHttpClient(null));

  final Uri endpoint;
  final http.Client _inner;
  final destinations = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    destinations.add(request.url);
    final local =
        http.Request(request.method, endpoint.replace(path: request.url.path))
          ..headers.addAll(request.headers)
          ..bodyBytes = await request.finalize().toBytes();
    return _inner.send(local);
  }

  @override
  void close() => _inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final model in ['gpt-6-luna', 'gpt-5.6-terra']) {
    test('$model completes a real HTTP tool-call round trip', () async {
      final requests = <Map<String, dynamic>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final toolCall = {
        'id': 'call_render_1',
        'type': 'function',
        'function': {
          'name': 'render',
          'arguments': jsonEncode({
            'type': 'table',
            'title': 'Compatibility check',
            'columns': ['status'],
            'rows': [
              ['ok'],
            ],
          }),
        },
      };
      final subscription = server.listen((request) async {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        requests.add(body);
        final messages = (body['messages'] as List).cast<Map>();
        final continuationValid =
            requests.length == 1 ||
            (requests.length == 2 &&
                messages[messages.length - 2]['role'] == 'assistant' &&
                messages[messages.length - 2]['tool_calls'][0]['id'] ==
                    'call_render_1' &&
                messages.last['role'] == 'tool' &&
                messages.last['tool_call_id'] == 'call_render_1' &&
                messages.last['content'] == 'Rendered "table" for the user.');
        final valid =
            request.method == 'POST' &&
            request.uri.path == '/v1/chat/completions' &&
            request.headers.contentType?.mimeType == 'application/json' &&
            body['model'] == model &&
            body['reasoning_effort'] == 'none' &&
            body['tool_choice'] == 'auto' &&
            (body['tools'] as List).isNotEmpty &&
            continuationValid;
        request.response
          ..statusCode = valid ? 200 : 400
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(
              valid
                  ? {
                      'choices': [
                        {
                          'message': requests.length == 1
                              ? {
                                  'role': 'assistant',
                                  'content': null,
                                  'tool_calls': [toolCall],
                                }
                              : {
                                  'role': 'assistant',
                                  'content': 'The compatibility check passed.',
                                },
                        },
                      ],
                    }
                  : {
                      'error': {
                        'message': 'Invalid request or tool continuation',
                      },
                    },
            ),
          );
        await request.response.close();
      });
      addTearDown(subscription.cancel);

      final client = _LoopbackClient(
        Uri.parse('http://127.0.0.1:${server.port}'),
      );
      final config = CoachConfig();
      await config.save(model: model);
      addTearDown(config.dispose);
      final engine = CoachEngine(
        config: config,
        api: _FakeRepo(),
        client: client,
      );
      addTearDown(engine.dispose);
      final items = <CoachItem>[];
      final statuses = <String?>[];
      await engine.send(
        'Render a compatibility check table, then confirm it worked.',
        onItem: items.add,
        onStatus: statuses.add,
        confirm: (_) async => fail('A render must not request a write'),
      );

      expect(requests, hasLength(2));
      expect(
        client.destinations,
        everyElement(Uri.parse('https://api.openai.com/v1/chat/completions')),
      );
      final renderTool = (requests.first['tools'] as List)
          .cast<Map>()
          .singleWhere((tool) => (tool['function'] as Map)['name'] == 'render');
      expect(renderTool['type'], 'function');
      expect(
        renderTool['function']['parameters']['required'],
        contains('type'),
      );
      expect((requests.last['messages'] as List).last['name'], 'render');
      expect(items.map((item) => item.kind), [
        CoachItemKind.user,
        CoachItemKind.render,
        CoachItemKind.assistant,
      ]);
      expect(items[1].render?['title'], 'Compatibility check');
      expect(items.last.text, 'The compatibility check passed.');
      expect(statuses.last, isNull);
      expect(engine.debugHistory.last['content'], items.last.text);
    });
  }
}
