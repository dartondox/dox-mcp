/// JSON-RPC 2.0 error codes that MCP uses.
class JsonRpcCode {
  /// The body is not JSON.
  static const int parseError = -32700;

  /// The JSON is not a valid JSON-RPC message.
  static const int invalidRequest = -32600;

  /// No such method.
  static const int methodNotFound = -32601;

  /// Bad params, like an unknown tool.
  static const int invalidParams = -32602;

  /// The server failed.
  static const int internalError = -32603;

  /// A transport error that is not in JSON-RPC, like a missing session.
  /// The MCP SDKs use it for HTTP level errors.
  static const int serverError = -32000;
}

/// An error that becomes a JSON-RPC error response.
/// ```
/// throw McpError(JsonRpcCode.invalidParams, 'Tool x not found');
/// ```
class McpError implements Exception {
  final int code;
  final String message;
  final Object? data;

  const McpError(this.code, this.message, [this.data]);

  /// The `error` member of the response.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'code': code,
      'message': message,
      if (data != null) 'data': data,
    };
  }

  @override
  String toString() => 'McpError($code): $message';
}

/// Builds JSON-RPC 2.0 messages.
class JsonRpc {
  static Map<String, dynamic> result(Object? id, Object? result) {
    return <String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result};
  }

  static Map<String, dynamic> error(Object? id, McpError error) {
    return <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'error': error.toJson(),
    };
  }

  /// A request has a `method` and an `id`.
  static bool isRequest(Object? message) {
    return message is Map &&
        message['method'] is String &&
        message.containsKey('id') &&
        message['id'] != null;
  }

  /// A notification has a `method` and no `id`.
  static bool isNotification(Object? message) {
    return message is Map &&
        message['method'] is String &&
        (!message.containsKey('id') || message['id'] == null);
  }

  /// A response (to a request the server sent) has an `id` and a
  /// `result` or an `error`, and no `method`.
  static bool isResponse(Object? message) {
    return message is Map &&
        message['method'] == null &&
        message.containsKey('id') &&
        (message.containsKey('result') || message.containsKey('error'));
  }

  /// A valid JSON-RPC 2.0 id: a string or a number.
  static bool isValidId(Object? id) => id is String || id is num;
}
