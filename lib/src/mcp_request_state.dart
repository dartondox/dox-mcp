import 'dart:convert';

import 'package:crypto/crypto.dart' show Digest, Hmac, sha256;
import 'package:dox_core/dox_core.dart';
import 'package:dox_mcp/src/json_rpc.dart';

/// What a checked `requestState` holds.
class McpStateContent {
  const McpStateContent(this.asked, this.answers);

  /// The keys of the inputs the server asked for in the last round.
  final List<String> asked;

  /// The answers of earlier rounds, by input key.
  final Map<String, Map<String, Object?>> answers;
}

/// Makes and checks the `requestState` of a multi round-trip tool call
/// (protocol 2026-07-28).
///
/// The client sends the state back, so it is attacker-controlled. The
/// state is signed with HMAC-SHA256. The signature covers the scope, the
/// tool name, a hash of the arguments and an expiry time. So a state only
/// works for the same user, the same tool, the same arguments, and only
/// for a short time.
///
/// The state is signed, not encrypted. It holds the answers of earlier
/// rounds, and the client already knows them.
///
/// A state can be used more than once until it expires. A tool that must
/// run at most once (like a payment) must check that itself.
class McpRequestState {
  McpRequestState({this._key, this.ttl = const Duration(minutes: 5)});

  /// The label of the key made from `APP_KEY`.
  static const String keyLabel = 'dox:mcp-state';

  final List<int>? _key;

  /// How long a state works after the server sends it.
  final Duration ttl;

  List<int> get _secret => _key ?? KeyDerivation.forAppKey(keyLabel);

  /// A new state. [now] is for tests.
  String sign({
    required String scope,
    required String tool,
    required Object? args,
    required List<String> asked,
    required Map<String, Map<String, Object?>> answers,
    DateTime? now,
  }) {
    DateTime time = now ?? DateTime.now();
    Map<String, Object?> payload = <String, Object?>{
      't': tool,
      'a': hashOf(args),
      'e': time.add(ttl).millisecondsSinceEpoch,
      'k': asked,
      'r': answers,
    };
    String body = base64Url
        .encode(utf8.encode(jsonEncode(payload)))
        .replaceAll('=', '');
    return '$body.${_signature(scope, body)}';
  }

  /// The content of [state]. Throws an [McpError] when the signature is
  /// wrong, when it was made for another scope, tool or arguments, or
  /// when it expired. [now] is for tests.
  McpStateContent verify(
    String state, {
    required String scope,
    required String tool,
    required Object? args,
    DateTime? now,
  }) {
    int dot = state.lastIndexOf('.');
    if (dot <= 0 ||
        !Hash.equals(
          state.substring(dot + 1),
          _signature(scope, state.substring(0, dot)),
        )) {
      throw _invalid('requestState is not valid');
    }
    Object? payload;
    try {
      payload = jsonDecode(
        utf8.decode(
          base64Url.decode(base64.normalize(state.substring(0, dot))),
        ),
      );
    } on FormatException {
      throw _invalid('requestState is not valid');
    }
    if (payload is! Map ||
        payload['e'] is! int ||
        payload['k'] is! List ||
        payload['r'] is! Map) {
      throw _invalid('requestState is not valid');
    }
    if (payload['t'] != tool || payload['a'] != hashOf(args)) {
      throw _invalid('requestState is for another tool call');
    }
    int expires = payload['e'] as int;
    if ((now ?? DateTime.now()).millisecondsSinceEpoch > expires) {
      throw _invalid('requestState has expired, call the tool again');
    }
    Map<String, Map<String, Object?>> answers =
        <String, Map<String, Object?>>{};
    for (MapEntry<dynamic, dynamic> entry
        in (payload['r'] as Map<dynamic, dynamic>).entries) {
      Object? value = entry.value;
      if (value is Map) answers['${entry.key}'] = value.cast<String, Object?>();
    }
    return McpStateContent(<String>[
      for (Object? key in payload['k'] as List<dynamic>) '$key',
    ], answers);
  }

  String _signature(String scope, String body) {
    Digest digest = Hmac(sha256, _secret).convert(utf8.encode('$scope\n$body'));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  static McpError _invalid(String reason) {
    return McpError(JsonRpcCode.invalidParams, 'Invalid params: $reason');
  }

  /// A short hash of [value] as JSON, with map keys sorted. So the same
  /// value gives the same hash, in any key order.
  static String hashOf(Object? value) {
    Digest digest = sha256.convert(utf8.encode(jsonEncode(_sorted(value))));
    return base64Url.encode(digest.bytes).substring(0, 22);
  }

  static Object? _sorted(Object? value) {
    if (value is Map) {
      List<String> keys = <String>[for (Object? key in value.keys) '$key']
        ..sort();
      return <String, Object?>{
        for (String key in keys) key: _sorted(value[key]),
      };
    }
    if (value is List) {
      return <Object?>[for (Object? item in value) _sorted(item)];
    }
    return value;
  }
}
