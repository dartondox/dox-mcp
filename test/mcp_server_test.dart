import 'dart:convert';

import 'package:dox_core/dox_core.dart';
import 'package:dox_core/testing.dart';
import 'package:dox_mcp/dox_mcp.dart';
import 'package:test/test.dart';

/// Adds two numbers. Reads the user from `auth`.
class AddTool extends McpTool {
  @override
  String get name => 'add';

  @override
  String get description => 'Add two numbers.';

  @override
  ObjectSchema get input => v.object(<String, Schema<Object?>>{
    'a': v.num().describe('The first number.'),
    'b': v.num(),
  });

  @override
  Map<String, dynamic>? get annotations => <String, dynamic>{
    'readOnlyHint': true,
  };

  @override
  McpToolResult call(Map<String, dynamic> args, McpContext context) {
    num sum = (args['a'] as num) + (args['b'] as num);
    return McpToolResult.text('${context.auth}: $sum');
  }
}

final McpServer mcp = McpServer(
  name: 'test-server',
  version: '1.2.3',
  title: 'Test',
  instructions: 'Use add.',
  sessions: SignedMcpSessions(key: utf8.encode('k' * 32)),
  tools: <McpTool>[
    AddTool(),
    McpTool.of(
      name: 'boom',
      description: 'Always fails.',
      handler: (Map<String, dynamic> args, McpContext context) {
        throw StateError('broken');
      },
    ),
  ],
);

class TestRouter extends Router {
  @override
  void register() {
    // the user comes from the URL here; an app reads its own auth
    Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp/{user}', (
      DoxRequest req,
    ) {
      String user = '${req.param['user']}';
      return mcp.handle(req, auth: user, scope: user);
    });
  }
}

