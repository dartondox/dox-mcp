import 'dart:async';

import 'package:dox_core/dox_core.dart';
import 'package:dox_mcp/src/json_rpc.dart';
import 'package:dox_mcp/src/mcp_sessions.dart';
import 'package:dox_mcp/src/mcp_tool.dart';

/// The header with the session id.
const String mcpSessionHeader = 'mcp-session-id';

/// The header with the protocol version, sent after `initialize`.
const String mcpProtocolHeader = 'mcp-protocol-version';

/// An MCP server over the Streamable HTTP transport, for Dox routes.
///
/// It answers `POST` with JSON (no SSE stream is needed for tools), says
/// `405` to `GET` (no server-to-client stream), and ends the session on
/// `DELETE`. Sessions are signed ids (see [SignedMcpSessions]), so every
/// isolate can serve every session.
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
  }) : sessions = sessions ?? SignedMcpSessions(),
       _tools = <String, McpTool>{for (McpTool tool in tools) tool.name: tool} {
    if (_tools.length != tools.length) {
      throw ArgumentError('Two MCP tools have the same name');
    }
  }

  /// The protocol versions this server speaks, newest first.
  static const List<String> protocolVersions = <String>[
    '2025-11-25',
    '2025-06-18',
    '2025-03-26',
    '2024-11-05',
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

  /// Called when a tool throws. The model gets an error result with the
  /// error text either way. Use it to log.
  final void Function(String tool, Object error, StackTrace stack)? onToolError;

  final Map<String, McpTool> _tools;

  /// The tools, in the order they were given.
  List<McpTool> get tools => _tools.values.toList();

  /// Answer one HTTP request of the transport. [auth] is handed to the
  /// tools (`context.auth`), like the user the app found. [scope] ties
  /// sessions to it (use the user id), so a session id works only for the
  /// one it was made for.
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
        'tools/list' => <String, dynamic>{
          'tools': <Map<String, dynamic>>[
            for (McpTool tool in _tools.values) tool.toJson(),
          ],
        },
        'tools/call' => await _callTool(params, context),
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
      'capabilities': <String, dynamic>{
        'tools': <String, dynamic>{'listChanged': false},
      },
      'serverInfo': <String, dynamic>{
        'name': name,
        'version': version,
        'title': ?title,
      },
      'instructions': ?instructions,
    };
  }

  Future<Map<String, dynamic>> _callTool(
    Object? params,
    McpContext context,
  ) async {
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
      String problems = <String>[
        for (ValidationIssue issue in parsed.issues)
          issue.dottedPath.isEmpty
              ? issue.message
              : '${issue.dottedPath}: ${issue.message}',
      ].join('; ');
      return McpToolResult.error(
        'Input validation error: Invalid arguments for tool $toolName: $problems',
      ).toJson();
    }

    try {
      McpToolResult result = await tool.call(parsed.value!, context);
      return result.toJson();
    } catch (error, stack) {
      onToolError?.call(toolName, error, stack);
      return McpToolResult.error('$error').toJson();
    }
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
