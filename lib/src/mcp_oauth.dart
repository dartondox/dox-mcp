import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Digest, Hmac, sha256;
import 'package:dox_core/dox_core.dart';

/// An OAuth error. The client gets `{ error, error_description }`.
class McpOAuthException implements Exception {
  const McpOAuthException(this.error, this.description, {this.status = 400});

  /// The OAuth error code, like `invalid_grant`.
  final String error;

  /// Text for people.
  final String description;

  /// The HTTP status.
  final int status;

  Map<String, String> toJson() {
    return <String, String>{'error': error, 'error_description': description};
  }

  @override
  String toString() => 'McpOAuthException($error): $description';
}

/// A client that registered with `POST /oauth/register`.
class McpOAuthClient {
  const McpOAuthClient(this.id, this.name, this.redirectUris);

  /// The signed `client_id`. It holds [name] and [redirectUris].
  final String id;

  /// The name the client gave, like `Claude`.
  final String name;

  /// The only addresses a code may be sent to.
  final List<String> redirectUris;
}

/// A person said yes to a client. The app makes a token for it.
class McpOAuthGrant {
  const McpOAuthGrant({
    required this.subject,
    required this.client,
    required this.redirectUri,
  });

  /// Who said yes, as the app gave it to [McpOAuth.approve]. Like a user id.
  final String subject;

  final McpOAuthClient client;

  /// Where the code went. Its host is a good part of a token's name.
  final String redirectUri;
}

/// The app's part of the sign-in: its own tokens.
///
/// The app decides how a token looks, where it is kept, and how it is
/// revoked. Keep only a hash of it.
abstract class McpOAuthTokens {
  const McpOAuthTokens();

  /// A new access token for [grant]. Throw an [McpOAuthException] to say
  /// no, like when the person has too many clients.
  Future<String> issue(McpOAuthGrant grant);

  /// What the token stands for (the `auth` of [McpServer.handle]), or null
  /// when it is not a valid token.
  Future<Object?> verify(String token);
}

/// OAuth 2.1 sign-in for an MCP server, as the MCP spec asks for. The
/// client gets only the address of the server, like `https://my.app/mcp`.
/// It finds the rest itself.
///
/// | Step | Route |
/// | --- | --- |
/// | Find | `GET /.well-known/oauth-protected-resource` (also with the MCP path after it) and `GET /.well-known/oauth-authorization-server` |
/// | Register | `POST /oauth/register`. Nothing is stored: the `client_id` is the name and redirect addresses, signed with `APP_KEY` |
/// | Ask | the app's own consent page, at [authorizePage]. The person signs in there and says yes |
/// | Allow | the page calls the app, and the app calls [approve]. It gives the address to send the browser to, with a one-time code |
/// | Swap | `POST /oauth/token`. It checks the code (once), the client, the redirect address and the PKCE secret, then asks [tokens] for a token |
/// | Use | `Authorization: Bearer <token>` on the MCP route. [authenticate] checks it. [unauthorized] tells the client where to sign in |
///
/// PKCE `S256` only, `authorization_code` only, public clients only (no
/// client secret). A redirect address must be `https`, or `http` on the
/// person's own computer (`localhost`, `127.0.0.1`, `[::1]`).
///
/// The codes are kept in [codes], a Dox cache. Dox runs many isolates, so
/// use a store they share, like `Cache().store('file')` on one host, or
/// Redis on many.
///
/// ```
/// final McpOAuth oauth = McpOAuth(
///   issuer: 'https://my.app',
///   tokens: MyTokenStore(),
///   codes: Cache().store('file'),
/// );
///
/// class McpRouter extends Router {
///   @override
///   void register() {
///     oauth.routes();
///     Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', handle);
///   }
/// }
///
/// Future<DoxResponse> handle(DoxRequest req) async {
///   Object? user = await oauth.authenticate(req);
///   if (user == null) return oauth.unauthorized();
///   return mcp.handle(req, auth: user, scope: '$user');
/// }
/// ```
class McpOAuth {
  McpOAuth({
    required String issuer,
    required this.tokens,
    this.mcpPath = '/mcp',
    this._authorizePage,
    this._codes,
    this.codeTtl = const Duration(minutes: 1),
    this.resourceName,
    this._key,
  }) : issuer = issuer.replaceFirst(RegExp(r'/+$'), '');

  static const String protectedResourcePath =
      '/.well-known/oauth-protected-resource';
  static const String authorizationServerPath =
      '/.well-known/oauth-authorization-server';
  static const String registerPath = '/oauth/register';
  static const String tokenPath = '/oauth/token';

  /// The label of the key made from `APP_KEY`.
  static const String keyLabel = 'dox:mcp-oauth';

