import 'dart:convert';
import 'dart:io';

import 'package:dox_core/dox_core.dart';
import 'package:dox_core/testing.dart';
import 'package:dox_mcp/dox_mcp.dart';
import 'package:dox_mcp/src/origin_check.dart';
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
    lastContext = context;
    num sum = (args['a'] as num) + (args['b'] as num);
    return McpToolResult.text('${context.auth}: $sum');
  }
}

/// A small DTO, like a class with `@Dto()`.
class CreateCategory {
  const CreateCategory({required this.name, this.color});

  final String name;
  final String? color;
}

/// Written by hand in the shape `dox_builder` writes, for:
/// `@Describe('The category name.') @Length(min: 2, max: 20) final String name;`
/// and a `@Unique`-like async rule that refuses the name `taken`.
class _CreateCategoryDto extends DtoSchema<CreateCategory> {
  const _CreateCategoryDto();

  static const Map<String, String> _m = <String, String>{};

  @override
  Type get type => CreateCategory;

  @override
  String get name => 'CreateCategory';

  @override
  bool get isAsync => true;

  @override
  CreateCategory? convert(Object? input, DtoState s, List<Object> p) {
    if (input is! Map) {
      s.notObject(input, p, _m);
      return null;
    }
    int e = s.issues.length;
    Object? c0 = s.string(s.read(input, 'name'), p, 'name', _m);
    if (c0 == null || c0 is Undefined) s.required(p, 'name', _m);
    Object? c1 = s.string(s.read(input, 'color'), p, 'color', _m);
    if (s.issues.length != e) return null;
    if (c0 is String && (c0.length < 2 || c0.length > 20)) {
      s.fail(
        p,
        'name',
        IssueCodes.lengthBetween,
        DefaultMessages.lengthBetween,
        c0,
        params: const <String, Object?>{'min': 2, 'max': 20},
      );
      return null;
    }
    return CreateCategory(
      name: c0 as String,
      color: c1 is Undefined ? null : c1 as String?,
    );
  }

  @override
  Future<void> checkAsync(
    CreateCategory value,
    DtoState state,
    List<Object> path,
  ) async {
    if (value.name == 'taken') {
      state.fail(path, 'name', 'unique', 'The name is already taken', null);
    }
  }

  @override
  CreateCategory fromMap(Map<String, dynamic> m) {
    return CreateCategory(name: m['name'] as String);
  }

  @override
  Map<String, dynamic> toMap(CreateCategory o) {
    return <String, dynamic>{'name': o.name, 'color': o.color};
  }

  @override
  Map<String, dynamic> toJsonSchema() {
    return <String, dynamic>{
      'type': 'object',
      'title': 'CreateCategory',
      'properties': <String, dynamic>{
        'name': <String, dynamic>{
          'type': 'string',
          'minLength': 2,
          'maxLength': 20,
          'description': 'The category name.',
        },
        'color': <String, dynamic>{
          'type': <dynamic>['string', 'null'],
        },
      },
      'required': <dynamic>['name'],
    };
  }
}

class CreateCategoryTool extends McpDtoTool<CreateCategory> {
  @override
  String get name => 'create_category';

  @override
  String get description => 'Add a category.';

  @override
  DtoSchema<CreateCategory> get dto => const _CreateCategoryDto();

  @override
  McpToolResult handle(CreateCategory input, McpContext context) {
    return McpToolResult.text('${input.name} ${input.color}');
  }
}

/// the context of the last `add` call
McpContext? lastContext;

/// what `onToolError` got
final List<Object> toolErrors = <Object>[];

