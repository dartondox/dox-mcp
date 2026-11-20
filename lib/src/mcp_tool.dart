import 'dart:async';
import 'dart:convert';

import 'package:dox_core/dox_core.dart';
import 'package:dox_mcp/src/mcp_request_state.dart';

part 'mcp_input.dart';

/// What a tool call knows about its request.
class McpContext {
  const McpContext({
    required this.request,
    required this.sessionId,
    required this.protocolVersion,
    this.auth,
    this.clientCapabilities,
    this.clientInfo,
  }) : _answers = const <String, Map<String, Object?>>{};

  McpContext._withAnswers(McpContext other, this._answers)
    : request = other.request,
      sessionId = other.sessionId,
      protocolVersion = other.protocolVersion,
      auth = other.auth,
      clientCapabilities = other.clientCapabilities,
      clientInfo = other.clientInfo;

  /// The HTTP request of the call.
  final DoxRequest request;

  /// The MCP session of the call.
  ///
  /// Protocol 2026-07-28 has no sessions. Then it is an empty string.
  final String sessionId;

  /// The protocol version of the call, like `2025-06-18` or `2026-07-28`.
  final String protocolVersion;

  /// What the client can do. Protocol 2026-07-28 sends it with every
  /// request. Null for older versions.
  final McpClientCapabilities? clientCapabilities;

  /// The name and version of the client. Protocol 2026-07-28 sends it
  /// with a request when the client wants to. Null for older versions,
  /// and when the client did not send it. The client says this about
  /// itself, so do not trust it for security.
  final McpClientInfo? clientInfo;

  /// What the app passed to `McpServer.handle(auth: ...)`, like the user.
  final Object? auth;

  /// The client answers of a retried call, by input key.
  final Map<String, Map<String, Object?>> _answers;

  /// The user's answer to [input], or null when there is none yet. Then
  /// return `McpToolResult.inputRequired(<McpInput>[input])` to ask.
  ///
  /// It is also null when the answer cannot be read, like a wrong type
  /// or a form that fails the DTO rules. Then the tool asks again.
  ///
  /// Only protocol 2026-07-28 has answers. Older clients always get null.
  McpAnswer<T>? answer<T>(McpInput<T> input) {
    Map<String, Object?>? result = _answers[input._key];
    if (result == null) return null;
    return input._answer(result);
  }

  /// [auth] as a [T]. Throws a [StateError] when it is not one.
  T authAs<T>() {
    Object? value = auth;
    if (value is T) return value;
    throw StateError(
      'The MCP request has no $T (auth is ${value.runtimeType})',
    );
  }
}

/// What an MCP client can do, from
/// `_meta["io.modelcontextprotocol/clientCapabilities"]`.
class McpClientCapabilities {
  const McpClientCapabilities({
    this.roots = false,
    this.sampling = false,
    this.elicitation = false,
    this.extensions = const <String>{},
  }) : _json = const <String, Object?>{};

  McpClientCapabilities._fromJson(this._json)
    : roots = _json['roots'] is Map,
      sampling = _json['sampling'] is Map,
      elicitation = _json['elicitation'] is Map,
      extensions = _json['extensions'] is Map
          ? <String>{
              for (Object? key
                  in (_json['extensions'] as Map<dynamic, dynamic>).keys)
                '$key',
            }
          : const <String>{};

  /// The capabilities as the client sent them.
  final Map<dynamic, dynamic> _json;

  /// The client can list its roots.
  final bool roots;

  /// The client can ask its model for a completion.
  final bool sampling;

  /// The client can ask the user for input.
  final bool elicitation;

  /// The ids of the MCP extensions the client supports, like
  /// `io.modelcontextprotocol/ui`.
  final Set<String> extensions;

  /// The client can show a form. An empty `elicitation` object means
  /// form mode too.
  bool get elicitationForm {
    if (!elicitation) return false;
    Object? modes = _json['elicitation'];
    if (modes is! Map) return true;
    return modes.containsKey('form') || !modes.containsKey('url');
  }

  /// The client can send the user to a URL.
  bool get elicitationUrl {
    Object? modes = _json['elicitation'];
    return modes is Map && modes['url'] is Map;
  }

  /// True when the client sent an object at [path], like
  /// `<String>['sampling', 'tools']`. It reads what the client sent, so
  /// it is false for capabilities made in code.
  bool has(List<String> path) {
    Object? node = _json;
    for (String part in path) {
      if (node is! Map) return false;
      node = node[part];
    }
    return node is Map;
  }
}

