import 'dart:async';
import 'dart:convert';

import 'package:dox_core/dox_core.dart';
// Needed for dox_core 3.2.3 and older. Newer dox_core exports showErrors,
// so drop this import once the dox_core floor is above 3.2.3.
// ignore: unnecessary_import
import 'package:dox_core/http/http_response_handler.dart' show showErrors;
import 'package:dox_mcp/src/json_rpc.dart';
import 'package:dox_mcp/src/mcp_request_state.dart';
import 'package:dox_mcp/src/mcp_sessions.dart';
import 'package:dox_mcp/src/origin_check.dart';
import 'package:dox_mcp/src/mcp_tool.dart';

/// The header with the session id.
const String mcpSessionHeader = 'mcp-session-id';

/// The header with the protocol version. Older versions send it after
/// `initialize`. Version 2026-07-28 sends it with every request.
const String mcpProtocolHeader = 'mcp-protocol-version';

/// Protocol 2026-07-28: the header with the JSON-RPC method.
const String mcpMethodHeader = 'mcp-method';

/// Protocol 2026-07-28: the header with the tool name of `tools/call`.
const String mcpNameHeader = 'mcp-name';

/// An MCP server over the Streamable HTTP transport, for Dox routes.
///
/// It answers `POST` with JSON (no SSE stream is needed for tools), says
/// `405` to `GET` (no server-to-client stream), and ends the session on
/// `DELETE`. Sessions are signed ids (see [SignedMcpSessions]), so every
/// isolate can serve every session.
///
/// One endpoint serves both kinds of clients:
/// - Older clients (`2025-11-25` and before) send `initialize` first and
///   then use a session.
/// - Clients of `2026-07-28` send the protocol version in the `_meta` of
///   every request. There is no session and no `initialize`.
///
/// ```
/// final McpServer mcp = McpServer(
///   name: 'my-app',
///   version: '1.0.0',
///   tools: <McpTool>[AddNumbers()],
/// );
///
/// Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', (DoxRequest req) {
///   return mcp.handle(req);
/// });
/// ```
class McpServer {
  McpServer({
    required this.name,
    required this.version,
    required List<McpTool> tools,
    this.title,
    this.instructions,
    McpSessions? sessions,
    this.allowedOrigins,
    this.onToolError,
    Duration requestStateTtl = const Duration(minutes: 5),
    List<int>? requestStateKey,
  }) : sessions = sessions ?? SignedMcpSessions(),
       _states = McpRequestState(key: requestStateKey, ttl: requestStateTtl),
       _tools = <String, McpTool>{for (McpTool tool in tools) tool.name: tool} {
    if (_tools.length != tools.length) {
      throw ArgumentError('Two MCP tools have the same name');
    }
    if (allowedOrigins == null) warnOpenOriginOnce();
  }

  /// The protocol versions that start with `initialize` and use a
  /// session, newest first.
  static const List<String> protocolVersions = <String>[
    '2025-11-25',
    '2025-06-18',
    '2025-03-26',
    '2024-11-05',
  ];

  /// The protocol versions with no session. Each request sends its version
  /// in `_meta`.
  static const List<String> statelessProtocolVersions = <String>['2026-07-28'];

  /// Every protocol version this server speaks, newest first.
  static const List<String> supportedProtocolVersions = <String>[
    ...statelessProtocolVersions,
    ...protocolVersions,
  ];

  /// `serverInfo.name`
  final String name;

  /// `serverInfo.version`
  final String version;

  /// `serverInfo.title`, a name for people. Optional.
  final String? title;

  /// Text for the model about how to use the server. Optional.
  final String? instructions;

  final McpSessions sessions;

  /// Browsers may only call the server from these origins. A request with
  /// another `Origin` header gets `403` (this stops DNS rebinding).
  /// Null: any origin. A request with no `Origin` (not a browser) is
  /// always allowed.
  final List<String>? allowedOrigins;

  /// Called when a tool throws. It gets the full error. The client gets
  /// `Tool failed`, unless `APP_ENV` is `development` or `local`. A tool
  /// that wants the model to see a message must return
  /// `McpToolResult.error(...)`. Use this to log.
  final void Function(String tool, Object error, StackTrace stack)? onToolError;

