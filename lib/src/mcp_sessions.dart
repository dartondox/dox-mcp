import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Digest, Hmac, sha256;
import 'package:dox_core/dox_core.dart';

/// Makes and checks MCP session ids.
///
/// The server calls [create] for each `initialize`, and [isValid] for
/// every later request of the session. [scope] ties a session to
/// something of the app, like the user id, so one user cannot use the
/// session of another. Use the same [scope] for every request.
abstract class McpSessions {
  const McpSessions();

  /// A new session id.
  String create(String scope);

  /// True when [id] is a session that [create] made for [scope], and it
  /// was not ended.
  Future<bool> isValid(String id, String scope);

  /// The client ended the session (`DELETE`).
  Future<void> end(String id);
}

/// Session ids signed with HMAC-SHA256, so no store is needed.
///
/// Dox runs many isolates, and they share no memory. A session made on one
/// isolate must work on the others, and after a restart. A signed id does:
/// any isolate with the same key can check it.
///
/// The key comes from `APP_KEY` (label `dox:mcp`), unless you give one.
///
/// A signed id cannot be ended by itself. `DELETE` answers `200`, and
/// the client forgets the id. Give [ended] (a cache store, like
/// `Cache().store('file')` or Redis) to remember ended ids too.
class SignedMcpSessions extends McpSessions {
  SignedMcpSessions({
    this._key,
    this.ended,
    this.endedFor = const Duration(days: 30),
  });

  /// The label of the key made from `APP_KEY`.
  static const String keyLabel = 'dox:mcp';

  final List<int>? _key;

  /// Remembers ended ids, when set.
  final Cache? ended;

  /// How long an ended id is remembered.
  final Duration endedFor;

  static final Random _random = Random.secure();

  List<int> get _secret => _key ?? KeyDerivation.forAppKey(keyLabel);

  @override
  String create(String scope) {
    Uint8List nonce = Uint8List.fromList(
      List<int>.generate(16, (_) => _random.nextInt(256)),
    );
    String id = base64Url.encode(nonce).replaceAll('=', '');
    return '$id.${_sign(id, scope)}';
  }

  @override
  Future<bool> isValid(String id, String scope) async {
    int dot = id.indexOf('.');
    if (dot <= 0 || dot == id.length - 1) return false;
    String nonce = id.substring(0, dot);
    String signature = id.substring(dot + 1);
    if (!Hash.equals(signature, _sign(nonce, scope))) return false;
    Cache? store = ended;
    if (store == null) return true;
    return await store.get(_endedKey(id)) == null;
  }

  @override
  Future<void> end(String id) async {
    await ended?.put(_endedKey(id), true, duration: endedFor);
  }

  String _sign(String nonce, String scope) {
    Digest digest = Hmac(
      sha256,
      _secret,
    ).convert(utf8.encode('$scope\n$nonce'));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  static String _endedKey(String id) {
    return 'dox_mcp:ended:${sha256.convert(utf8.encode(id))}';
  }
}
