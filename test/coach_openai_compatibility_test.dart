import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';

Map<String, dynamic> _body(String model, {bool tools = true}) => {
  'model': model,
  'messages': [
    {'role': 'user', 'content': 'Hello'},
  ],
  'temperature': 0.3,
  if (tools) ...{
    'tools': [
      {
        'type': 'function',
        'function': {
          'name': 'lookup',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
    ],
    'tool_choice': 'auto',
  },
};

/// Inspect the serialized HTTP request rather than an internal policy helper.
Future<Map<String, dynamic>> _capture(
  CoachConfig config,
  Map<String, dynamic> body,
) async {
  Map<String, dynamic>? sent;
  final client = MockClient((request) async {
    expect(request.method, 'POST');
    expect(request.url.toString(), '${config.apiBase}/chat/completions');
    expect(request.headers.containsKey('authorization'), isFalse);
    sent = jsonDecode(request.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'Hello back'},
          },
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  try {
    final reply = await CoachEngine.postChat(config, body, client: client);
    expect(reply['content'], 'Hello back');
    return sent!;
  } finally {
    client.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('official OpenAI compatibility requests', () {
    for (final model in [
      'gpt-6-luna',
      'gpt-6-luna-2026-10-03',
      'gpt-5.6-terra',
      'gpt-5.6-terra-2026-08-11',
    ]) {
      for (final tools in [true, false]) {
        test(
          '$model sends none ${tools ? 'with tools' : 'for text only'}',
          () async {
            final body = _body(model, tools: tools);
            final sent = await _capture(CoachConfig(), body);
            expect(sent, {...body, 'reasoning_effort': 'none'});
          },
        );
      }
    }

    test(
      'overrides incompatible effort without mutating caller input',
      () async {
        final body = _body('gpt-6-luna')..['reasoning_effort'] = 'medium';
        final original = jsonDecode(jsonEncode(body));
        final sent = await _capture(CoachConfig(), body);
        expect(sent['reasoning_effort'], 'none');
        expect(body, original);
      },
    );

    test('normalizes a trailing slash on the official API base', () async {
      final config = CoachConfig();
      await config.save(baseUrl: 'https://api.openai.com/v1/');
      final sent = await _capture(config, _body('gpt-6-luna'));
      expect(sent['reasoning_effort'], 'none');
    });
  });

  group('unaffected OpenAI model requests', () {
    for (final model in [
      'gpt-4o-mini',
      'gpt-5.3',
      'gpt-5.6-sol',
      'gpt-6-astra',
      'gpt-6.1-sol',
      'gpt-6-luna-pro',
      'gpt-6-luna-custom',
      'gpt-6-luna-2026-10-03-preview',
      'gpt-6-luna-20261003',
      'gpt-5.6-terra-pro',
    ]) {
      test('$model retains the original request', () async {
        final body = _body(model);
        expect(await _capture(CoachConfig(), body), body);
      });
    }

    test(
      'retains caller-provided effort outside the supported model scope',
      () async {
        final body = _body('gpt-6-astra')..['reasoning_effort'] = 'high';
        expect(await _capture(CoachConfig(), body), body);
      },
    );
  });

  group('unaffected provider requests', () {
    for (final base in [
      'https://openrouter.ai/api/v1',
      'http://localhost:11434/v1',
      'http://192.168.1.2:1234/v1',
      'https://api.openai.com.example.com/v1',
      'https://evil-api.openai.com/v1',
      'https://proxy.api.openai.com/v1',
      'http://api.openai.com/v1',
      'https://api.openai.com:8443/v1',
    ]) {
      test('$base retains Luna and Terra requests', () async {
        final config = CoachConfig();
        await config.save(baseUrl: base);
        for (final model in ['gpt-6-luna', 'gpt-5.6-terra']) {
          final body = _body(model)..['reasoning_effort'] = 'medium';
          expect(await _capture(config, body), body);
        }
      });
    }

    test(
      'existing Claude sampling removal still reaches the HTTP request',
      () async {
        final config = CoachConfig();
        await config.save(baseUrl: 'https://openrouter.ai/api/v1');
        final body = _body('anthropic/claude-opus-4.8')
          ..['top_p'] = 0.9
          ..['top_k'] = 10;
        final expected = {...body}
          ..remove('temperature')
          ..remove('top_p')
          ..remove('top_k');
        expect(await _capture(config, body), expected);
        expect(body['temperature'], 0.3);
        expect(body['top_p'], 0.9);
        expect(body['top_k'], 10);
      },
    );
  });
}