  /// The base address of the app, like `https://my.app`. It is the OAuth
  /// issuer, and the host of every endpoint.
  final String issuer;

  /// The path of the MCP route.
  final String mcpPath;

  final McpOAuthTokens tokens;

  /// How long a code may wait before the client swaps it.
  final Duration codeTtl;

  /// A name of the server for people, in the resource file. Optional.
  final String? resourceName;

  final String? _authorizePage;
  final Cache? _codes;
  final List<int>? _key;

  static final Random _random = Random.secure();

  /// The address of the MCP server: what a client is given.
  String get resource => '$issuer$mcpPath';

  /// The consent page of the app. Default: `<issuer>/oauth/authorize`.
  String get authorizePage => _authorizePage ?? '$issuer/oauth/authorize';

  /// The address of the resource file for [resource].
  String get resourceMetadataUrl => '$issuer$protectedResourcePath$mcpPath';

  Cache get _store => _codes ?? Cache();

  List<int> get _secret => _key ?? KeyDerivation.forAppKey(keyLabel);

  // ---------------------------------------------------------------- routes

  /// Adds the public routes: the two discovery files, register and token.
  /// Call it in `register()` of a router with no prefix.
  ///
  /// They answer any origin (CORS `*`), because a browser-based client
  /// calls them from its own site. They read no cookie. The app's CORS
  /// list is not used for them.
  void routes() {
    Route.disabledCors(_publicRoutes);
  }

  void _publicRoutes() {
    for (String path in <String>[
      protectedResourcePath,
      '$protectedResourcePath$mcpPath',
    ]) {
      Route.get(path, resourceMetadata);
      Route.match(<String>['OPTIONS'], path, preflight);
    }
    Route.get(authorizationServerPath, serverMetadata);
    Route.match(<String>['OPTIONS'], authorizationServerPath, preflight);
    Route.post(registerPath, register);
    Route.match(<String>['OPTIONS'], registerPath, preflight);
    Route.post(tokenPath, token);
    Route.match(<String>['OPTIONS'], tokenPath, preflight);
  }

  /// `GET /.well-known/oauth-protected-resource` (RFC 9728)
  DoxResponse resourceMetadata(DoxRequest req) {
    return _public(<String, dynamic>{
      'resource': resource,
      'authorization_servers': <String>[issuer],
      'bearer_methods_supported': <String>['header'],
      'resource_name': ?resourceName,
    });
  }

  /// `GET /.well-known/oauth-authorization-server` (RFC 8414)
  DoxResponse serverMetadata(DoxRequest req) {
    return _public(<String, dynamic>{
      'issuer': issuer,
      'authorization_endpoint': authorizePage,
      'token_endpoint': '$issuer$tokenPath',
      'registration_endpoint': '$issuer$registerPath',
      'response_types_supported': <String>['code'],
      'grant_types_supported': <String>['authorization_code'],
      'code_challenge_methods_supported': <String>['S256'],
      'token_endpoint_auth_methods_supported': <String>['none'],
      'authorization_response_iss_parameter_supported': true,
    });
  }

  /// The CORS preflight of the public routes.
  DoxResponse preflight(DoxRequest req) {
    return _withCors(response().statusCode(204));
  }

  /// `POST /oauth/register` (RFC 7591). Nothing is stored.
  DoxResponse register(DoxRequest req) {
    try {
      Map<String, dynamic> body = _body(req);
      Object? name = body['client_name'];
      Object? uris = body['redirect_uris'];
      if (uris is! List || uris.isEmpty || uris.length > 10) {
        throw const McpOAuthException(
          'invalid_redirect_uri',
          'redirect_uris must be a list of 1 to 10 addresses',
        );
      }
      List<String> redirects = <String>[for (Object? uri in uris) '$uri'];
      for (String uri in redirects) {
        _checkRedirectShape(uri);
      }
      String clientName = name is String && name.trim().isNotEmpty
          ? name.trim()
          : 'MCP client';
      if (clientName.length > 100) clientName = clientName.substring(0, 100);
      McpOAuthClient client = McpOAuthClient(
        _signClient(clientName, redirects),
        clientName,
        redirects,
      );
      return _public(<String, dynamic>{
        'client_id': client.id,
        'client_id_issued_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'client_name': client.name,
        'redirect_uris': client.redirectUris,
        'grant_types': <String>['authorization_code'],
        'response_types': <String>['code'],
        'token_endpoint_auth_method': 'none',
      }, status: 201);
    } on McpOAuthException catch (error) {
      return _oauthError(error);
    }
  }