void main() {
  late DoxTestClient client;
  Map<String, String> json = <String, String>{
    'content-type': 'application/json',
    'accept': 'application/json, text/event-stream',
  };

  setUpAll(() async {
    client = await DoxTestClient.start(
      AppConfig(
        appKey: 'mcp-test-key-0123456789abcdef!!!',
        routers: <Router>[TestRouter()],
      ),
    );
  });

  tearDownAll(() async {
    await client.close();
  });

  Future<TestResponse> post(
    String user,
    Object? body, {
    String? session,
    String? protocol,
  }) {
    return client.post(
      '/mcp/$user',
      headers: <String, String>{
        ...json,
        'mcp-session-id': ?session,
        'mcp-protocol-version': ?protocol,
      },
      body: jsonEncode(body),
    );
  }

  Map<String, dynamic> request(int id, String method, [Object? params]) {
    return <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
    };
  }

  Future<String> initialize(
    String user, [
    String version = '2025-06-18',
  ]) async {
    TestResponse res = await post(
      user,
      request(1, 'initialize', <String, dynamic>{
        'protocolVersion': version,
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{'name': 'test', 'version': '1'},
      }),
    );
    res.expectStatus(200);
    return res.header('mcp-session-id')!;
  }

  group('initialize', () {
    test('answers with the server info and a session id', () async {
      TestResponse res = await post(
        'ann',
        request(1, 'initialize', <String, dynamic>{
          'protocolVersion': '2025-06-18',
        }),
      );
      res.expectStatus(200).expectJson(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'result': <String, dynamic>{
          'protocolVersion': '2025-06-18',
          'capabilities': <String, dynamic>{
            'tools': <String, dynamic>{'listChanged': false},
          },
          'serverInfo': <String, dynamic>{
            'name': 'test-server',
            'version': '1.2.3',
            'title': 'Test',
          },
          'instructions': 'Use add.',
        },
      });
      expect(
        res.header('mcp-session-id'),
        matches(RegExp(r'^[\w-]+\.[\w-]+$')),
      );
    });

    test('an unknown protocol version gets the newest one', () async {
      TestResponse res = await post(
        'ann',
        request(1, 'initialize', <String, dynamic>{
          'protocolVersion': '1999-01-01',
        }),
      );
      expect(
        res.json['result']['protocolVersion'],
        McpServer.protocolVersions.first,
      );
    });

    test('initialize must be alone in a batch', () async {
      TestResponse res = await post('ann', <Object>[
        request(1, 'initialize'),
        request(2, 'ping'),
      ]);
      res.expectStatus(400);
      expect(res.json['error']['code'], JsonRpcCode.invalidRequest);
    });
  });

  group('sessions', () {
    test('a request needs a valid session of the same scope', () async {
      String session = await initialize('ann');
      (await post('ann', request(2, 'ping'))).expectStatus(400);
      (await post(
        'ann',
        request(2, 'ping'),
        session: '${session}x',
      )).expectStatus(404);
      (await post(
        'bob',
        request(2, 'ping'),
        session: session,
      )).expectStatus(404);
      (await post(
        'ann',
        request(2, 'ping'),
        session: session,
      )).expectStatus(200).expectJson(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 2,
        'result': <String, dynamic>{},
      });
    });

    test('a session made by another server with the same key works', () async {
      McpSessions other = SignedMcpSessions(key: utf8.encode('k' * 32));
      String session = other.create('ann');
      (await post(
        'ann',
        request(2, 'ping'),
        session: session,
      )).expectStatus(200);
      McpSessions wrongKey = SignedMcpSessions(key: utf8.encode('x' * 32));
      (await post(
        'ann',
        request(2, 'ping'),
        session: wrongKey.create('ann'),
      )).expectStatus(404);
    });

    test('an unsupported protocol header is a 400', () async {
      String session = await initialize('ann');
      (await post(
        'ann',
        request(2, 'ping'),
        session: session,
        protocol: '1999-01-01',
      )).expectStatus(400);
    });

    test('DELETE ends the session; GET has no stream', () async {
      String session = await initialize('ann');
      (await client.get(
        '/mcp/ann',
        headers: <String, String>{'mcp-session-id': session},
      )).expectStatus(405).expectHeader('allow', 'POST, DELETE');
      (await client.delete(
        '/mcp/ann',
        headers: <String, String>{'mcp-session-id': session},
      )).expectStatus(200);
      (await client.delete('/mcp/ann')).expectStatus(400);
    });

    test('ended ids are refused when a store remembers them', () async {
      Dox().cache = CacheManager(
        CacheConfig(
          defaultStore: 'memory',
          stores: <String, Map<String, dynamic>>{
            'memory': <String, dynamic>{'driver': 'memory'},
          },
        ),
      );
      SignedMcpSessions sessions = SignedMcpSessions(
        key: utf8.encode('k' * 32),
        ended: Cache(),
      );
      String id = sessions.create('ann');
      expect(await sessions.isValid(id, 'ann'), isTrue);
      await sessions.end(id);
      expect(await sessions.isValid(id, 'ann'), isFalse);
    });
  });

  group('messages', () {
    late String session;

    setUpAll(() async {
      session = await initialize('ann');
    });

    test('tools/list gives each tool with its JSON Schema', () async {
      TestResponse res = await post(
        'ann',
        request(2, 'tools/list'),
        session: session,
      );
      List<dynamic> tools = res.json['result']['tools'] as List<dynamic>;
      expect(tools, hasLength(2));
      expect(tools.first['name'], 'add');
      expect(tools.first['annotations'], <String, dynamic>{
        'readOnlyHint': true,
      });
      Map<String, dynamic> schema =
          tools.first['inputSchema'] as Map<String, dynamic>;
      expect(schema['type'], 'object');
      expect(schema['required'], <String>['a', 'b']);
      expect(
        schema['properties']['a'],
        containsPair('description', 'The first number.'),
      );
      expect(tools.last['inputSchema'], <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      });
    });

    test('tools/call runs the tool with auth', () async {
      TestResponse res = await post(
        'ann',
        request(3, 'tools/call', <String, dynamic>{
          'name': 'add',
          'arguments': <String, dynamic>{'a': 2, 'b': 3.5},
        }),
        session: session,
      );
      expect(res.json['result'], <String, dynamic>{
        'content': <dynamic>[
          <String, dynamic>{'type': 'text', 'text': 'ann: 5.5'},
        ],
      });
    });

    test('bad arguments and a failing tool are error results', () async {
      TestResponse bad = await post(
        'ann',
        request(4, 'tools/call', <String, dynamic>{
          'name': 'add',
          'arguments': <String, dynamic>{'a': 'x'},
        }),
        session: session,
      );
      expect(bad.json['result']['isError'], isTrue);
      expect(
        bad.json['result']['content'][0]['text'],
        startsWith(
          'Input validation error: Invalid arguments for tool add: a:',
        ),
      );

      TestResponse boom = await post(
        'ann',
        request(5, 'tools/call', <String, dynamic>{'name': 'boom'}),
        session: session,
      );
      expect(boom.json['result'], <String, dynamic>{
        'content': <dynamic>[
          <String, dynamic>{'type': 'text', 'text': 'Bad state: broken'},
        ],
        'isError': true,
      });
    });

    test('an unknown tool or method is a JSON-RPC error', () async {
      TestResponse tool = await post(
        'ann',
        request(6, 'tools/call', <String, dynamic>{'name': 'nope'}),
        session: session,
      );
      expect(tool.json['error'], <String, dynamic>{
        'code': JsonRpcCode.invalidParams,
        'message': 'Tool nope not found',
      });
      TestResponse method = await post(
        'ann',
        request(7, 'resources/list'),
        session: session,
      );
      expect(method.json['error']['code'], JsonRpcCode.methodNotFound);
    });

    test('a batch gets a list; notifications get 202', () async {
      TestResponse batch = await post('ann', <Object>[
        request(8, 'ping'),
        <String, dynamic>{'jsonrpc': '2.0', 'method': 'notifications/x'},
        request(9, 'ping'),
      ], session: session);
      expect(
        <Object?>[for (dynamic r in batch.json as List<dynamic>) r['id']],
        <int>[8, 9],
      );
      (await post('ann', <String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }, session: session)).expectStatus(202).expectBody('');
    });

    test('bad JSON, bad messages and other content types', () async {
      TestResponse parse = await client.post(
        '/mcp/ann',
        headers: json,
        body: '{nope',
      );
      parse.expectStatus(400);
      expect(parse.json['error']['code'], JsonRpcCode.parseError);
      (await post('ann', <String, dynamic>{'id': 1})).expectStatus(400);
      (await client.post(
        '/mcp/ann',
        headers: <String, String>{'content-type': 'text/plain'},
        body: 'hi',
      )).expectStatus(415);
    });
  });

  test('allowedOrigins stops other browsers', () async {
    McpServer guarded = McpServer(
      name: 'g',
      version: '1',
      tools: <McpTool>[],
      allowedOrigins: <String>['https://ok.test'],
    );
    Route.post('/guarded', (DoxRequest req) => guarded.handle(req));
    (await client.post(
      '/guarded',
      headers: <String, String>{...json, 'origin': 'https://evil.test'},
      body: '{}',
    )).expectStatus(403);
  });
}
