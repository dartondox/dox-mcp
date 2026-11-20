part of 'mcp_tool.dart';

/// Something a tool asks the user during a call (protocol 2026-07-28).
///
/// Make one input, keep it in a `static final` field, and use it two
/// times: [McpContext.answer] reads the answer, and
/// [McpToolResult.inputRequired] asks for it when there is no answer yet.
///
/// ```
/// static final McpInput<bool> confirmDelete =
///     McpInput.confirm('Delete this expense?');
///
/// Future<McpToolResult> call(
///   Map<String, dynamic> args,
///   McpContext context,
/// ) async {
///   McpAnswer<bool>? answer = context.answer(confirmDelete);
///   if (answer == null) {
///     return McpToolResult.inputRequired(<McpInput<Object?>>[confirmDelete]);
///   }
///   return switch (answer) {
///     McpAccepted<bool>(value: true) => _delete(args),
///     McpAccepted<bool>() ||
///     McpDeclined<bool>() ||
///     McpCancelled<bool>() => McpToolResult.text('Cancelled'),
///   };
/// }
/// ```
///
/// Each input gets a key in `inputRequests`. The key is a short hash of
/// the request JSON, so it is the same in every round. Two inputs with
/// the same JSON in one call have the same key, and
/// [McpToolResult.inputRequired] throws.
///
/// The built-in kinds use elicitation. For other kinds, extend
/// [McpCustomInput].
sealed class McpInput<T> {
  McpInput();

  /// A yes or no question. The answer is a `bool`.
  static McpInput<bool> confirm(String message) {
    return _ConfirmInput(message);
  }

  /// A line of text. The answer is a `String`.
  static McpInput<String> text(String message) {
    return _TextInput(message);
  }

  /// A number. The answer is a `num`.
  static McpInput<num> number(String message) {
    return _NumberInput(message);
  }

  /// One of [values], like `Color.values`. The client shows the enum
  /// names. The answer is the enum value.
  static McpInput<E> choice<E extends Enum>(String message, List<E> values) {
    if (values.isEmpty) {
      throw ArgumentError.value(values, 'values', 'needs at least one value');
    }
    return _ChoiceInput<E>(message, values);
  }

  /// A form from a `@Dto` class, like `McpInput.form('New expense',
  /// NewExpense.schema)`. The answer is the DTO object, checked by the
  /// DTO rules.
  ///
  /// MCP forms only have flat fields: text, numbers, booleans, enums and
  /// lists of enum values. A DTO with a nested object or another list
  /// throws an [ArgumentError] here. A DTO with async rules (like
  /// `@Unique`) throws too, because the answer is read without `await`.
  /// Check those in the tool.
  static McpInput<T> form<T>(String message, DtoSchema<T> dto) {
    return _FormInput<T>(message, dto);
  }

  /// Send the user to [url], for things that must not pass through the
  /// client, like a password or a sign-in to another service.
  ///
  /// `McpAccepted` only means the user agreed to open the page. It does
  /// not mean they finished it. The app must check that itself, like in
  /// its database. Never put secrets or a signed-in link in [url].
  static McpInput<void> url(String message, String url) {
    Uri? uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError.value(url, 'url', 'must be a full URL');
    }
    return _UrlInput(message, url);
  }

  /// The request as it goes in `inputRequests`.
  Map<String, Object?> _request();

  /// True when the client said it can answer this input.
  bool _supportedBy(McpClientCapabilities capabilities);

  /// The client capability this input needs, for the error when the
  /// client does not have it.
  Map<String, Object?> get _requiredCapabilities;

  /// The answer from the client [result]. Null when it cannot be read.
  McpAnswer<T>? _answer(Map<String, Object?> result);

  late final String _key = 'i_${McpRequestState.hashOf(_request())}';
}

/// An input kind that this package does not have yet, like a future MCP
/// request. Extend it. This is the one place with a raw map.
///
/// ```
/// class ListRoots extends McpCustomInput<List<String>> {
///   @override
///   String get method => 'roots/list';
///
///   @override
///   List<String> get capability => <String>['roots'];
///
///   @override
///   Map<String, Object?> toJson() {
///     return <String, Object?>{};
///   }
///
///   @override
///   List<String> parse(Map<String, Object?> result) {
///     return <String>[
///       for (Object? root in result['roots'] as List<Object?>)
///         (root as Map<String, Object?>)['uri'] as String,
///     ];
///   }
/// }
/// ```
abstract class McpCustomInput<T> extends McpInput<T> {
  McpCustomInput();

  /// The request method, like `sampling/createMessage`.
  String get method;

  /// The path of the client capability this input needs, like
  /// `<String>['sampling']` or `<String>['extensions', 'my.extension']`.
  /// The server only asks when the client sent it.
  List<String> get capability;

  /// The `params` of the request.
  Map<String, Object?> toJson();