/// The name and version of an MCP client, from
/// `_meta["io.modelcontextprotocol/clientInfo"]`.
class McpClientInfo {
  const McpClientInfo({
    required this.name,
    required this.version,
    this.title,
    this.description,
    this.websiteUrl,
  });

  final String name;
  final String version;

  /// A name for people. Optional.
  final String? title;

  final String? description;
  final String? websiteUrl;
}

/// One item of a tool result. MCP has text, image, audio and resource
/// items. Most tools only need [McpContent.text].
class McpContent {
  const McpContent(this.json);

  /// A text item.
  factory McpContent.text(String text) {
    return McpContent(<String, dynamic>{'type': 'text', 'text': text});
  }

  /// An image item. [data] is base64.
  factory McpContent.image(String data, String mimeType) {
    return McpContent(<String, dynamic>{
      'type': 'image',
      'data': data,
      'mimeType': mimeType,
    });
  }

  /// The item as MCP sends it.
  final Map<String, dynamic> json;
}

/// The result of a tool call.
class McpToolResult {
  const McpToolResult(this.content, {this.isError = false, this.structured})
    : inputs = const <McpInput<Object?>>[];

  McpToolResult._inputRequired(this.inputs)
    : content = <McpContent>[
        McpContent.text(
          'This tool needs to ask the user a question. That needs MCP '
          'protocol 2026-07-28. Update the MCP client and try again.',
        ),
      ],
      isError = true,
      structured = null;

  /// Ask the user for [inputs], then the client calls the tool again
  /// with the answers. Read them with [McpContext.answer].
  ///
  /// Only clients of protocol 2026-07-28 can answer. An older client
  /// gets an error result that says so.
  ///
  /// Throws an [ArgumentError] when [inputs] is empty, or when two
  /// inputs are the same request.
  factory McpToolResult.inputRequired(List<McpInput<Object?>> inputs) {
    if (inputs.isEmpty) {
      throw ArgumentError.value(inputs, 'inputs', 'needs at least one input');
    }
    Set<String> keys = <String>{};
    for (McpInput<Object?> input in inputs) {
      if (!keys.add(input._key)) {
        throw ArgumentError(
          'McpToolResult.inputRequired: two inputs ask the same thing. '
          'Give each one its own message.',
        );
      }
    }
    return McpToolResult._inputRequired(
      List<McpInput<Object?>>.unmodifiable(inputs),
    );
  }

  /// One text item.
  factory McpToolResult.text(String text) {
    return McpToolResult(<McpContent>[McpContent.text(text)]);
  }

  /// One text item, marked as an error. The model sees the text and can
  /// try again. Use it for errors the model can fix, like a bad id.
  factory McpToolResult.error(String text) {
    return McpToolResult(<McpContent>[McpContent.text(text)], isError: true);
  }

  /// The error result for bad arguments: one line with each problem as
  /// `field: message`, so the model can fix the call and try again.
  factory McpToolResult.invalidArguments(
    String tool,
    List<ValidationIssue> issues,
  ) {
    String problems = <String>[
      for (ValidationIssue issue in issues)
        issue.dottedPath.isEmpty
            ? issue.message
            : '${issue.dottedPath}: ${issue.message}',
    ].join('; ');
    return McpToolResult.error(
      'Input validation error: Invalid arguments for tool $tool: $problems',
    );
  }

  /// [value] as JSON text, and as `structuredContent` when it is a map.
  factory McpToolResult.json(Object? value) {
    return McpToolResult(<McpContent>[
      McpContent.text(jsonEncode(value)),
    ], structured: value is Map<String, dynamic> ? value : null);
  }

  final List<McpContent> content;
  final bool isError;

  /// `structuredContent`, for tools with an output schema.
  final Map<String, dynamic>? structured;

  /// What the tool asks the user. Empty for a normal result. See
  /// [McpToolResult.inputRequired].
  final List<McpInput<Object?>> inputs;

  /// The result as MCP sends it.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'content': <Map<String, dynamic>>[for (McpContent c in content) c.json],
      if (structured != null) 'structuredContent': structured,
      if (isError) 'isError': true,
    };
  }
}

/// One MCP tool. Extend it, or use [McpTool.of] for a small one.
///
/// [input] is a `dox_validation` object schema. It is the `inputSchema`
/// the client sees (as JSON Schema), and the arguments are checked with
/// it before [call] runs. Use `.describe()` on a field to explain it to
/// the model.
/// ```
/// class AddNumbers extends McpTool {
///   @override
///   String get name => 'add';
///
///   @override
///   String get description => 'Add two numbers.';
///
///   @override
///   ObjectSchema get input => v.object(<String, Schema<Object?>>{
///     'a': v.num().describe('The first number.'),
///     'b': v.num(),
///   });
///
///   @override
///   McpToolResult call(Map<String, dynamic> args, McpContext context) {
///     return McpToolResult.text('${args['a'] + args['b']}');
///   }
/// }
/// ```
abstract class McpTool {
  const McpTool();

