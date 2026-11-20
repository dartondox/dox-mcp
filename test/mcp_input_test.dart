import 'dart:convert';

import 'package:dox_core/dox_core.dart';
import 'package:dox_core/testing.dart';
import 'package:dox_mcp/dox_mcp.dart';
import 'package:dox_mcp/src/mcp_request_state.dart';
import 'package:dox_mcp/src/mcp_tool.dart' show McpInputs;
import 'package:test/test.dart';

enum Color { red, green }

/// The example of the docs: asks before it deletes.
class DeleteTool extends McpTool {
  static final McpInput<bool> confirmDelete = McpInput.confirm(
    'Delete this expense?',
  );

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete an expense.';

  @override
  ObjectSchema get input => v.object(<String, Schema<Object?>>{'id': v.int()});

  @override
  McpToolResult call(Map<String, dynamic> args, McpContext context) {
    McpAnswer<bool>? answer = context.answer(confirmDelete);
    if (answer == null) {
      return McpToolResult.inputRequired(<McpInput<Object?>>[confirmDelete]);
    }
    return switch (answer) {
      McpAccepted<bool>(value: true) => McpToolResult.text(
        'Deleted ${args['id']}',
      ),
      McpAccepted<bool>() ||
      McpDeclined<bool>() ||
      McpCancelled<bool>() => McpToolResult.text('Cancelled'),
    };
  }
}

/// Asks for text, a number and a choice in one round. Asks only for
/// the ones it has no answer for.
class PickTool extends McpTool {
  static final McpInput<String> label = McpInput.text('Title?');
  static final McpInput<num> amount = McpInput.number('Amount?');
  static final McpInput<Color> color = McpInput.choice('Color?', Color.values);

  @override
  String get name => 'pick';

  @override
  String get description => 'Pick things.';

  @override
  McpToolResult call(Map<String, dynamic> args, McpContext context) {
    McpAnswer<String>? t = context.answer(label);
    McpAnswer<num>? a = context.answer(amount);
    McpAnswer<Color>? c = context.answer(color);
    List<McpInput<Object?>> missing = <McpInput<Object?>>[
      if (t == null) label,
      if (a == null) amount,
      if (c == null) color,
    ];
    if (missing.isNotEmpty) return McpToolResult.inputRequired(missing);
    if (t is McpAccepted<String> &&
        a is McpAccepted<num> &&
        c is McpAccepted<Color>) {
      return McpToolResult.text('${t.value} ${a.value} ${c.value.name}');
    }
    return McpToolResult.text('not all accepted');
  }
}

/// Asks one question per round, so the first answer must be kept.
class TwoStepTool extends McpTool {
  static final McpInput<bool> sure = McpInput.confirm('Sure?');
  static final McpInput<String> reason = McpInput.text('Why?');

  @override
  String get name => 'two_step';

  @override
  String get description => 'Two questions.';

  @override
  McpToolResult call(Map<String, dynamic> args, McpContext context) {
    McpAnswer<bool>? first = context.answer(sure);
    if (first == null) {
      return McpToolResult.inputRequired(<McpInput<Object?>>[sure]);
    }
    McpAnswer<String>? second = context.answer(reason);
    if (second == null) {
      return McpToolResult.inputRequired(<McpInput<Object?>>[reason]);
    }
    if (first is McpAccepted<bool> && second is McpAccepted<String>) {
      return McpToolResult.text('${first.value} ${second.value}');
    }
    return McpToolResult.text('no');
  }
}

class Expense {
  const Expense(this.name, this.note);

  final String name;
  final String? note;
}

/// In the shape `dox_builder` writes, for a DTO with
/// `@Length(min: 2) final String name;` and `final String? note;`.
class ExpenseDto extends DtoSchema<Expense> {
  const ExpenseDto();

  static const Map<String, String> _m = <String, String>{};

  @override
  Type get type => Expense;

  @override
  String get name => 'Expense';

  @override
  Expense? convert(Object? input, DtoState s, List<Object> p) {
    if (input is! Map) {
      s.notObject(input, p, _m);
      return null;
    }
    int e = s.issues.length;
    Object? c0 = s.string(s.read(input, 'name'), p, 'name', _m);
    if (c0 == null || c0 is Undefined) s.required(p, 'name', _m);
    Object? c1 = s.string(s.read(input, 'note'), p, 'note', _m);
    if (s.issues.length != e) return null;
    if (c0 is String && c0.length < 2) {
      s.fail(p, 'name', 'too_short', 'Too short', c0);
      return null;
    }
    return Expense(c0 as String, c1 is Undefined ? null : c1 as String?);
  }