  final Map<String, McpTool> _tools;

  /// Signs the `requestState` of a tool that asks the user (protocol
  /// 2026-07-28). The key comes from `APP_KEY` (label `dox:mcp-state`),
  /// unless `requestStateKey` is given. A state works for
  /// `requestStateTtl` (default 5 minutes).
  final McpRequestState _states;

  /// The tools, in the order they were given.
  List<McpTool> get tools => _tools.values.toList();

  /// Answer one HTTP request of the transport. [auth] is handed to the
  /// tools (`context.auth`), like the user the app found. [scope] ties
  /// sessions to it (use the user id), so a session id works only for the
  /// one it was made for. It ties the `requestState` of a tool that asks
  /// the user to it in the same way. Apps with users MUST pass [scope]:
  /// without it, one user can use the session or the question state of
  /// another user.
  Future<DoxResponse> handle(
    DoxRequest req, {
    Object? auth,
    String scope = '',
  }) async {
    String? origin = req.header('origin');
    List<String>? origins = allowedOrigins;
    if (origin != null && origins != null && !origins.contains(origin)) {
      return _httpError(403, 'Forbidden: origin not allowed');
    }

    switch (req.method) {
      case 'POST':
        return _post(req, auth, scope);
      case 'DELETE':
        return _delete(req, scope);
      case 'GET':
        // No server-to-client stream: the client goes on with POST only.
        return response(<String, dynamic>{
          'jsonrpc': '2.0',
          'error': <String, dynamic>{
            'code': JsonRpcCode.serverError,
            'message': 'Method not allowed: this server sends no stream',
          },
          'id': null,
        }).statusCode(405).header('Allow', 'POST, DELETE');
      default:
        return _httpError(
          405,
          'Method not allowed',
        ).header('Allow', 'POST, DELETE');
    }
  }

  Future<DoxResponse> _post(DoxRequest req, Object? auth, String scope) async {
    RequestBody body = req.requestBody;
    if (body.kind != BodyKind.json && body.kind != BodyKind.invalidJson) {
      return _httpError(
        415,
        'Unsupported Media Type: Content-Type must be application/json',
      );
    }
    if (body.kind == BodyKind.invalidJson) {
      return _rpcErrorResponse(400, JsonRpcCode.parseError, 'Parse error');
    }

    Object? json = body.json;
    bool batch = json is List;
    List<Object?> messages = json is List ? json : <Object?>[json];
    if (messages.isEmpty) {
      return _rpcErrorResponse(
        400,
        JsonRpcCode.invalidRequest,
        'Invalid Request: empty batch',
      );
    }
    for (Object? message in messages) {
      if (message is! Map || message['jsonrpc'] != '2.0') {
        return _rpcErrorResponse(
          400,
          JsonRpcCode.invalidRequest,
          'Invalid Request: not a JSON-RPC 2.0 message',
        );
      }
    }

    if (_isStateless(req, messages)) {
      return _statelessPost(req, json, auth, scope);
    }

    bool initialize = messages.any(_isInitialize);
    String? sessionId = req.header(mcpSessionHeader);
    String protocol;
    Map<String, String> headers = <String, String>{};

    if (initialize) {
      if (messages.length > 1) {
        return _rpcErrorResponse(
          400,
          JsonRpcCode.invalidRequest,
          'Invalid Request: initialize must be sent alone',
        );
      }
      sessionId = sessions.create(scope);
      headers[mcpSessionHeader] = sessionId;
      protocol = _negotiate(messages.first);
    } else {
      if (sessionId == null || sessionId.isEmpty) {
        return _rpcErrorResponse(
          400,
          JsonRpcCode.serverError,
          'Bad Request: No valid session ID provided',
        );
      }
      if (!await sessions.isValid(sessionId, scope)) {
        // 404 makes the client start a new session.
        return _rpcErrorResponse(
          404,
          JsonRpcCode.serverError,
          'Session not found',
        );
      }
      String? asked = req.header(mcpProtocolHeader);
      if (asked != null && !protocolVersions.contains(asked)) {
        return _rpcErrorResponse(
          400,
          JsonRpcCode.serverError,
          'Bad Request: Unsupported protocol version: $asked',
        );
      }
      // no header: the client speaks the version before the header came
      protocol = asked ?? '2025-03-26';
    }

    McpContext context = McpContext(
      request: req,
      sessionId: sessionId,
      protocolVersion: protocol,
      auth: auth,
    );

    List<Map<String, dynamic>> replies = <Map<String, dynamic>>[];
    for (Object? message in messages) {
      if (!JsonRpc.isRequest(message)) continue; // notifications, responses
      Map<dynamic, dynamic> request = message! as Map<dynamic, dynamic>;
      replies.add(await _dispatch(request, context));
    }

    // only notifications or responses: nothing to answer
    if (replies.isEmpty) return response().statusCode(202).withHeaders(headers);

    Object reply = batch ? replies : replies.first;
    return response(reply).withHeaders(headers);
  }

