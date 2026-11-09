import 'dart:async';
import 'dart:convert';

import 'package:dox_core/dox_core.dart';

/// What a tool call knows about its request.
class McpContext {
  const McpContext({
    required this.request,
    required this.sessionId,
    required this.protocolVersion,
    this.auth,
  });

  /// The HTTP request of the call.
  final DoxRequest request;

  /// The MCP session of the call.
  final String sessionId;

  /// The protocol version the session uses, like `2025-06-18`.
  final String protocolVersion;

  /// What the app passed to `McpServer.handle(auth: ...)`, like the user.
  final Object? auth;

  /// [auth] as a [T]. Throws a [StateError] when it is not one.
  T authAs<T>() {
    Object? value = auth;
    if (value is T) return value;
    throw StateError(
      'The MCP request has no $T (auth is ${value.runtimeType})',
    );
  }
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
  const McpToolResult(this.content, {this.isError = false, this.structured});

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