  /// The answer from the client [result]. Throw a [FormatException] (or
  /// any [Exception]) when it is not a good answer. Then
  /// [McpContext.answer] gives null, and the tool asks again. A result
  /// with `action` `decline` or `cancel` is an [McpDeclined] or an
  /// [McpCancelled], and does not reach this method.
  T parse(Map<String, Object?> result);

  @override
  Map<String, Object?> _request() {
    return <String, Object?>{'method': method, 'params': toJson()};
  }

  @override
  bool _supportedBy(McpClientCapabilities capabilities) {
    return capabilities.has(capability);
  }

  @override
  Map<String, Object?> get _requiredCapabilities {
    Map<String, Object?> json = <String, Object?>{};
    for (String part in capability.reversed) {
      json = <String, Object?>{part: json};
    }
    return json;
  }

  @override
  McpAnswer<T>? _answer(Map<String, Object?> result) {
    switch (result['action']) {
      case 'decline':
        return McpDeclined<T>();
      case 'cancel':
        return McpCancelled<T>();
    }
    try {
      return McpAccepted<T>(parse(result));
    } on Exception {
      return null;
    } on TypeError {
      // a bad cast of the client JSON is a bad answer too
      return null;
    }
  }
}

/// The answer to an [McpInput].
sealed class McpAnswer<T> {
  const McpAnswer();
}

/// The user answered. [value] is the answer.
final class McpAccepted<T> extends McpAnswer<T> {
  const McpAccepted(this.value);

  final T value;
}

/// The user said no.
final class McpDeclined<T> extends McpAnswer<T> {
  const McpDeclined();
}

/// The user closed the question without a choice.
final class McpCancelled<T> extends McpAnswer<T> {
  const McpCancelled();
}

/// An `elicitation/create` input.
abstract class _ElicitInput<T> extends McpInput<T> {
  _ElicitInput(this.message);

  final String message;

  /// The `params` of the request, without the message.
  Map<String, Object?> get _params;

  /// The value from the `content` of an accepted answer. Throws a
  /// [FormatException] when it is not a good value.
  T _value(Object? content);

  bool get _isUrl => false;

  @override
  Map<String, Object?> _request() {
    return <String, Object?>{
      'method': 'elicitation/create',
      'params': <String, Object?>{..._params, 'message': message},
    };
  }

  @override
  bool _supportedBy(McpClientCapabilities capabilities) {
    return _isUrl ? capabilities.elicitationUrl : capabilities.elicitationForm;
  }

  @override
  Map<String, Object?> get _requiredCapabilities {
    return <String, Object?>{
      'elicitation': <String, Object?>{
        _isUrl ? 'url' : 'form': <String, Object?>{},
      },
    };
  }

  @override
  McpAnswer<T>? _answer(Map<String, Object?> result) {
    switch (result['action']) {
      case 'accept':
        try {
          return McpAccepted<T>(_value(result['content']));
        } on FormatException {
          return null;
        }
      case 'decline':
        return McpDeclined<T>();
      case 'cancel':
        return McpCancelled<T>();
    }
    return null;
  }
}

/// A form with one field, `value`.
abstract class _FieldInput<T> extends _ElicitInput<T> {
  _FieldInput(super.message);

  /// The JSON Schema of the field.
  Map<String, Object?> get _field;

  /// The value of the field. Throws a [FormatException] when it is bad.
  T _read(Object? value);

  @override
  Map<String, Object?> get _params {
    return <String, Object?>{
      'mode': 'form',
      'requestedSchema': <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{'value': _field},
        'required': <String>['value'],
      },
    };
  }

  @override
  T _value(Object? content) {
    if (content is! Map) throw const FormatException('no content');
    return _read(content['value']);
  }
}

class _ConfirmInput extends _FieldInput<bool> {
  _ConfirmInput(super.message);

  @override
  Map<String, Object?> get _field {
    return <String, Object?>{'type': 'boolean'};
  }

  @override
  bool _read(Object? value) {
    if (value is! bool) throw const FormatException('not a boolean');
    return value;
  }
}

class _TextInput extends _FieldInput<String> {
  _TextInput(super.message);

  @override
  Map<String, Object?> get _field {
    return <String, Object?>{'type': 'string'};
  }

  @override
  String _read(Object? value) {
    if (value is! String) throw const FormatException('not a string');
    return value;
  }
}

class _NumberInput extends _FieldInput<num> {
  _NumberInput(super.message);

  @override
  Map<String, Object?> get _field {
    return <String, Object?>{'type': 'number'};
  }

  @override
  num _read(Object? value) {
    if (value is! num) throw const FormatException('not a number');
    return value;
  }
}

class _ChoiceInput<E extends Enum> extends _FieldInput<E> {
  _ChoiceInput(super.message, this.values);

  final List<E> values;

  @override
  Map<String, Object?> get _field {
    return <String, Object?>{
      'type': 'string',
      'enum': <String>[for (E value in values) value.name],
    };
  }