  /// `POST /oauth/token`: swap a code for a token. Form or JSON body.
  Future<DoxResponse> token(DoxRequest req) async {
    try {
      Map<String, dynamic> body = _body(req);
      if (body['grant_type'] != 'authorization_code') {
        throw const McpOAuthException(
          'unsupported_grant_type',
          'Only authorization_code is supported',
        );
      }
      String code = _field(body, 'code');
      String verifier = _field(body, 'code_verifier');
      McpOAuthClient client = this.client(_field(body, 'client_id'));
      String redirectUri = _field(body, 'redirect_uri');

      Map<String, dynamic>? saved = await _takeCode(code);
      if (saved == null) {
        throw const McpOAuthException(
          'invalid_grant',
          'The code is wrong, used or too old',
        );
      }
      // all parts are checked, so a wrong one tells nothing about the others
      bool same =
          Hash.equals('${saved['c']}', client.id) &
          Hash.equals('${saved['r']}', redirectUri) &
          Hash.equals('${saved['ch']}', _challenge(verifier));
      if (!same) {
        throw const McpOAuthException(
          'invalid_grant',
          'The code does not match the client, address or verifier',
        );
      }
      String accessToken = await tokens.issue(
        McpOAuthGrant(
          subject: '${saved['s']}',
          client: client,
          redirectUri: redirectUri,
        ),
      );
      return _public(<String, dynamic>{
        'access_token': accessToken,
        'token_type': 'Bearer',
      }).header('Cache-Control', 'no-store').header('Pragma', 'no-cache');
    } on McpOAuthException catch (error) {
      return _oauthError(error);
    }
  }

  // ------------------------------------------------------------ for the app

  /// The client of a signed [clientId]. Throws `invalid_client` when it was
  /// not made by this server.
  McpOAuthClient client(String clientId) {
    int dot = clientId.lastIndexOf('.');
    if (dot > 0 && dot < clientId.length - 1) {
      String data = clientId.substring(0, dot);
      String signature = clientId.substring(dot + 1);
      if (Hash.equals(signature, _sign('client\n$data'))) {
        try {
          Object? json = jsonDecode(utf8.decode(_unBase64(data)));
          if (json is Map && json['n'] is String && json['r'] is List) {
            return McpOAuthClient(clientId, json['n'] as String, <String>[
              for (Object? uri in json['r'] as List<dynamic>) '$uri',
            ]);
          }
        } on FormatException {
          // falls through to the error
        }
      }
    }
    throw const McpOAuthException('invalid_client', 'Unknown client');
  }

  /// The client, when [redirectUri] is one of its addresses. The consent
  /// page shows its name. Throws when the client or address is wrong: then
  /// never send the browser anywhere.
  McpOAuthClient checkClient(String clientId, String redirectUri) {
    McpOAuthClient found = client(clientId);
    if (!found.redirectUris.contains(redirectUri)) {
      throw const McpOAuthException(
        'invalid_request',
        'The redirect address is not one of the client',
      );
    }
    return found;
  }

  /// The person ([subject], like a user id) said yes. Returns the address
  /// to send the browser to, with a one-time code and [state].
  Future<String> approve({
    required String subject,
    required String clientId,
    required String redirectUri,
    required String codeChallenge,
    String codeChallengeMethod = 'S256',
    String? state,
    String? resource,
  }) async {
    checkClient(clientId, redirectUri);
    if (codeChallengeMethod != 'S256') {
      throw const McpOAuthException(
        'invalid_request',
        'code_challenge_method must be S256',
      );
    }
    if (codeChallenge.length < 43 || codeChallenge.length > 128) {
      throw const McpOAuthException(
        'invalid_request',
        'code_challenge must be 43 to 128 characters',
      );
    }
    if (resource != null && resource.isNotEmpty && !_isOurs(resource)) {
      throw const McpOAuthException(
        'invalid_target',
        'The resource is not this MCP server',
      );
    }
    String code = _randomToken();
    await _store.put(_codeKey(code), <String, dynamic>{
      's': subject,
      'c': clientId,
      'r': redirectUri,
      'ch': codeChallenge,
    }, duration: codeTtl);
    return _redirect(redirectUri, <String, String>{
      'code': code,
      'state': ?state,
      'iss': issuer,
    });
  }

  /// The person said no. Returns the address to send the browser to.
  String deny({
    required String clientId,
    required String redirectUri,
    String? state,
  }) {
    checkClient(clientId, redirectUri);
    return _redirect(redirectUri, <String, String>{
      'error': 'access_denied',
      'state': ?state,
      'iss': issuer,
    });
  }