  Future<DoxResponse> _delete(DoxRequest req, String scope) async {
    String? sessionId = req.header(mcpSessionHeader);
    if (sessionId == null || sessionId.isEmpty) {
      return _httpError(400, 'Bad Request: Missing session ID');
    }
    if (!await sessions.isValid(sessionId, scope)) {
      return _httpError(404, 'Session not found');
    }
    await sessions.end(sessionId);
    return response();
  }

  /// One JSON-RPC request to its response.
  Future<Map<String, dynamic>> _dispatch(
    Map<dynamic, dynamic> request,
    McpContext context,
  ) async {
    Object? id = request['id'];
    if (!JsonRpc.isValidId(id)) {
      return JsonRpc.error(
        null,
        const McpError(JsonRpcCode.invalidRequest, 'Invalid Request: bad id'),
      );
    }
    String method = request['method'] as String;
    Object? params = request['params'];
    try {
      Object? result = switch (method) {
        'initialize' => _initializeResult(context.protocolVersion),
        'ping' => <String, dynamic>{},
        'tools/list' => _toolsListResult(),
        'tools/call' => await _callTool(params, context, scope: ''),
        _ => throw McpError(
          JsonRpcCode.methodNotFound,
          'Method not found: $method',
        ),
      };
      return JsonRpc.result(id, result);
    } on McpError catch (error) {
      return JsonRpc.error(id, error);
    }
  }

  Map<String, dynamic> _initializeResult(String protocol) {
    return <String, dynamic>{
      'protocolVersion': protocol,
      'capabilities': _capabilities(),
      'serverInfo': _serverInfo(),
      'instructions': ?instructions,
    };
  }

  Map<String, dynamic> _capabilities() {
    return <String, dynamic>{
      'tools': <String, dynamic>{'listChanged': false},
    };
  }

  Map<String, dynamic> _serverInfo() {
    return <String, dynamic>{'name': name, 'version': version, 'title': ?title};
  }

  Map<String, dynamic> _toolsListResult() {
    return <String, dynamic>{
      'tools': <Map<String, dynamic>>[
        for (McpTool tool in _tools.values) tool.toJson(),
      ],
    };
  }