  @override
  Expense fromMap(Map<String, dynamic> m) {
    return Expense(m['name'] as String, m['note'] as String?);
  }

  @override
  Map<String, dynamic> toMap(Expense o) {
    return <String, dynamic>{'name': o.name, 'note': o.note};
  }

  @override
  Map<String, dynamic> toJsonSchema() {
    return <String, dynamic>{
      'type': 'object',
      'title': 'Expense',
      'properties': <String, dynamic>{
        'name': <String, dynamic>{
          'type': 'string',
          'minLength': 2,
          'pattern': '^.+\$',
        },
        'note': <String, dynamic>{
          'type': <dynamic>['string', 'null'],
          'format': 'email',
        },
      },
      'required': <dynamic>['name'],
    };
  }
}

/// An [ExpenseDto] with a nested object.
class NestedDto extends ExpenseDto {
  const NestedDto();

  @override
  Map<String, dynamic> toJsonSchema() {
    return <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'address': <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        },
      },
    };
  }
}

/// An [ExpenseDto] with an async rule, like `@Unique`.
class AsyncDto extends ExpenseDto {
  const AsyncDto();

  @override
  bool get isAsync => true;
}

class Rename {
  const Rename(this.id);

  final int id;
}

class RenameDto extends DtoSchema<Rename> {
  const RenameDto();

  @override
  Type get type => Rename;

  @override
  String get name => 'Rename';

  @override
  Rename? convert(Object? input, DtoState s, List<Object> p) {
    if (input is! Map || input['id'] is! int) {
      s.fail(p, 'id', 'required', 'needed', null);
      return null;
    }
    return Rename(input['id'] as int);
  }

  @override
  Rename fromMap(Map<String, dynamic> m) => Rename(m['id'] as int);

  @override
  Map<String, dynamic> toMap(Rename o) => <String, dynamic>{'id': o.id};

  @override
  Map<String, dynamic> toJsonSchema() {
    return <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{
        'id': <String, dynamic>{'type': 'integer'},
      },
      'required': <dynamic>['id'],
    };
  }
}

/// An `McpDtoTool` that asks for a form.
class FormTool extends McpDtoTool<Rename> {
  static final McpInput<Expense> expense = McpInput.form(
    'New expense',
    const ExpenseDto(),
  );

  @override
  String get name => 'form';

  @override
  String get description => 'Ask a form.';

  @override
  DtoSchema<Rename> get dto => const RenameDto();

  @override
  McpToolResult handle(Rename input, McpContext context) {
    McpAnswer<Expense>? answer = context.answer(expense);
    if (answer == null) {
      return McpToolResult.inputRequired(<McpInput<Object?>>[expense]);
    }
    return switch (answer) {
      McpAccepted<Expense>(value: Expense e) => McpToolResult.text(
        '${input.id} ${e.name} ${e.note}',
      ),
      McpDeclined<Expense>() => McpToolResult.text('declined'),
      McpCancelled<Expense>() => McpToolResult.text('cancelled'),
    };
  }
}

class LinkTool extends McpTool {
  static final McpInput<void> connect = McpInput.url(
    'Connect your bank',
    'https://app.example.com/connect',
  );

  @override
  String get name => 'link';

  @override
  String get description => 'Send the user to a page.';

  @override
  McpToolResult call(Map<String, dynamic> args, McpContext context) {
    McpAnswer<void>? answer = context.answer(connect);
    if (answer == null) {
      return McpToolResult.inputRequired(<McpInput<Object?>>[connect]);
    }
    return McpToolResult.text(answer is McpAccepted<void> ? 'opened' : 'not');
  }
}

/// A sampling request, made with the escape hatch.
class AskModel extends McpCustomInput<String> {
  @override
  String get method => 'sampling/createMessage';

  @override
  List<String> get capability => <String>['sampling'];