  /// What the `Authorization: Bearer` token of [req] stands for, or null.
  Future<Object?> authenticate(DoxRequest req) async {
    String header = req.header('authorization') ?? '';
    Match? match = RegExp(
      r'^Bearer\s+(\S+)$',
      caseSensitive: false,
    ).firstMatch(header.trim());
    if (match == null) return null;
    return tokens.verify(match.group(1)!);
  }

  /// `401` with `WWW-Authenticate`, so the client finds the sign-in.
  DoxResponse unauthorized() {
    return response(<String, dynamic>{
          'jsonrpc': '2.0',
          'error': <String, dynamic>{'code': -32001, 'message': 'Unauthorized'},
          'id': null,
        })
        .statusCode(401)
        .header(
          'WWW-Authenticate',
          'Bearer resource_metadata="$resourceMetadataUrl"',
        );
  }

  // --------------------------------------------------------------- helpers

  /// Get the code and forget it, under a lock: a code works once, also
  /// when two isolates get it at the same time.
  Future<Map<String, dynamic>?> _takeCode(String code) async {
    String key = _codeKey(code);
    CacheLock lock = _store.lock('$key:lock', const Duration(seconds: 10));
    if (!await lock.block(const Duration(seconds: 5))) return null;
    try {
      Object? saved = await _store.get(key);
      await _store.forget(key);
      return saved is Map ? Map<String, dynamic>.from(saved) : null;
    } finally {
      await lock.release();
    }
  }

  bool _isOurs(String uri) {
    String trimmed = uri.replaceFirst(RegExp(r'/+$'), '');
    return trimmed == resource || trimmed == issuer;
  }

  static void _checkRedirectShape(String uri) {
    Uri? parsed = Uri.tryParse(uri);
    bool loopback =
        parsed != null &&
        <String>['localhost', '127.0.0.1', '::1'].contains(parsed.host);
    bool ok =
        parsed != null &&
        parsed.host.isNotEmpty &&
        !parsed.hasFragment &&
        (parsed.scheme == 'https' || (parsed.scheme == 'http' && loopback));
    if (!ok) {
      throw McpOAuthException(
        'invalid_redirect_uri',
        'A redirect address must be https, or http on localhost: $uri',
      );
    }
  }

  static String _redirect(String uri, Map<String, String> params) {
    Uri parsed = Uri.parse(uri);
    return parsed
        .replace(
          queryParameters: <String, String>{
            ...parsed.queryParameters,
            ...params,
          },
        )
        .toString();
  }

  String _signClient(String name, List<String> redirects) {
    String data = _base64(
      utf8.encode(jsonEncode(<String, dynamic>{'n': name, 'r': redirects})),
    );
    return '$data.${_sign('client\n$data')}';
  }

  String _sign(String text) {
    Digest digest = Hmac(sha256, _secret).convert(utf8.encode(text));
    return _base64(digest.bytes);
  }

  static String _challenge(String verifier) {
    return _base64(sha256.convert(ascii.encode(verifier)).bytes);
  }

  static String _codeKey(String code) {
    return 'dox_mcp:oauth-code:${sha256.convert(utf8.encode(code))}';
  }

  static String _randomToken() {
    return _base64(Uint8List.fromList(List<int>.generate(32, _randomByte)));
  }

  static int _randomByte(int _) => _random.nextInt(256);

  static String _base64(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static List<int> _unBase64(String text) {
    return base64Url.decode(base64Url.normalize(text));
  }

  static Map<String, dynamic> _body(DoxRequest req) {
    RequestBody body = req.requestBody;
    if (body.kind == BodyKind.invalidJson) {
      throw const McpOAuthException('invalid_request', 'The body is not JSON');
    }
    if (body.kind == BodyKind.json) {
      Object? json = body.json;
      if (json is Map) return Map<String, dynamic>.from(json);
      throw const McpOAuthException(
        'invalid_request',
        'The body must be an object',
      );
    }
    return body.map;
  }

  static String _field(Map<String, dynamic> body, String name) {
    Object? value = body[name];
    if (value is String && value.isNotEmpty) return value;
    throw McpOAuthException('invalid_request', '$name is missing');
  }

  static DoxResponse _public(Map<String, dynamic> body, {int status = 200}) {
    return _withCors(response(body).statusCode(status));
  }

  static DoxResponse _oauthError(McpOAuthException error) {
    return _public(error.toJson(), status: error.status);
  }

  static DoxResponse _withCors(DoxResponse res) {
    return res
        .header('Access-Control-Allow-Origin', '*')
        .header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        .header(
          'Access-Control-Allow-Headers',
          'Content-Type, Authorization, mcp-protocol-version',
        )
        .header('Access-Control-Max-Age', '86400');
  }
}