  /// A tool from a function.
  factory McpTool.of({
    required String name,
    required String description,
    ObjectSchema? input,
    String? title,
    Map<String, dynamic>? annotations,
    required FutureOr<McpToolResult> Function(
      Map<String, dynamic> args,
      McpContext context,
    )
    handler,
  }) = _FunctionTool;

  /// The tool name, like `add_expense`. Unique in the server.
  String get name;

  /// What the tool does, for the model.
  String get description;

  /// A name for people. Optional.
  String? get title => null;

  /// The arguments. No arguments: an empty object.
  ObjectSchema get input => v.object(<String, Schema<Object?>>{});

  /// MCP tool annotations, like `{'readOnlyHint': true}`. Optional.
  Map<String, dynamic>? get annotations => null;

  /// Run the tool. [args] are already checked by [input].
  FutureOr<McpToolResult> call(Map<String, dynamic> args, McpContext context);

  /// The tool as `tools/list` sends it.
  Map<String, dynamic> toJson() {
    Map<String, dynamic> schema = <String, dynamic>{
      ...input.toJsonSchema(),
      'type': 'object',
    };
    schema.putIfAbsent('properties', () => <String, dynamic>{});
    return <String, dynamic>{
      'name': name,
      'title': ?title,
      'description': description,
      'inputSchema': schema,
      'annotations': ?annotations,
    };
  }
}

class _FunctionTool extends McpTool {
  const _FunctionTool({
    required this.name,
    required this.description,
    this._input,
    this.title,
    this.annotations,
    required this.handler,
  });

  @override
  final String name;

  @override
  final String description;

  @override
  final String? title;

  @override
  final Map<String, dynamic>? annotations;

  final ObjectSchema? _input;

  final FutureOr<McpToolResult> Function(
    Map<String, dynamic> args,
    McpContext context,
  )
  handler;

  @override
  ObjectSchema get input => _input ?? super.input;

  @override
  FutureOr<McpToolResult> call(Map<String, dynamic> args, McpContext context) {
    return handler(args, context);
  }
}

/// An MCP tool that takes a `@Dto` class as its input.
///
/// The `inputSchema` comes from the DTO, so `@Describe`, `@Length` and the
/// other annotations show up for the model. The arguments are checked the
/// same way as a DTO in a controller, async rules like `@Unique` too.
/// Bad arguments give an error result with each problem, not a JSON-RPC
/// error, so the model can fix them and try again.
///
/// Route path params are not passed. MCP has none.
///
/// ```
/// class CreateCategory extends McpDtoTool<NewCategory> {
///   @override
///   String get name => 'create_category';
///
///   @override
///   String get description => 'Add a category.';
///
///   @override
///   DtoSchema<NewCategory> get dto => NewCategory.schema;
///
///   @override
///   Future<McpToolResult> handle(
///     NewCategory input,
///     McpContext context,
///   ) async {
///     Category category = await Category.create(dto.toMap(input));
///     return McpToolResult.json(category.toJson());
///   }
/// }
/// ```
abstract class McpDtoTool<T> extends McpTool {
  const McpDtoTool();

  /// The DTO schema, like `NewCategory.schema` or
  /// `$NewCategoryDto`.
  DtoSchema<T> get dto;

  /// Run the tool with the checked DTO.
  FutureOr<McpToolResult> handle(T input, McpContext context);

  /// Keeps every key. [call] checks them with [dto].
  @override
  ObjectSchema get input => v.object(<String, Schema<Object?>>{}).passthrough();

  @override
  Future<McpToolResult> call(
    Map<String, dynamic> args,
    McpContext context,
  ) async {
    // the same steps as RequestValidator.validateDto for a JSON body
    ParseResult<T> result = await dto.run(
      args,
      DtoState(
        root: args,
        resolver: Dox().messages,
        locale: context.request.locale,
      ),
    );
    if (!result.success) {
      return McpToolResult.invalidArguments(name, result.issues);
    }
    return handle(result.value as T, context);
  }

  @override
  Map<String, dynamic> toJson() {
    Map<String, dynamic> json = super.toJson();
    Map<String, dynamic> schema = <String, dynamic>{
      ...dto.toJsonSchema(),
      'type': 'object',
    };
    schema.putIfAbsent('properties', () => <String, dynamic>{});
    json['inputSchema'] = schema;
    return json;
  }
}