  @override
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'messages': <Object?>[
        <String, Object?>{
          'role': 'user',
          'content': <String, Object?>{'type': 'text', 'text': 'Hi?'},
        },
      ],
      'maxTokens': 10,
    };
  }

  @override
  String parse(Map<String, Object?> result) {
    Map<String, Object?> content = result['content']! as Map<String, Object?>;
    return content['text']! as String;
  }
}

class CustomTool extends McpTool {
  static final AskModel ask = AskModel();

  @override
  String get name => 'custom';

  @override
  String get description => 'Ask the model.';

  @override
  McpToolResult call(Map<String, dynamic> args, McpContext context) {
    McpAnswer<String>? answer = context.answer(ask);
    if (answer == null) {
      return McpToolResult.inputRequired(<McpInput<Object?>>[ask]);
    }
    return McpToolResult.text(switch (answer) {
      McpAccepted<String>(value: String text) => 'model: $text',
      McpDeclined<String>() || McpCancelled<String>() => 'no model',
    });
  }
}

final List<int> stateKey = utf8.encode('s' * 32);

final McpServer server = McpServer(
  name: 'mrtr',
  version: '1',
  allowedOrigins: <String>[],
  requestStateKey: stateKey,
  tools: <McpTool>[
    DeleteTool(),
    PickTool(),
    TwoStepTool(),
    FormTool(),
    LinkTool(),
    CustomTool(),
  ],
);

class MrtrRouter extends Router {
  @override
  void register() {
    Route.match(<String>['POST'], '/mrtr/{user}', (DoxRequest req) {
      String user = '${req.param['user']}';
      return server.handle(req, auth: user, scope: user);
    });
  }
}

const String version = '2026-07-28';

Map<String, dynamic> formOnly = <String, dynamic>{
  'elicitation': <String, dynamic>{},
};