final McpServer mcp = McpServer(
  onToolError: (String tool, Object error, StackTrace stack) {
    toolErrors.add(error);
  },
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
        throw StateError('broken host=db.internal password=p@ss/word');
      },
    ),
    McpTool.of(
      name: 'deliberate',
      description: 'Returns an error on purpose.',
      handler: (Map<String, dynamic> args, McpContext context) {
        return McpToolResult.error('No category with this id');
      },
    ),
    CreateCategoryTool(),
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
  originWarningTests();
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
      expect(tools, hasLength(4));
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
      expect(tools[1]['inputSchema'], <String, dynamic>{
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
      // APP_ENV is not development here: the text is hidden
      expect(boom.json['result'], <String, dynamic>{
        'content': <dynamic>[
          <String, dynamic>{'type': 'text', 'text': 'Tool failed'},
        ],
        'isError': true,
      });
      expect('${boom.json}', isNot(contains('p@ss/word')));
    });

    Future<Map<String, dynamic>> callTool(int id, String name) async {
      TestResponse res = await post(
        'ann',
        request(id, 'tools/call', <String, dynamic>{'name': name}),
        session: session,
      );
      return res.json['result'] as Map<String, dynamic>;
    }

    test('an uncaught error shows its text in development and local', () async {
      for (String env in <String>['development', 'local']) {
        Env().env['APP_ENV'] = env;
        Map<String, dynamic> result = await callTool(6, 'boom');
        expect(result['isError'], isTrue);
        expect(
          result['content'][0]['text'],
          'Bad state: broken host=db.internal password=p@ss/word',
        );
      }
      Env().env.remove('APP_ENV');
    });

    test(
      'an error the tool returns on purpose always passes through',
      () async {
        Map<String, dynamic> result = await callTool(7, 'deliberate');
        expect(result['isError'], isTrue);
        expect(result['content'][0]['text'], 'No category with this id');
      },
    );

    test('onToolError still gets the full error in production', () async {
      toolErrors.clear();
      Env().env.remove('APP_ENV');
      await callTool(8, 'boom');
      expect(toolErrors, hasLength(1));
      expect('${toolErrors.single}', contains('password=p@ss/word'));
    });

    test('a DTO tool lists the DTO schema with its descriptions', () async {
      TestResponse res = await post(
        'ann',
        request(20, 'tools/list'),
        session: session,
      );
      Map<String, dynamic> tool =
          (res.json['result']['tools'] as List<dynamic>).last
              as Map<String, dynamic>;
      expect(tool['name'], 'create_category');
      Map<String, dynamic> schema = tool['inputSchema'] as Map<String, dynamic>;
      expect(schema['type'], 'object');
      expect(schema['required'], <String>['name']);
      expect(schema['properties']['name'], <String, dynamic>{
        'type': 'string',
        'minLength': 2,
        'maxLength': 20,
        'description': 'The category name.',
      });
    });

    test('a DTO tool gets the typed DTO', () async {
      TestResponse res = await post(
        'ann',
        request(21, 'tools/call', <String, dynamic>{
          'name': 'create_category',
          'arguments': <String, dynamic>{'name': 'Food', 'color': '#00ff00'},
        }),
        session: session,
      );
      expect(res.json['result'], <String, dynamic>{
        'content': <dynamic>[
          <String, dynamic>{'type': 'text', 'text': 'Food #00ff00'},
        ],
      });
    });

    test('bad DTO input is an error result with each problem', () async {
      Future<Map<String, dynamic>> call(Object? args) async {
        TestResponse res = await post(
          'ann',
          request(22, 'tools/call', <String, dynamic>{
            'name': 'create_category',
            'arguments': args,
          }),
          session: session,
        );
        expect(res.json.containsKey('error'), isFalse);
        return res.json['result'] as Map<String, dynamic>;
      }

      Map<String, dynamic> bad = await call(<String, dynamic>{
        'name': 5,
        'color': true,
      });
      expect(bad['isError'], isTrue);
      String text = bad['content'][0]['text'] as String;
      expect(
        text,
        startsWith(
          'Input validation error: Invalid arguments for tool '
          'create_category: name: ',
        ),
      );
      expect(text, contains('; color: '));

      Map<String, dynamic> short = await call(<String, dynamic>{'name': 'x'});
      expect(short['isError'], isTrue);
      expect(short['content'][0]['text'], contains('name: '));

      // the async step runs too, like @Unique
      Map<String, dynamic> taken = await call(<String, dynamic>{
        'name': 'taken',
      });
      expect(taken, <String, dynamic>{
        'content': <dynamic>[
          <String, dynamic>{
            'type': 'text',
            'text':
                'Input validation error: Invalid arguments for tool '
                'create_category: name: The name is already taken',
          },
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

  group('protocol 2026-07-28', () {
    const String version = '2026-07-28';
    Map<String, dynamic> meta = <String, dynamic>{
      'io.modelcontextprotocol/protocolVersion': version,
      'io.modelcontextprotocol/clientInfo': <String, dynamic>{
        'name': 'NewClient',
        'version': '2.0.0',
        'title': 'New Client',
      },
      'io.modelcontextprotocol/clientCapabilities': <String, dynamic>{
        'elicitation': <String, dynamic>{},
        'extensions': <String, dynamic>{
          'io.modelcontextprotocol/ui': <String, dynamic>{},
        },
      },
    };
    Map<String, dynamic> serverMeta = <String, dynamic>{
      'io.modelcontextprotocol/serverInfo': <String, dynamic>{
        'name': 'test-server',
        'version': '1.2.3',
        'title': 'Test',
      },
    };

    Map<String, dynamic> modern(
      Object id,
      String method, [
      Map<String, dynamic> params = const <String, dynamic>{},
    ]) {
      return request(1, method, <String, dynamic>{...params, '_meta': meta})
        ..['id'] = id;
    }

    /// Sends the `MCP-*` headers from the body, unless [headers] says
    /// otherwise. A null value in [headers] leaves that header out.
    Future<TestResponse> send(
      Object body, {
      Map<String, String?> headers = const <String, String?>{},
    }) {
      Map<String, String?> all = <String, String?>{
        ...json,
        'mcp-protocol-version': version,
        if (body is Map) 'mcp-method': body['method'] as String?,
        if (body is Map && body['method'] == 'tools/call')
          'mcp-name': body['params']['name'] as String?,
        ...headers,
      };
      return client.post(
        '/mcp/ann',
        headers: <String, String>{
          for (MapEntry<String, String?> e in all.entries)
            if (e.value != null) e.key: e.value!,
        },
        body: jsonEncode(body),
      );
    }

    void expectError(TestResponse res, int status, int code, Object? id) {
      res.expectStatus(status);
      expect(res.json['id'], id);
      expect(res.json['error']['code'], code);
      expect(res.header('mcp-session-id'), isNull);
    }

    test('server/discover gives versions, capabilities and info', () async {
      TestResponse res = await send(modern('d1', 'server/discover'));
      res.expectStatus(200).expectJson(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'd1',
        'result': <String, dynamic>{
          'resultType': 'complete',
          'supportedVersions': <String>[
            '2026-07-28',
            '2025-11-25',
            '2025-06-18',
            '2025-03-26',
            '2024-11-05',
          ],
          'capabilities': <String, dynamic>{
            'tools': <String, dynamic>{'listChanged': false},
          },
          'instructions': 'Use add.',
          'ttlMs': 0,
          'cacheScope': 'private',
          '_meta': serverMeta,
        },
      });
      expect(res.header('mcp-session-id'), isNull);
    });

    test('server/discover needs the _meta too', () async {
      TestResponse res = await send(request(2, 'server/discover'));
      expectError(res, 400, JsonRpcCode.invalidParams, 2);
    });

    test('tools/list has resultType, cache hints and server info', () async {
      TestResponse res = await send(modern(3, 'tools/list'));
      res.expectStatus(200);
      Map<String, dynamic> result = res.json['result'] as Map<String, dynamic>;
      expect(result['resultType'], 'complete');
      expect(result['tools'], hasLength(4));
      expect(result['ttlMs'], 0);
      expect(result['cacheScope'], 'private');
      expect(result['_meta'], serverMeta);
    });

    test('tools/call runs the tool with auth and no session', () async {
      TestResponse res = await send(
        modern(4, 'tools/call', <String, dynamic>{
          'name': 'add',
          'arguments': <String, dynamic>{'a': 1, 'b': 2},
        }),
        // a session id is ignored, and none is sent back
        headers: <String, String?>{'mcp-session-id': 'old.session'},
      );
      res.expectStatus(200).expectJson(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 4,
        'result': <String, dynamic>{
          'resultType': 'complete',
          'content': <dynamic>[
            <String, dynamic>{'type': 'text', 'text': 'ann: 3'},
          ],
          '_meta': serverMeta,
        },
      });
      expect(res.header('mcp-session-id'), isNull);
      McpContext context = lastContext!;
      expect(context.sessionId, '');
      expect(context.protocolVersion, version);
      expect(context.clientInfo!.name, 'NewClient');
      expect(context.clientInfo!.version, '2.0.0');
      expect(context.clientInfo!.title, 'New Client');
      expect(context.clientCapabilities!.elicitation, isTrue);
      expect(context.clientCapabilities!.sampling, isFalse);
      expect(context.clientCapabilities!.roots, isFalse);
      expect(context.clientCapabilities!.extensions, <String>{
        'io.modelcontextprotocol/ui',
      });
    });

    test(
      'header names are not case sensitive; Mcp-Name can be base64',
      () async {
        TestResponse res = await send(
          modern(5, 'tools/call', <String, dynamic>{
            'name': 'add',
            'arguments': <String, dynamic>{'a': 1, 'b': 1},
          }),
          headers: <String, String?>{
            'mcp-protocol-version': null,
            'mcp-method': null,
            'mcp-name': null,
            'MCP-PROTOCOL-VERSION': version,
            'MCP-METHOD': 'tools/call',
            'MCP-NAME': '=?base64?${base64.encode(utf8.encode('add'))}?=',
          },
        );
        res.expectStatus(200);
        expect(res.json['result']['content'][0]['text'], 'ann: 2');
      },
    );

    test(
      'a bad tool call is still a tool result or a JSON-RPC error',
      () async {
        TestResponse bad = await send(
          modern(6, 'tools/call', <String, dynamic>{
            'name': 'add',
            'arguments': <String, dynamic>{'a': 'x'},
          }),
        );
        bad.expectStatus(200);
        expect(bad.json['result']['resultType'], 'complete');
        expect(bad.json['result']['isError'], isTrue);
        TestResponse unknown = await send(
          modern(7, 'tools/call', <String, dynamic>{'name': 'nope'}),
        );
        expectError(unknown, 200, JsonRpcCode.invalidParams, 7);
      },
    );

    test('an unsupported version lists the supported ones', () async {
      Map<String, dynamic> body = modern(8, 'tools/list');
      body['params']['_meta'] = <String, dynamic>{
        ...meta,
        'io.modelcontextprotocol/protocolVersion': '2099-01-01',
      };
      TestResponse res = await send(
        body,
        headers: <String, String?>{'mcp-protocol-version': '2099-01-01'},
      );
      expectError(res, 400, JsonRpcCode.unsupportedProtocolVersion, 8);
      expect(res.json['error']['data'], <String, dynamic>{
        'supported': McpServer.supportedProtocolVersions,
        'requested': '2099-01-01',
      });

      // an older version needs initialize; in _meta it is unsupported
      body['params']['_meta'] = <String, dynamic>{
        ...meta,
        'io.modelcontextprotocol/protocolVersion': '2025-11-25',
      };
      expectError(
        await send(
          body,
          headers: <String, String?>{'mcp-protocol-version': '2025-11-25'},
        ),
        400,
        JsonRpcCode.unsupportedProtocolVersion,
        8,
      );
    });

    test('a missing _meta field is invalid params', () async {
      for (String key in <String>[
        'io.modelcontextprotocol/protocolVersion',
        'io.modelcontextprotocol/clientCapabilities',
      ]) {
        Map<String, dynamic> body = modern(9, 'tools/list');
        body['params']['_meta'] = <String, dynamic>{...meta}..remove(key);
        expectError(await send(body), 400, JsonRpcCode.invalidParams, 9);
      }
      // only the header says 2026-07-28
      expectError(
        await send(request(10, 'tools/list')),
        400,
        JsonRpcCode.invalidParams,
        10,
      );
    });

    test('missing or wrong MCP headers are a header mismatch', () async {
      Map<String, dynamic> call = modern(11, 'tools/call', <String, dynamic>{
        'name': 'add',
        'arguments': <String, dynamic>{'a': 1, 'b': 1},
      });
      List<Map<String, String?>> cases = <Map<String, String?>>[
        <String, String?>{'mcp-protocol-version': null},
        <String, String?>{'mcp-method': null},
        <String, String?>{'mcp-name': null},
        <String, String?>{'mcp-method': 'tools/list'},
        <String, String?>{'mcp-name': 'boom'},
        <String, String?>{'mcp-name': '=?base64?Ym9vbQ==?='},
        <String, String?>{'mcp-name': '=?base64?not base64!?='},
      ];
      for (Map<String, String?> headers in cases) {
        TestResponse res = await send(call, headers: headers);
        expectError(res, 400, JsonRpcCode.headerMismatch, 11);
      }
      // the protocol header must equal the _meta version, which is
      // checked first; a supported but different header still fails
      expectError(
        await send(
          modern(12, 'tools/list'),
          headers: <String, String?>{'mcp-protocol-version': '2025-11-25'},
        ),
        400,
        JsonRpcCode.headerMismatch,
        12,
      );
    });

    test('ping and other unknown methods are a 404', () async {
      expectError(
        await send(modern(13, 'ping')),
        404,
        JsonRpcCode.methodNotFound,
        13,
      );
      expectError(
        await send(modern(14, 'resources/list')),
        404,
        JsonRpcCode.methodNotFound,
        14,
      );
    });

    test('a batch is refused; a notification gets 202', () async {
      TestResponse batch = await send(<Object>[
        modern(15, 'tools/list'),
        modern(16, 'tools/list'),
      ]);
      batch.expectStatus(400);
      expect(batch.json['error']['code'], JsonRpcCode.invalidRequest);
      TestResponse note = await send(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'notifications/x',
      });
      note.expectStatus(202).expectBody('');
      expect(note.header('mcp-session-id'), isNull);
    });

    test('initialize with the new _meta still starts a session', () async {
      TestResponse res = await post(
        'ann',
        request(1, 'initialize', <String, dynamic>{
          'protocolVersion': '2025-11-25',
          '_meta': meta,
        }),
      );
      res.expectStatus(200);
      expect(res.json['result']['protocolVersion'], '2025-11-25');
      expect(res.json['result'].containsKey('resultType'), isFalse);
      expect(res.header('mcp-session-id'), isNotNull);
    });

    test('an older client still works on the same endpoint', () async {
      String session = await initialize('ann', '2025-11-25');
      TestResponse res = await post(
        'ann',
        request(2, 'tools/call', <String, dynamic>{
          'name': 'add',
          'arguments': <String, dynamic>{'a': 2, 'b': 2},
        }),
        session: session,
        protocol: '2025-11-25',
      );
      res.expectStatus(200).expectJson(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 2,
        'result': <String, dynamic>{
          'content': <dynamic>[
            <String, dynamic>{'type': 'text', 'text': 'ann: 4'},
          ],
        },
      });
      expect(lastContext!.sessionId, session);
      expect(lastContext!.clientInfo, isNull);
      expect(lastContext!.clientCapabilities, isNull);
      (await post(
        'ann',
        request(3, 'ping'),
        session: session,
      )).expectStatus(200);
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

class _FakeStderr implements Stdout {
  final StringBuffer text = StringBuffer();

  @override
  void writeln([Object? object = '']) => text.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

McpServer _server({List<String>? origins}) {
  return McpServer(
    name: 'x',
    version: '1',
    tools: <McpTool>[AddTool()],
    allowedOrigins: origins,
  );
}

void originWarningTests() {
  group('open origin warning', () {
    test('warns once when allowedOrigins is null', () {
      originWarningDone = false;
      _FakeStderr err = _FakeStderr();
      IOOverrides.runZoned(() {
        _server();
        _server();
      }, stderr: () => err);
      String out = err.text.toString();
      expect(out, contains('[mcp] warning'));
      expect('warning'.allMatches(out), hasLength(1));
    });

    test('does not warn when allowedOrigins is set', () {
      originWarningDone = false;
      _FakeStderr err = _FakeStderr();
      IOOverrides.runZoned(() {
        _server(origins: <String>['https://app.example.com']);
        _server(origins: <String>[]);
      }, stderr: () => err);
      expect(err.text.toString(), isEmpty);
    });
  });
}