  /// Answer one POST of protocol 2026-07-28. Each request carries all it
  /// needs, so there is no session: an `Mcp-Session-Id` header is ignored,
  /// and none is sent back.
  Future<DoxResponse> _statelessPost(
    DoxRequest req,
    Object? json,
    Object? auth,
    String scope,
  ) async {
    if (json is! Map) {
      return _rpcErrorResponse(
        400,
        JsonRpcCode.invalidRequest,
        'Invalid Request: protocol 2026-07-28 does not allow batches',
      );
    }
    if (JsonRpc.isNotification(json)) return response().statusCode(202);
    Object? id = json['id'];
    if (!JsonRpc.isRequest(json) || !JsonRpc.isValidId(id)) {
      return _rpcErrorResponse(
        400,
        JsonRpcCode.invalidRequest,
        'Invalid Request: send one request or notification',
      );
    }

    Object? params = json['params'];
    Object? meta = params is Map ? params['_meta'] : null;
    Object? asked = meta is Map ? meta[_metaProtocolVersion] : null;
    Object? capabilities = meta is Map ? meta[_metaClientCapabilities] : null;
    if (asked is! String || capabilities is! Map) {
      return _errorFor(
        400,
        id,
        const McpError(
          JsonRpcCode.invalidParams,
          'Invalid params: _meta needs $_metaProtocolVersion and '
          '$_metaClientCapabilities',
        ),
      );
    }
    if (!statelessProtocolVersions.contains(asked)) {
      return _errorFor(
        400,
        id,
        McpError(
          JsonRpcCode.unsupportedProtocolVersion,
          'Unsupported protocol version',
          <String, dynamic>{
            'supported': supportedProtocolVersions,
            'requested': asked,
          },
        ),
      );
    }
    String? mismatch = _headerMismatch(req, json, asked);
    if (mismatch != null) {
      return _errorFor(400, id, McpError(JsonRpcCode.headerMismatch, mismatch));
    }

    McpContext context = McpContext(
      request: req,
      sessionId: '',
      protocolVersion: asked,
      auth: auth,
      clientCapabilities: McpInputs.capabilitiesOf(capabilities),
      clientInfo: _clientInfo((meta as Map<dynamic, dynamic>)[_metaClientInfo]),
    );

    String method = json['method'] as String;
    try {
      Map<String, dynamic> result = switch (method) {
        'server/discover' => <String, dynamic>{
          'supportedVersions': supportedProtocolVersions,
          'capabilities': _capabilities(),
          'instructions': ?instructions,
          ..._cacheHints,
        },
        'tools/list' => <String, dynamic>{
          ..._toolsListResult(),
          ..._cacheHints,
        },
        'tools/call' => await _callTool(params, context, scope: scope),
        // `ping`, `initialize` and the rest are not methods of 2026-07-28
        _ => throw McpError(
          JsonRpcCode.methodNotFound,
          'Method not found: $method',
        ),
      };
      return response(
        JsonRpc.result(id, <String, dynamic>{
          'resultType': 'complete',
          ...result,
          '_meta': <String, dynamic>{_metaServerInfo: _serverInfo()},
        }),
      );
    } on McpError catch (error) {
      // an unknown method is a 404, so the client knows it is not a
      // network problem. A missing client capability must be a 400.
      int status = switch (error.code) {
        JsonRpcCode.methodNotFound => 404,
        JsonRpcCode.missingRequiredClientCapability => 400,
        _ => 200,
      };
      return _errorFor(status, id, error);
    }
  }

  /// The error text when the `MCP-*` headers do not match the body, or
  /// one is missing. Null when they are fine. Header names are not case
  /// sensitive; values are.
  static String? _headerMismatch(
    DoxRequest req,
    Map<dynamic, dynamic> message,
    String protocol,
  ) {
    String? sentProtocol = req.header(mcpProtocolHeader);
    if (sentProtocol == null) {
      return 'Header mismatch: MCP-Protocol-Version header is missing';
    }
    if (sentProtocol != protocol) {
      return 'Header mismatch: MCP-Protocol-Version header does not match '
          'the body';
    }
    String method = message['method'] as String;
    String? sentMethod = req.header(mcpMethodHeader);
    if (sentMethod == null) {
      return 'Header mismatch: Mcp-Method header is missing';
    }
    if (sentMethod != method) {
      return 'Header mismatch: Mcp-Method header does not match the body';
    }
    if (method == 'tools/call') {
      String? sentName = req.header(mcpNameHeader);
      if (sentName == null) {
        return 'Header mismatch: Mcp-Name header is missing';
      }
      Object? params = message['params'];
      Object? name = params is Map ? params['name'] : null;
      if (_decodeHeader(sentName) != name) {
        return 'Header mismatch: Mcp-Name header does not match the body';
      }
    }
    return null;
  }