  @override
  E _read(Object? value) {
    for (E item in values) {
      if (item.name == value) return item;
    }
    throw const FormatException('not one of the choices');
  }
}

class _FormInput<T> extends _ElicitInput<T> {
  _FormInput(super.message, this.dto) : _schema = _flatSchema(dto);

  final DtoSchema<T> dto;

  final Map<String, Object?> _schema;

  @override
  Map<String, Object?> get _params {
    return <String, Object?>{'mode': 'form', 'requestedSchema': _schema};
  }

  @override
  T _value(Object? content) {
    if (content is! Map) throw const FormatException('no content');
    ParseResult<T> result;
    try {
      result = dto.safeParse(content);
    } on StateError {
      throw StateError(
        'McpInput.form: DTO ${dto.name} has an async validate(). A form '
        'answer is checked without await. Check it in the tool.',
      );
    }
    if (!result.success) throw const FormatException('the DTO rules failed');
    return result.value as T;
  }

  /// The JSON Schema keys an MCP form field may have.
  static const Set<String> _allowed = <String>{
    'type',
    'title',
    'description',
    'minLength',
    'maxLength',
    'minimum',
    'maximum',
    'default',
    'enum',
    'oneOf',
    'minItems',
    'maxItems',
  };

  static const Set<String> _formats = <String>{
    'email',
    'uri',
    'date',
    'date-time',
  };

  /// The `requestedSchema` of [dto]. Throws when a field is not flat.
  static Map<String, Object?> _flatSchema(DtoSchema<Object?> dto) {
    if (dto.isAsync) {
      throw ArgumentError.value(
        dto.name,
        'dto',
        'has async rules (like @Unique). A form answer is checked without '
            'await. Check them in the tool',
      );
    }
    Map<String, dynamic> json = dto.toJsonSchema();
    Object? properties = json['properties'];
    Map<String, Object?> fields = <String, Object?>{};
    if (properties is Map) {
      for (MapEntry<dynamic, dynamic> entry in properties.entries) {
        fields['${entry.key}'] = _flatField(
          dto.name,
          '${entry.key}',
          entry.value,
        );
      }
    }
    Object? required = json['required'];
    return <String, Object?>{
      'type': 'object',
      'properties': fields,
      if (required is List && required.isNotEmpty)
        'required': <String>[for (Object? name in required) '$name'],
    };
  }

  static Map<String, Object?> _flatField(
    String dtoName,
    String name,
    Object? field,
  ) {
    ArgumentError notFlat = ArgumentError(
      'McpInput.form: field "$name" of $dtoName is not flat. MCP forms only '
      'allow text, numbers, booleans, enums and lists of enum values.',
    );
    if (field is! Map) throw notFlat;
    Object? type = field['type'];
    if (type is List) {
      List<Object?> types = <Object?>[
        for (Object? item in type)
          if (item != 'null') item,
      ];
      type = types.length == 1 ? types.first : null;
    }
    Map<String, Object?> out = <String, Object?>{
      for (MapEntry<dynamic, dynamic> entry in field.entries)
        if (_allowed.contains(entry.key)) '${entry.key}': entry.value,
    };
    out['type'] = type;
    Object? format = field['format'];
    if (format is String && _formats.contains(format)) out['format'] = format;
    switch (type) {
      case 'string' || 'number' || 'integer' || 'boolean':
        return out;
      case 'array':
        Object? items = field['items'];
        if (items is Map && (items['enum'] is List || items['anyOf'] is List)) {
          out['items'] = items;
          return out;
        }
    }
    throw notFlat;
  }
}

class _UrlInput extends _ElicitInput<void> {
  _UrlInput(super.message, this.url);

  final String url;

  @override
  bool get _isUrl => true;

  @override
  Map<String, Object?> get _params {
    return <String, Object?>{'mode': 'url', 'url': url};
  }

  @override
  void _value(Object? content) {}
}

/// Helpers for the server. Not exported.
class McpInputs {
  /// The `inputRequests` key of [input].
  static String keyOf(McpInput<Object?> input) {
    return input._key;
  }

  /// The request of [input], as it goes in `inputRequests`.
  static Map<String, Object?> requestOf(McpInput<Object?> input) {
    return input._request();
  }

  /// True when the client can answer [input].
  static bool supports(
    McpClientCapabilities capabilities,
    McpInput<Object?> input,
  ) {
    return input._supportedBy(capabilities);
  }

  /// The client capability [input] needs.
  static Map<String, Object?> requiredCapabilitiesOf(McpInput<Object?> input) {
    return input._requiredCapabilities;
  }

  /// [context] with the client answers, by input key.
  static McpContext withAnswers(
    McpContext context,
    Map<String, Map<String, Object?>> answers,
  ) {
    return McpContext._withAnswers(context, answers);
  }

  /// The client capabilities from the JSON the client sent.
  static McpClientCapabilities capabilitiesOf(Map<dynamic, dynamic> json) {
    return McpClientCapabilities._fromJson(json);
  }
}