void main() {
  late DoxTestClient client;

  setUpAll(() async {
    client = await DoxTestClient.start(
      AppConfig(
        appKey: 'mcp-test-key-0123456789abcdef!!!',
        routers: <Router>[MrtrRouter()],
      ),
    );
  });

  tearDownAll(() async {
    await client.close();
  });

  /// One `tools/call` of protocol 2026-07-28.
  Future<TestResponse> call(
    String tool, {
    Map<String, dynamic> args = const <String, dynamic>{},
    Map<String, dynamic>? capabilities,
    String? state,
    Map<String, dynamic>? responses,
    String user = 'ann',
    int id = 1,
  }) {
    Map<String, dynamic> body = <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': <String, dynamic>{
        'name': tool,
        'arguments': args,
        'requestState': ?state,
        'inputResponses': ?responses,
        '_meta': <String, dynamic>{
          'io.modelcontextprotocol/protocolVersion': version,
          'io.modelcontextprotocol/clientCapabilities':
              capabilities ?? formOnly,
        },
      },
    };
    return client.post(
      '/mrtr/$user',
      headers: <String, String>{
        'content-type': 'application/json',
        'mcp-protocol-version': version,
        'mcp-method': 'tools/call',
        'mcp-name': tool,
      },
      body: jsonEncode(body),
    );
  }

  Map<String, dynamic> resultOf(TestResponse res) {
    res.expectStatus(200);
    return res.json['result'] as Map<String, dynamic>;
  }

  String textOf(TestResponse res) {
    Map<String, dynamic> result = resultOf(res);
    expect(result['resultType'], 'complete');
    return result['content'][0]['text'] as String;
  }

  /// The only key of `inputRequests`.
  String keyOf(Map<String, dynamic> result) {
    expect(result['resultType'], 'input_required');
    return (result['inputRequests'] as Map<String, dynamic>).keys.single;
  }

  Map<String, dynamic> accept(Object? content) {
    return <String, dynamic>{'action': 'accept', 'content': content};
  }

  void expectError(TestResponse res, int status, int code) {
    res.expectStatus(status);
    expect(res.json['error']['code'], code);
  }

  group('confirm', () {
    test('asks first, with an elicitation form', () async {
      Map<String, dynamic> result = resultOf(
        await call('delete', args: <String, dynamic>{'id': 7}),
      );
      String key = keyOf(result);
      expect(key, startsWith('i_'));
      expect(result['inputRequests'][key], <String, dynamic>{
        'method': 'elicitation/create',
        'params': <String, dynamic>{
          'mode': 'form',
          'requestedSchema': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'value': <String, dynamic>{'type': 'boolean'},
            },
            'required': <String>['value'],
          },
          'message': 'Delete this expense?',
        },
      });
      expect(result['requestState'], isA<String>());
    });

    test('the key is the same in every call', () async {
      Map<String, dynamic> a = resultOf(
        await call('delete', args: <String, dynamic>{'id': 7}),
      );
      Map<String, dynamic> b = resultOf(
        await call('delete', args: <String, dynamic>{'id': 8}),
      );
      expect(keyOf(a), keyOf(b));
    });

    Future<String> answer(Map<String, dynamic> response) async {
      Map<String, dynamic> first = resultOf(
        await call('delete', args: <String, dynamic>{'id': 7}),
      );
      return textOf(
        await call(
          'delete',
          id: 2,
          args: <String, dynamic>{'id': 7},
          state: first['requestState'] as String,
          responses: <String, dynamic>{keyOf(first): response},
        ),
      );
    }

    test('yes runs the tool', () async {
      expect(
        await answer(accept(<String, dynamic>{'value': true})),
        'Deleted 7',
      );
    });

    test('no, decline and cancel do not', () async {
      expect(
        await answer(accept(<String, dynamic>{'value': false})),
        'Cancelled',
      );
      expect(await answer(<String, dynamic>{'action': 'decline'}), 'Cancelled');
      expect(await answer(<String, dynamic>{'action': 'cancel'}), 'Cancelled');
    });

    test('a bad or missing answer asks again', () async {
      Map<String, dynamic> first = resultOf(
        await call('delete', args: <String, dynamic>{'id': 7}),
      );
      String key = keyOf(first);
      for (Map<String, dynamic>? responses in <Map<String, dynamic>?>[
        <String, dynamic>{
          key: accept(<String, dynamic>{'value': 'yes'}),
        },
        <String, dynamic>{key: accept(null)},
        <String, dynamic>{
          key: <String, dynamic>{'action': 'maybe'},
        },
        <String, dynamic>{key: 'accept'},
        <String, dynamic>{
          'other': accept(<String, dynamic>{'value': true}),
        },
        null,
      ]) {
        Map<String, dynamic> again = resultOf(
          await call(
            'delete',
            id: 2,
            args: <String, dynamic>{'id': 7},
            state: first['requestState'] as String,
            responses: responses,
          ),
        );
        expect(keyOf(again), key, reason: '$responses');
      }
    });

    test('answers without a requestState are not read', () async {
      Map<String, dynamic> first = resultOf(
        await call('delete', args: <String, dynamic>{'id': 7}),
      );
      Map<String, dynamic> again = resultOf(
        await call(
          'delete',
          id: 2,
          args: <String, dynamic>{'id': 7},
          responses: <String, dynamic>{
            keyOf(first): accept(<String, dynamic>{'value': true}),
          },
        ),
      );
      expect(again['resultType'], 'input_required');
    });

    test('needs the elicitation capability', () async {
      TestResponse res = await call(
        'delete',
        args: <String, dynamic>{'id': 7},
        capabilities: <String, dynamic>{},
      );
      expectError(res, 400, JsonRpcCode.missingRequiredClientCapability);
      expect(res.json['error']['data'], <String, dynamic>{
        'requiredCapabilities': <String, dynamic>{
          'elicitation': <String, dynamic>{'form': <String, dynamic>{}},
        },
      });
    });

    test('a client with only url mode cannot get a form', () async {
      TestResponse res = await call(
        'delete',
        args: <String, dynamic>{'id': 7},
        capabilities: <String, dynamic>{
          'elicitation': <String, dynamic>{'url': <String, dynamic>{}},
        },
      );
      expectError(res, 400, JsonRpcCode.missingRequiredClientCapability);
    });
  });

  group('requestState', () {
    Future<String> stateFor(int id) async {
      Map<String, dynamic> first = resultOf(
        await call('delete', args: <String, dynamic>{'id': id}),
      );
      return first['requestState'] as String;
    }

    Map<String, dynamic> yes = <String, dynamic>{
      'x': accept(<String, dynamic>{'value': true}),
    };

    test('a changed state is refused', () async {
      String state = await stateFor(7);
      String body = state.substring(0, state.indexOf('.'));
      String sig = state.substring(state.indexOf('.') + 1);
      for (String bad in <String>[
        '${state}x',
        'x$state',
        '${body}x.$sig',
        body,
        'nonsense',
      ]) {
        expectError(
          await call(
            'delete',
            args: <String, dynamic>{'id': 7},
            state: bad,
            responses: yes,
          ),
          200,
          JsonRpcCode.invalidParams,
        );
      }
    });

    test('a state that is not a string is refused', () async {
      TestResponse res = await client.post(
        '/mrtr/ann',
        headers: <String, String>{
          'content-type': 'application/json',
          'mcp-protocol-version': version,
          'mcp-method': 'tools/call',
          'mcp-name': 'delete',
        },
        body: jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'tools/call',
          'params': <String, dynamic>{
            'name': 'delete',
            'arguments': <String, dynamic>{'id': 7},
            'requestState': 12,
            '_meta': <String, dynamic>{
              'io.modelcontextprotocol/protocolVersion': version,
              'io.modelcontextprotocol/clientCapabilities': formOnly,
            },
          },
        }),
      );
      expectError(res, 200, JsonRpcCode.invalidParams);
    });

    test('the state of other arguments is refused', () async {
      String state = await stateFor(7);
      expectError(
        await call('delete', args: <String, dynamic>{'id': 8}, state: state),
        200,
        JsonRpcCode.invalidParams,
      );
    });

    test('the state of another tool is refused', () async {
      Map<String, dynamic> first = resultOf(await call('two_step'));
      expectError(
        await call('pick', state: first['requestState'] as String),
        200,
        JsonRpcCode.invalidParams,
      );
    });

    test('the state of another user is refused', () async {
      String state = await stateFor(7);
      expectError(
        await call(
          'delete',
          args: <String, dynamic>{'id': 7},
          state: state,
          user: 'bob',
        ),
        200,
        JsonRpcCode.invalidParams,
      );
    });

    test('an expired state is refused', () async {
      Map<String, dynamic> first = resultOf(
        await call('delete', args: <String, dynamic>{'id': 7}),
      );
      String key = keyOf(first);
      McpRequestState states = McpRequestState(key: stateKey);
      String old = states.sign(
        scope: 'ann',
        tool: 'delete',
        args: <String, dynamic>{'id': 7},
        asked: <String>[key],
        answers: <String, Map<String, Object?>>{},
        now: DateTime.now().subtract(const Duration(minutes: 6)),
      );
      TestResponse res = await call(
        'delete',
        args: <String, dynamic>{'id': 7},
        state: old,
        responses: <String, dynamic>{
          key: accept(<String, dynamic>{'value': true}),
        },
      );
      expectError(res, 200, JsonRpcCode.invalidParams);
      expect(res.json['error']['message'], contains('expired'));

      // the same state, still fresh, works
      String fresh = states.sign(
        scope: 'ann',
        tool: 'delete',
        args: <String, dynamic>{'id': 7},
        asked: <String>[key],
        answers: <String, Map<String, Object?>>{},
      );
      expect(
        textOf(
          await call(
            'delete',
            args: <String, dynamic>{'id': 7},
            state: fresh,
            responses: <String, dynamic>{
              key: accept(<String, dynamic>{'value': true}),
            },
          ),
        ),
        'Deleted 7',
      );
    });

    test('argument key order does not matter', () {
      expect(
        McpRequestState.hashOf(<String, dynamic>{'a': 1, 'b': 2}),
        McpRequestState.hashOf(<String, dynamic>{'b': 2, 'a': 1}),
      );
    });
  });

  group('text, number and choice', () {
    test('ask in one round and read the answers', () async {
      Map<String, dynamic> first = resultOf(await call('pick'));
      Map<String, dynamic> requests =
          first['inputRequests'] as Map<String, dynamic>;
      expect(requests, hasLength(3));
      Map<String, String> keys = <String, String>{
        for (MapEntry<String, dynamic> e in requests.entries)
          e.value['params']['message'] as String: e.key,
      };
      expect(
        requests[keys['Color?']]['params']['requestedSchema']['properties']['value'],
        <String, dynamic>{
          'type': 'string',
          'enum': <String>['red', 'green'],
        },
      );

      Future<TestResponse> retry(Object? color) {
        return call(
          'pick',
          id: 2,
          state: first['requestState'] as String,
          responses: <String, dynamic>{
            keys['Title?']!: accept(<String, dynamic>{'value': 'Lunch'}),
            keys['Amount?']!: accept(<String, dynamic>{'value': 12.5}),
            keys['Color?']!: accept(<String, dynamic>{'value': color}),
          },
        );
      }

      expect(textOf(await retry('green')), 'Lunch 12.5 green');

      // an unknown enum name asks for that one again, the others are kept
      Map<String, dynamic> again = resultOf(await retry('blue'));
      expect(keyOf(again), keys['Color?']);
      expect(
        textOf(
          await call(
            'pick',
            id: 3,
            state: again['requestState'] as String,
            responses: <String, dynamic>{
              keys['Color?']!: accept(<String, dynamic>{'value': 'red'}),
            },
          ),
        ),
        'Lunch 12.5 red',
      );
    });
  });

  test('answers of earlier rounds are kept', () async {
    Map<String, dynamic> first = resultOf(await call('two_step'));
    Map<String, dynamic> second = resultOf(
      await call(
        'two_step',
        id: 2,
        state: first['requestState'] as String,
        responses: <String, dynamic>{
          keyOf(first): accept(<String, dynamic>{'value': true}),
        },
      ),
    );
    expect(second['inputRequests'][keyOf(second)]['params']['message'], 'Why?');
    expect(
      textOf(
        await call(
          'two_step',
          id: 3,
          state: second['requestState'] as String,
          // the client only sends the answer of the last round
          responses: <String, dynamic>{
            keyOf(second): accept(<String, dynamic>{'value': 'tidy'}),
          },
        ),
      ),
      'true tidy',
    );
  });

  group('form', () {
    test('works in an McpDtoTool, with a flat requestedSchema', () async {
      Map<String, dynamic> first = resultOf(
        await call('form', args: <String, dynamic>{'id': 3}),
      );
      String key = keyOf(first);
      expect(
        first['inputRequests'][key]['params']['requestedSchema'],
        <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'name': <String, dynamic>{'type': 'string', 'minLength': 2},
            'note': <String, dynamic>{'type': 'string', 'format': 'email'},
          },
          'required': <String>['name'],
        },
      );

      Future<TestResponse> retry(Map<String, dynamic> answer) {
        return call(
          'form',
          id: 2,
          args: <String, dynamic>{'id': 3},
          state: first['requestState'] as String,
          responses: <String, dynamic>{key: answer},
        );
      }

      expect(
        textOf(
          await retry(
            accept(<String, dynamic>{'name': 'Taxi', 'note': 'a@b.co'}),
          ),
        ),
        '3 Taxi a@b.co',
      );
      expect(
        textOf(await retry(<String, dynamic>{'action': 'decline'})),
        'declined',
      );
      // the DTO rules fail: ask again
      Map<String, dynamic> again = resultOf(
        await retry(accept(<String, dynamic>{'name': 'T'})),
      );
      expect(keyOf(again), key);
    });

    test('a DTO with a nested object throws', () {
      expect(
        () => McpInput.form('x', const NestedDto()),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => e.message,
            'message',
            contains('"address"'),
          ),
        ),
      );
    });

    test('a DTO with async rules throws', () {
      expect(() => McpInput.form('x', const AsyncDto()), throwsArgumentError);
    });
  });

  group('url', () {
    test('needs the url mode', () async {
      TestResponse res = await call('link');
      expectError(res, 400, JsonRpcCode.missingRequiredClientCapability);
      expect(res.json['error']['data'], <String, dynamic>{
        'requiredCapabilities': <String, dynamic>{
          'elicitation': <String, dynamic>{'url': <String, dynamic>{}},
        },
      });
    });

    test('asks with mode url and reads accept', () async {
      Map<String, dynamic> caps = <String, dynamic>{
        'elicitation': <String, dynamic>{'url': <String, dynamic>{}},
      };
      Map<String, dynamic> first = resultOf(
        await call('link', capabilities: caps),
      );
      String key = keyOf(first);
      expect(first['inputRequests'][key]['params'], <String, dynamic>{
        'mode': 'url',
        'url': 'https://app.example.com/connect',
        'message': 'Connect your bank',
      });
      expect(
        textOf(
          await call(
            'link',
            id: 2,
            capabilities: caps,
            state: first['requestState'] as String,
            responses: <String, dynamic>{
              key: <String, dynamic>{'action': 'accept'},
            },
          ),
        ),
        'opened',
      );
    });

    test('a URL that is not full throws', () {
      expect(() => McpInput.url('x', '/connect'), throwsArgumentError);
    });
  });

  group('custom input', () {
    test('checks its capability', () async {
      TestResponse res = await call('custom');
      expectError(res, 400, JsonRpcCode.missingRequiredClientCapability);
      expect(res.json['error']['data'], <String, dynamic>{
        'requiredCapabilities': <String, dynamic>{
          'sampling': <String, dynamic>{},
        },
      });
    });

    test('asks with its method and parses the result', () async {
      Map<String, dynamic> caps = <String, dynamic>{
        'sampling': <String, dynamic>{},
      };
      Map<String, dynamic> first = resultOf(
        await call('custom', capabilities: caps),
      );
      String key = keyOf(first);
      expect(first['inputRequests'][key]['method'], 'sampling/createMessage');
      expect(first['inputRequests'][key]['params']['maxTokens'], 10);

      Future<TestResponse> retry(Map<String, dynamic> result) {
        return call(
          'custom',
          id: 2,
          capabilities: caps,
          state: first['requestState'] as String,
          responses: <String, dynamic>{key: result},
        );
      }

      expect(
        textOf(
          await retry(<String, dynamic>{
            'role': 'assistant',
            'content': <String, dynamic>{'type': 'text', 'text': 'Hello'},
            'model': 'm',
          }),
        ),
        'model: Hello',
      );
      expect(
        textOf(await retry(<String, dynamic>{'action': 'decline'})),
        'no model',
      );
      // a result parse cannot read: ask again
      expect(
        resultOf(await retry(<String, dynamic>{'content': 5}))['resultType'],
        'input_required',
      );
    });
  });

  group('inputRequired', () {
    test('needs at least one input', () {
      expect(
        () => McpToolResult.inputRequired(<McpInput<Object?>>[]),
        throwsArgumentError,
      );
    });

    test('two inputs that ask the same thing throw', () {
      expect(
        () => McpToolResult.inputRequired(<McpInput<Object?>>[
          McpInput.confirm('Sure?'),
          McpInput.confirm('Sure?'),
        ]),
        throwsArgumentError,
      );
    });

    test('an older client gets an error result', () async {
      TestResponse init = await client.post(
        '/mrtr/ann',
        headers: <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{'protocolVersion': '2025-11-25'},
        }),
      );
      String session = init.header('mcp-session-id')!;
      TestResponse res = await client.post(
        '/mrtr/ann',
        headers: <String, String>{
          'content-type': 'application/json',
          'mcp-session-id': session,
          'mcp-protocol-version': '2025-11-25',
        },
        body: jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/call',
          'params': <String, dynamic>{
            'name': 'delete',
            'arguments': <String, dynamic>{'id': 7},
          },
        }),
      );
      res.expectStatus(200);
      Map<String, dynamic> result = res.json['result'] as Map<String, dynamic>;
      expect(result['isError'], true);
      expect(result['content'][0]['text'], contains('2026-07-28'));
      expect(result.containsKey('inputRequests'), isFalse);
    });
  });

  group('McpClientCapabilities', () {
    McpClientCapabilities caps(Map<String, dynamic> json) {
      return McpInputs.capabilitiesOf(json);
    }

    test('an empty elicitation means form mode', () {
      McpClientCapabilities c = caps(formOnly);
      expect(c.elicitationForm, isTrue);
      expect(c.elicitationUrl, isFalse);
    });

    test('url only, and both', () {
      McpClientCapabilities url = caps(<String, dynamic>{
        'elicitation': <String, dynamic>{'url': <String, dynamic>{}},
      });
      expect(url.elicitationForm, isFalse);
      expect(url.elicitationUrl, isTrue);
      McpClientCapabilities both = caps(<String, dynamic>{
        'elicitation': <String, dynamic>{
          'form': <String, dynamic>{},
          'url': <String, dynamic>{},
        },
        'extensions': <String, dynamic>{'my.ext': <String, dynamic>{}},
      });
      expect(both.elicitationForm, isTrue);
      expect(both.elicitationUrl, isTrue);
      expect(both.has(<String>['extensions', 'my.ext']), isTrue);
      expect(both.has(<String>['sampling']), isFalse);
      expect(both.extensions, <String>{'my.ext'});
    });
  });
}
