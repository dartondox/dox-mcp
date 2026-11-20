/// Model Context Protocol (MCP) server for the Dox framework.
///
/// Tools over the Streamable HTTP transport of MCP 2026-07-28, with
/// arguments checked by `dox_validation` schemas. Each request stands
/// alone, so every isolate can answer it and nothing is stored.
///
/// ```dart
/// import 'package:dox_core/dox_core.dart';
/// import 'package:dox_mcp/dox_mcp.dart';
///
/// final McpServer mcp = McpServer(
///   name: 'my-app',
///   version: '1.0.0',
///   tools: <McpTool>[
///     McpTool.of(
///       name: 'echo',
///       description: 'Say the text back.',
///       input: v.object(<String, Schema<Object?>>{'text': v.string()}),
///       handler: (Map<String, dynamic> args, McpContext context) {
///         return McpToolResult.text(args['text'] as String);
///       },
///     ),
///   ],
/// );
///
/// Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', (DoxRequest req) {
///   return mcp.handle(req);
/// });
/// ```
library;

export 'src/json_rpc.dart';
export 'src/mcp_server.dart';
export 'src/mcp_oauth.dart';
export 'src/mcp_sessions.dart';
export 'src/mcp_tool.dart' hide McpInputs;