  /// A header value as the client meant it. A value that is not plain
  /// ASCII comes as `=?base64?...?=`. Null when that base64 is broken.
  static String? _decodeHeader(String value) {
    const String start = '=?base64?';
    const String end = '?=';
    if (!value.startsWith(start) ||
        !value.endsWith(end) ||
        value.length < start.length + end.length) {
      return value;
    }
    try {
      return utf8.decode(
        base64.decode(value.substring(start.length, value.length - end.length)),
      );
    } on FormatException {
      return null;
    }
  }

  /// The client info, or null when it is missing or has no name and
  /// version. It is only for logs, so a bad one is not an error.
  static McpClientInfo? _clientInfo(Object? json) {
    if (json is! Map) return null;
    Object? name = json['name'];
    Object? version = json['version'];
    if (name is! String || version is! String) return null;
    Object? title = json['title'];
    Object? description = json['description'];
    Object? websiteUrl = json['websiteUrl'];
    return McpClientInfo(
      name: name,
      version: version,
      title: title is String ? title : null,
      description: description is String ? description : null,
      websiteUrl: websiteUrl is String ? websiteUrl : null,
    );
  }

  /// A request is of protocol 2026-07-28 when its `_meta` has the version
  /// or the client capabilities, when its `MCP-Protocol-Version` header is
  /// such a version, or when it is `server/discover`. `initialize` always
  /// starts the older kind with a session.
  static bool _isStateless(DoxRequest req, List<Object?> messages) {
    if (messages.any(_isInitialize)) return false;
    String? header = req.header(mcpProtocolHeader);
    if (header != null && statelessProtocolVersions.contains(header)) {
      return true;
    }
    for (Object? message in messages) {
      if (message is! Map) continue;
      if (message['method'] == 'server/discover') return true;
      Object? params = message['params'];
      Object? meta = params is Map ? params['_meta'] : null;
      if (meta is Map &&
          (meta.containsKey(_metaProtocolVersion) ||
              meta.containsKey(_metaClientCapabilities))) {
        return true;
      }
    }
    return false;
  }

  static const String _metaProtocolVersion =
      'io.modelcontextprotocol/protocolVersion';
  static const String _metaClientCapabilities =
      'io.modelcontextprotocol/clientCapabilities';
  static const String _metaClientInfo = 'io.modelcontextprotocol/clientInfo';
  static const String _metaServerInfo = 'io.modelcontextprotocol/serverInfo';

  /// The cache hints that `server/discover` and `tools/list` must have.
  /// ponytail: always stale and private. The app may build the server per
  /// user, so a shared cache is not safe. Add a setting when a client
  /// needs real caching.
  static const Map<String, dynamic> _cacheHints = <String, dynamic>{
    'ttlMs': 0,
    'cacheScope': 'private',
  };

  static DoxResponse _errorFor(int status, Object? id, McpError error) {
    return response(JsonRpc.error(id, error)).statusCode(status);
  }

  Future<Map<String, dynamic>> _callTool(
    Object? params,
    McpContext context, {
    required String scope,
  }) async {
    if (params is! Map || params['name'] is! String) {
      throw const McpError(
        JsonRpcCode.invalidParams,
        'Invalid params: tools/call needs a name',
      );
    }
    String toolName = params['name'] as String;
    McpTool? tool = _tools[toolName];
    if (tool == null) {
      throw McpError(JsonRpcCode.invalidParams, 'Tool $toolName not found');
    }

    Object? args = params['arguments'] ?? <String, dynamic>{};
    ParseResult<Map<String, dynamic>> parsed = tool.input.safeParse(args);
    if (!parsed.success) {
      return McpToolResult.invalidArguments(toolName, parsed.issues).toJson();
    }

    // Only protocol 2026-07-28 has client capabilities, and only it can
    // answer questions (multi round-trip requests).
    McpClientCapabilities? capabilities = context.clientCapabilities;
    Map<String, Map<String, Object?>> answers =
        <String, Map<String, Object?>>{};
    if (capabilities != null) {
      answers = _answersOf(params, toolName, args, scope);
      context = McpInputs.withAnswers(context, answers);
    }

    McpToolResult result;
    try {
      result = await tool.call(parsed.value!, context);
    } catch (error, stack) {
      onToolError?.call(toolName, error, stack);
      // The error text can hold hosts, SQL or passwords. Like the web
      // responses of Dox, show it only in development and local.
      return McpToolResult.error(showErrors() ? '$error' : 'Tool failed')
          .toJson();
    }
    // An older client gets the error text of the result.
    if (result.inputs.isEmpty || capabilities == null) return result.toJson();
    return _inputRequired(
      result.inputs,
      capabilities,
      answers,
      scope: scope,
      tool: toolName,
      args: args,
    );
  }

  /// The answers of a retried call: the ones the client sends in
  /// `inputResponses`, and the ones of earlier rounds from the
  /// `requestState`. Answers come only with a valid state, so a client
  /// cannot answer a question the server did not ask. A bad state throws.
  Map<String, Map<String, Object?>> _answersOf(
    Map<dynamic, dynamic> params,
    String tool,
    Object? args,
    String scope,
  ) {
    Object? state = params['requestState'];
    if (state == null) return <String, Map<String, Object?>>{};
    if (state is! String) {
      throw const McpError(
        JsonRpcCode.invalidParams,
        'Invalid params: requestState must be a string',
      );
    }
    McpStateContent content = _states.verify(
      state,
      scope: scope,
      tool: tool,
      args: args,
    );
    Map<String, Map<String, Object?>> answers = <String, Map<String, Object?>>{
      ...content.answers,
    };
    Object? responses = params['inputResponses'];
    if (responses is Map) {
      for (String key in content.asked) {
        Object? response = responses[key];
        if (response is Map) answers[key] = response.cast<String, Object?>();
      }
    }
    return answers;
  }

  /// The `input_required` result. Throws when the client cannot answer
  /// one of [inputs].
  Map<String, dynamic> _inputRequired(
    List<McpInput<Object?>> inputs,
    McpClientCapabilities capabilities,
    Map<String, Map<String, Object?>> answers, {
    required String scope,
    required String tool,
    required Object? args,
  }) {
    for (McpInput<Object?> input in inputs) {
      if (!McpInputs.supports(capabilities, input)) {
        Map<String, Object?> required = McpInputs.requiredCapabilitiesOf(input);
        throw McpError(
          JsonRpcCode.missingRequiredClientCapability,
          'The tool needs the client capability ${required.keys.first}',
          <String, dynamic>{'requiredCapabilities': required},
        );
      }
    }
    List<String> asked = <String>[
      for (McpInput<Object?> input in inputs) McpInputs.keyOf(input),
    ];
    // keep the answers of earlier rounds, but not the ones asked again
    Map<String, Map<String, Object?>> kept = <String, Map<String, Object?>>{
      for (MapEntry<String, Map<String, Object?>> entry in answers.entries)
        if (!asked.contains(entry.key)) entry.key: entry.value,
    };
    return <String, dynamic>{
      'resultType': 'input_required',
      'inputRequests': <String, dynamic>{
        for (McpInput<Object?> input in inputs)
          McpInputs.keyOf(input): McpInputs.requestOf(input),
      },
      'requestState': _states.sign(
        scope: scope,
        tool: tool,
        args: args,
        asked: asked,
        answers: kept,
      ),
    };
  }

  /// The version the client asked for, when this server speaks it. Else
  /// the newest one this server speaks.
  static String _negotiate(Object? message) {
    Object? params = message is Map ? message['params'] : null;
    Object? asked = params is Map ? params['protocolVersion'] : null;
    if (asked is String && protocolVersions.contains(asked)) return asked;
    return protocolVersions.first;
  }

  static bool _isInitialize(Object? message) {
    return message is Map && message['method'] == 'initialize';
  }

  static DoxResponse _rpcErrorResponse(int status, int code, String message) {
    return response(<String, dynamic>{
      'jsonrpc': '2.0',
      'error': <String, dynamic>{'code': code, 'message': message},
      'id': null,
    }).statusCode(status);
  }

  static DoxResponse _httpError(int status, String message) {
    return _rpcErrorResponse(status, JsonRpcCode.serverError, message);
  }
}
