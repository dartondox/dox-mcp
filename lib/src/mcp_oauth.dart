import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Digest, Hmac, sha256;
import 'package:dox_core/dox_core.dart';

import 'mcp_oauth_client_fetcher.dart';

export 'mcp_oauth_client_fetcher.dart';

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

/// A client of the sign-in. It is one of two kinds:
///
/// - It registered with `POST /oauth/register`. Then [id] is signed and
///   holds [name] and [redirectUris].
/// - It uses a client metadata document. Then [id] is an `https` address,
///   and [name] and [redirectUris] come from the document there.
class McpOAuthClient {
  const McpOAuthClient(this.id, this.name, this.redirectUris);

  /// The `client_id`: signed, or the `https` address of the document.
  final String id;

  /// The name the client gave, like `Claude`.
  final String name;

  /// The only addresses a code may be sent to.
  final List<String> redirectUris;

  /// The host of a document [id], like `claude.ai`. The client chooses its
  /// own [name], so the consent page shows this host next to it: it is the
  /// part the person can trust. Null for a signed client.
  String? get host =>
      McpOAuth.isClientIdUrl(id) ? Uri.tryParse(id)?.host : null;
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
/// | Client | A new client uses an `https` address as its `client_id` (a client metadata document). The server loads the document there |
/// | Register | Older clients: `POST /oauth/register`. Nothing is stored: the `client_id` is the name and redirect addresses, signed with `APP_KEY` |
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
///   User? user = await oauth.authenticate(req) as User?;
///   if (user == null) return oauth.unauthorized();
///   return mcp.handle(req, auth: user, scope: 'user:${user.id}');
/// }
/// ```
class McpOAuth {
  /// [now] reads the time, for the expiry of a code and the
  /// `client_id_issued_at` of a new client. Default: `DateTime.now`.
  /// A test can pass a fake clock.
  McpOAuth({
    required String issuer,
    required this.tokens,
    this.mcpPath = '/mcp',
    this._authorizePage,
    this._codes,
    this.codeTtl = const Duration(minutes: 1),
    this.resourceName,
    this._key,
    DateTime Function()? now,
    McpOAuthClientFetcher clientFetcher = const McpOAuthHttpFetcher(),
    Set<String>? allowedClientHosts,
    this.clientCacheMaxAge = const Duration(minutes: 5),
    this.maxClientFetches = 8,
    this.maxClientFetchesPerHost = 2,
  }) : issuer = issuer.replaceFirst(RegExp(r'/+$'), ''),
       _now = now ?? DateTime.now,
       _fetcher = clientFetcher,
       allowedClientHosts = allowedClientHosts == null
           ? null
           : <String>{
               for (String host in allowedClientHosts) host.toLowerCase(),
             };

  static const String protectedResourcePath =
      '/.well-known/oauth-protected-resource';
  static const String authorizationServerPath =
      '/.well-known/oauth-authorization-server';
  static const String registerPath = '/oauth/register';
  static const String tokenPath = '/oauth/token';

  /// The longest redirect address a client may register.
  static const int maxRedirectUriLength = 2048;

  /// The longest `client_id` address (client metadata document) it loads.
  static const int maxClientIdUrlLength = 2048;

  /// How many client metadata documents each isolate keeps in memory.
  static const int clientCacheSize = 500;

  /// How long a document is kept when its answer has no `Cache-Control`.
  /// [clientCacheMaxAge] still caps it.
  static const Duration clientCacheDefaultAge = Duration(minutes: 1);

  /// How long an old document may still be used after its cache time, when
  /// the host gave no answer to a new load (a timeout, no connection, or a
  /// `5xx` status). A real answer (like `404`, or a changed document) always
  /// replaces it.
  static const Duration clientStaleAge = Duration(hours: 1);

  /// How long an old document may still be used after its cache time, when
  /// a new load can not start (all slots busy). [checkClient] and [deny]
  /// also use it while they start a new load.
  static const Duration clientBusyStaleAge = Duration(minutes: 5);

  /// How long a document sent with `no-store`, `no-cache` or `max-age=0` is
  /// kept for [checkClient] and [deny] (and other calls when all slots are
  /// busy). So a consent page that uses them works for such a client.
  static const Duration clientHandOffAge = Duration(minutes: 1);

  /// How long a failed address, or a host that did not answer, is not
  /// loaded again. Each isolate keeps this in memory.
  static const Duration clientFailureAge = Duration(minutes: 1);

  // RFC 7636 4.1: 43 to 128 of these characters.
  static final RegExp _verifierShape = RegExp(r'^[A-Za-z0-9\-._~]{43,128}$');

  // An S256 challenge is a SHA-256 hash in base64url: always 43 characters.
  static final RegExp _challengeShape = RegExp(r'^[A-Za-z0-9_-]{43}$');

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

  /// The only hosts whose client metadata documents are loaded, like
  /// `{'claude.ai'}`. A `client_id` on another host gets `invalid_client`.
  /// Default: null, any public host.
  final Set<String>? allowedClientHosts;

  /// The longest time a loaded client metadata document is kept in memory.
  /// A shorter `Cache-Control: max-age` wins. Default: 5 minutes.
  final Duration clientCacheMaxAge;

  /// How many client metadata documents each isolate may load at the same
  /// time. When all are busy, a new address gets `invalid_client` at once
  /// (it does not wait). Two lookups of the same address count once. This
  /// stops a caller from making the server open many slow connections.
  /// Default: 8.
  final int maxClientFetches;

  /// How many of the [maxClientFetches] loads may go to one host at the
  /// same time. So one slow host can not take all slots. Default: 2.
  final int maxClientFetchesPerHost;

  final McpOAuthClientFetcher _fetcher;

  // per isolate, oldest first
  final Map<String, _CachedClient> _clientCache = <String, _CachedClient>{};
  // address or host -> no new load before this time
  final Map<String, DateTime> _failedUrls = <String, DateTime>{};
  final Map<String, DateTime> _failedHosts = <String, DateTime>{};
  final Map<String, Future<McpOAuthClient>> _clientLoads =
      <String, Future<McpOAuthClient>>{};

  final String? _authorizePage;
  final Cache? _codes;
  final List<int>? _key;

  /// Reads the time. Tests pass a fake clock. Default: `DateTime.now`.
  final DateTime Function() _now;

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
      'client_id_metadata_document_supported': true,
    });
  }

  /// The CORS preflight of the public routes.
  DoxResponse preflight(DoxRequest req) {
    return _withCors(response().statusCode(204));
  }

  /// `POST /oauth/register` (RFC 7591). Nothing is stored.
  ///
  /// The MCP spec now prefers client metadata documents. This stays for
  /// older clients.
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
        'client_id_issued_at': _now().millisecondsSinceEpoch ~/ 1000,
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
      // checked before the code is taken, so a bad verifier gives a
      // normal error and not a crash
      String challenge = _challenge(_field(body, 'code_verifier'));
      McpOAuthClient client = await findClient(_field(body, 'client_id'));
      if (isClientIdUrl(client.id) && _sendsClientAuth(req, body)) {
        // a document client has no secret (auth method `none`)
        throw const McpOAuthException(
          'invalid_client',
          'This client does not use client authentication',
        );
      }
      String redirectUri = _field(body, 'redirect_uri');

      Map<String, dynamic>? saved = await _takeCode(code);
      // the cache also forgets it after codeTtl; this check is exact
      Object? expires = saved?['e'];
      if (saved == null ||
          (expires is int && _now().millisecondsSinceEpoch > expires)) {
        throw const McpOAuthException(
          'invalid_grant',
          'The code is wrong, used or too old',
        );
      }
      // all parts are checked, so a wrong one tells nothing about the others
      bool same =
          Hash.equals('${saved['c']}', client.id) &
          Hash.equals('${saved['r']}', redirectUri) &
          Hash.equals('${saved['ch']}', challenge);
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
      if (error.error == 'invalid_client') return _invalidClient(req, error);
      return _oauthError(error);
    }
  }

  /// RFC 6749 5.2: `invalid_client` is a `401`. When the client sent an
  /// `Authorization` header, the answer names its scheme in
  /// `WWW-Authenticate`.
  DoxResponse _invalidClient(DoxRequest req, McpOAuthException error) {
    DoxResponse res = _public(error.toJson(), status: 401);
    String? scheme = RegExp(r"^[A-Za-z0-9!#$%&'*+\-.^_`|~]+")
        .stringMatch(req.header('authorization')?.trim() ?? '');
    if (scheme == null) return res;
    return res.header('WWW-Authenticate', '$scheme realm="$issuer"');
  }

  // ------------------------------------------------------------ for the app

  /// The client of [clientId]: a signed id from `/oauth/register`, or an
  /// `https` address of a client metadata document, which it loads (and
  /// keeps for a short time). Throws `invalid_client` when the client is
  /// not known, or its document can not be loaded or is not valid.
  Future<McpOAuthClient> findClient(String clientId) async {
    if (isClientIdUrl(clientId)) return _documentClient(clientId);
    return client(clientId);
  }

  /// The client, when [redirectUri] is one of its addresses. Like
  /// [checkClient], but it loads a client metadata document when it is not
  /// in memory yet. The consent page shows its name, its [McpOAuthClient.host]
  /// and the host of [redirectUri]. Throws when the client or address is
  /// wrong: then never send the browser anywhere.
  Future<McpOAuthClient> verifyClient(
    String clientId,
    String redirectUri,
  ) async {
    McpOAuthClient found = await findClient(clientId);
    _checkRedirect(found, redirectUri);
    return found;
  }

  /// The client of a signed [clientId]. Throws `invalid_client` when it was
  /// not made by this server. For a client metadata document (an `https`
  /// `client_id`), use [findClient].
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
  ///
  /// It is not async, so it can not wait for a client metadata document.
  /// It uses the document when this isolate has it in memory. Else it
  /// starts the load and throws `invalid_client`: a new try a moment later
  /// finds it. Prefer [verifyClient], which waits for the load.
  McpOAuthClient checkClient(String clientId, String redirectUri) {
    McpOAuthClient found = isClientIdUrl(clientId)
        ? _documentClientNow(clientId)
        : client(clientId);
    _checkRedirect(found, redirectUri);
    return found;
  }

  static void _checkRedirect(McpOAuthClient client, String redirectUri) {
    bool found = client.redirectUris.contains(redirectUri);
    // RFC 9700 4.1.3 and RFC 8252 7.3: a native app on the person's own
    // computer gets a random port, so for an `http` loopback address the
    // port may differ. Only for document clients: signed ones stay exact.
    if (!found && isClientIdUrl(client.id)) {
      String? asked = _withoutLoopbackPort(redirectUri);
      found =
          asked != null &&
          client.redirectUris.map(_withoutLoopbackPort).contains(asked);
    }
    if (!found) {
      throw const McpOAuthException(
        'invalid_request',
        'The redirect address is not one of the client',
      );
    }
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
    await verifyClient(clientId, redirectUri);
    if (codeChallengeMethod != 'S256') {
      throw const McpOAuthException(
        'invalid_request',
        'code_challenge_method must be S256',
      );
    }
    if (!_challengeShape.hasMatch(codeChallenge)) {
      throw const McpOAuthException(
        'invalid_request',
        'code_challenge must be 43 base64url characters (S256)',
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
      'e': _now().add(codeTtl).millisecondsSinceEpoch,
    }, duration: codeTtl);
    return _redirect(redirectUri, <String, String>{
      'code': code,
      'state': ?state,
      'iss': issuer,
    });
  }

  /// The person said no. Returns the address to send the browser to. Like
  /// [deny], but it also knows clients with a metadata document.
  Future<String> denyClient({
    required String clientId,
    required String redirectUri,
    String? state,
  }) async {
    await verifyClient(clientId, redirectUri);
    return _denied(redirectUri, state);
  }

  /// The person said no. Returns the address to send the browser to. For a
  /// client metadata document it has the same limit as [checkClient]:
  /// prefer [denyClient].
  String deny({
    required String clientId,
    required String redirectUri,
    String? state,
  }) {
    checkClient(clientId, redirectUri);
    return _denied(redirectUri, state);
  }

  String _denied(String redirectUri, String? state) {
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

  // ------------------------------------------- client metadata documents

  /// True when [clientId] is meant as a client metadata document: it
  /// starts with `https://`. A signed id never does.
  static bool isClientIdUrl(String clientId) => clientId.startsWith('https://');

  /// True when [url] follows the rules of a client metadata document
  /// address (draft-ietf-oauth-client-id-metadata-document, section 3):
  /// `https`, no user name or password, a path other than `/`, no `.` or
  /// `..` path part, no `#fragment`, at most [maxClientIdUrlLength]
  /// characters. A port and a query are allowed. It must also be in plain
  /// form already (the server compares it as a plain string), so
  /// `https://Example.com/c` or `https://example.com:443/c` are refused.
  static bool isValidClientIdUrl(String url) {
    if (url.length > maxClientIdUrlLength || !isClientIdUrl(url)) {
      return false;
    }
    if (url.contains('#')) return false;
    Uri? uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return false;
    }
    // the path as sent, before any clean-up
    String rawPath = url.substring('https://'.length);
    int slash = rawPath.indexOf('/');
    if (slash < 0) return false;
    rawPath = rawPath.substring(slash).split('?').first;
    if (rawPath == '/') return false;
    for (String part in rawPath.split('/')) {
      String lower = part.toLowerCase();
      if (<String>[
        '.',
        '..',
        '%2e',
        '%2e%2e',
        '.%2e',
        '%2e.',
      ].contains(lower)) {
        return false;
      }
    }
    return uri.toString() == url;
  }

  static const McpOAuthException _badDocument = McpOAuthException(
    'invalid_client',
    'The client metadata document could not be loaded or is not valid',
  );

  static const Set<String> _secretAuthMethods = <String>{
    'client_secret_post',
    'client_secret_basic',
    'client_secret_jwt',
  };

  /// Checks the address rules of a document [url], and the host list.
  Uri _documentUri(String url) {
    if (!isValidClientIdUrl(url)) {
      throw const McpOAuthException(
        'invalid_client',
        'The client_id is not a valid client metadata document address',
      );
    }
    Uri uri = Uri.parse(url);
    Set<String>? allowed = allowedClientHosts;
    if (allowed != null && !allowed.contains(uri.host)) {
      throw const McpOAuthException(
        'invalid_client',
        'This server does not accept clients from this host',
      );
    }
    // draft 10.1: a client may not use the address of this server
    if (url == issuer || url == resource) throw _badDocument;
    return uri;
  }

  /// The cached document of [url], fresh or old, or null. It forgets one
  /// that is too old to use.
  _CachedClient? _cached(String url) {
    _CachedClient? cached = _clientCache[url];
    if (cached != null && !_now().isBefore(cached.keepUntil)) {
      _clientCache.remove(url);
      return null;
    }
    return cached;
  }

  Future<McpOAuthClient> _documentClient(String url) {
    Uri uri = _documentUri(url);
    _CachedClient? cached = _cached(url);
    DateTime now = _now();
    if (cached != null && now.isBefore(cached.expires)) {
      return Future<McpOAuthClient>.value(cached.client);
    }
    // one fetch at a time for the same address
    Future<McpOAuthClient>? running = _clientLoads[url];
    if (running != null) return running;
    String host = _hostKey(uri);
    if (_failedRecently(_failedUrls, url) ||
        _failedRecently(_failedHosts, host)) {
      // only a failure with no answer keeps the old document
      if (cached != null && now.isBefore(cached.staleUntil)) {
        return Future<McpOAuthClient>.value(cached.client);
      }
      throw _badDocument;
    }
    if (!_hasSlot(host)) return _busy(cached);
    return _clientLoads[url] = _loadOnce(url, uri, cached);
  }

  /// No load can start now. A short time, an old document still works.
  /// Never waits in a queue.
  Future<McpOAuthClient> _busy(_CachedClient? cached) {
    if (cached != null && _now().isBefore(cached.busyUntil)) {
      return Future<McpOAuthClient>.value(cached.client);
    }
    throw _badDocument;
  }

  /// [checkClient] can not wait: the document in memory (fresh, or old for
  /// [clientBusyStaleAge]), else it starts the load and throws.
  McpOAuthClient _documentClientNow(String url) {
    _documentUri(url);
    _CachedClient? cached = _cached(url);
    if (cached != null && _now().isBefore(cached.expires)) {
      return cached.client;
    }
    try {
      // the next call finds it in memory
      _documentClient(url).ignore();
    } on McpOAuthException {
      // no load now; the old document or the error below
    }
    if (cached != null && _now().isBefore(cached.busyUntil)) {
      return cached.client;
    }
    throw const McpOAuthException(
      'invalid_client',
      'The client metadata document is not loaded yet. Try again, '
          'or use verifyClient',
    );
  }

  /// Host and port: a dead port of a host does not block its other ports.
  static String _hostKey(Uri uri) => '${uri.host}:${uri.port}';

  /// True when a slot is free: fewer than [maxClientFetches] loads, and
  /// fewer than [maxClientFetchesPerHost] to [host].
  bool _hasSlot(String host) {
    if (_clientLoads.length >= maxClientFetches) return false;
    int sameHost = 0;
    for (String running in _clientLoads.keys) {
      if (_hostKey(Uri.parse(running)) == host) sameHost++;
    }
    return sameHost < maxClientFetchesPerHost;
  }

  bool _failedRecently(Map<String, DateTime> failed, String key) {
    DateTime? until = failed[key];
    if (until == null) return false;
    if (_now().isBefore(until)) return true;
    failed.remove(key);
    return false;
  }

  void _remember(Map<String, DateTime> failed, String key) {
    failed.remove(key);
    if (failed.length >= clientCacheSize) failed.remove(failed.keys.first);
    failed[key] = _now().add(clientFailureAge);
  }

  Future<McpOAuthClient> _loadOnce(
    String url,
    Uri uri,
    _CachedClient? cached,
  ) async {
    try {
      return await _loadDocument(url, uri);
    } on _NoSlot {
      // the fetcher had no free slot: nothing failed, nothing is kept
      return _busy(cached);
    } on _NoAnswer {
      _remember(_failedUrls, url);
      if (cached != null && _now().isBefore(cached.staleUntil)) {
        return cached.client;
      }
      throw _badDocument;
    } on McpOAuthException {
      // a real answer: the old document is gone too
      _remember(_failedUrls, url);
      _clientCache.remove(url);
      rethrow;
    } finally {
      // the callers already wait for this future
      unawaited(_clientLoads.remove(url));
    }
  }

  Future<McpOAuthClient> _loadDocument(String url, Uri uri) async {
    McpOAuthFetchedDocument fetched;
    try {
      fetched = await _fetcher.fetch(uri);
    } on McpOAuthFetchBusyException {
      throw const _NoSlot();
    } on McpOAuthFetchException catch (error) {
      // the host itself failed: skip all its addresses a short time
      if (!error.hostFailed) throw _badDocument;
      _remember(_failedHosts, _hostKey(uri));
      throw const _NoAnswer();
    } on Object {
      // like a lost connection; never give the inside error to the client
      throw const _NoAnswer();
    }
    if (fetched.statusCode >= 500 && fetched.statusCode < 600) {
      throw const _NoAnswer();
    }
    if (fetched.statusCode != 200 || !_isJson(fetched.contentType)) {
      throw _badDocument;
    }
    Object? json;
    try {
      json = jsonDecode(fetched.body);
    } on FormatException {
      throw _badDocument;
    }
    if (json is! Map<String, dynamic>) throw _badDocument;
    McpOAuthClient client = _documentToClient(url, json);
    Duration age = _cacheAge(fetched.cacheControl);
    DateTime now = _now();
    DateTime expires = now.add(age);
    _clientCache.remove(url);
    if (_clientCache.length >= clientCacheSize) {
      _clientCache.remove(_clientCache.keys.first);
    }
    _clientCache[url] = age > Duration.zero
        ? _CachedClient(
            client,
            expires: expires,
            busyUntil: expires.add(clientBusyStaleAge),
            staleUntil: expires.add(clientStaleAge),
          )
        // no-store: only the short hand-off, never as fresh or stale
        : _CachedClient(
            client,
            expires: now,
            busyUntil: now.add(clientHandOffAge),
            staleUntil: now,
          );
    return client;
  }

  /// Checks a loaded document (draft sections 4, 4.1, 5 and 6, and the
  /// MCP spec: `client_id`, `client_name` and `redirect_uris` are needed).
  McpOAuthClient _documentToClient(String url, Map<String, dynamic> doc) {
    // compared as a plain string, never cleaned up first
    if (doc['client_id'] != url) throw _badDocument;
    Object? name = doc['client_name'];
    if (name is! String || name.trim().isEmpty) throw _badDocument;
    if (doc.containsKey('client_secret') ||
        doc.containsKey('client_secret_expires_at') ||
        (doc.containsKey('jwks') && doc.containsKey('jwks_uri'))) {
      throw _badDocument;
    }
    // the client must be able to use `none`, the only method here
    Object? methods = doc['token_endpoint_auth_methods_supported'];
    Object? method = doc['token_endpoint_auth_method'];
    List<String> allMethods = <String>[
      if (method != null) '$method',
      if (methods is List) ...<String>[for (Object? m in methods) '$m'],
    ];
    if ((methods != null && methods is! List) ||
        (method != null && method is! String) ||
        allMethods.any(_secretAuthMethods.contains) ||
        (methods is List && method != null && !methods.contains(method))) {
      throw _badDocument;
    }
    List<String> usable = methods is List
        ? <String>[for (Object? m in methods) '$m']
        : <String>[if (method is String) method else 'none'];
    if (!usable.contains('none')) throw _badDocument;
    if (!_offers(doc['grant_types'], 'authorization_code') ||
        !_offers(doc['response_types'], 'code')) {
      throw _badDocument;
    }
    Object? uris = doc['redirect_uris'];
    if (uris is! List) throw _badDocument;
    List<String> redirects = <String>[];
    for (Object? uri in uris) {
      if (uri is! String) continue;
      try {
        _checkRedirectShape(uri);
        redirects.add(uri);
      } on McpOAuthException {
        // an address this server can not use, like `myapp://cb`
      }
    }
    if (redirects.isEmpty) throw _badDocument;
    String clientName = name.trim();
    if (clientName.length > 100) clientName = clientName.substring(0, 100);
    return McpOAuthClient(url, clientName, redirects);
  }

  /// True when [field] is missing (the RFC 7591 default holds [value]) or a
  /// list with [value] in it.
  static bool _offers(Object? field, String value) {
    if (field == null) return true;
    return field is List && field.contains(value);
  }

  static bool _isJson(String? contentType) {
    String type = (contentType ?? '').split(';').first.trim().toLowerCase();
    return type == 'application/json' ||
        (type.startsWith('application/') && type.endsWith('+json'));
  }

  /// How long to keep a document: `max-age`, at most [clientCacheMaxAge].
  /// Zero for `no-store` or `no-cache`.
  Duration _cacheAge(String? cacheControl) {
    Duration age = clientCacheDefaultAge;
    for (String part in (cacheControl ?? '').toLowerCase().split(',')) {
      String directive = part.trim();
      if (directive == 'no-store' || directive == 'no-cache') {
        return Duration.zero;
      }
      if (directive.startsWith('max-age=')) {
        int? seconds = int.tryParse(directive.substring('max-age='.length));
        if (seconds != null && seconds >= 0) age = Duration(seconds: seconds);
      }
    }
    return age > clientCacheMaxAge ? clientCacheMaxAge : age;
  }

  /// True when the token request has client authentication: a secret, an
  /// assertion, or `Authorization: Basic`.
  static bool _sendsClientAuth(DoxRequest req, Map<String, dynamic> body) {
    String header = req.header('authorization')?.trim().toLowerCase() ?? '';
    return body.containsKey('client_secret') ||
        body.containsKey('client_assertion') ||
        header.startsWith('basic ');
  }

  // --------------------------------------------------------------- helpers

  /// Get the code and forget it, under a lock: a code works once, also
  /// when two isolates get it at the same time.
  Future<Map<String, dynamic>?> _takeCode(String code) async {
    String key = _codeKey(code);
    CacheLock lock = _store.lock('$key:lock', const Duration(seconds: 10));
    // a cache set to throw on a lock timeout (`CacheFlags.lockThrows`)
    // must give no code too, not a 500
    try {
      if (!await lock.block<bool>(const Duration(seconds: 5))) return null;
    } on LockTimeoutException {
      return null;
    }
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
    if (uri.length > maxRedirectUriLength) {
      throw const McpOAuthException(
        'invalid_redirect_uri',
        'A redirect address must be at most $maxRedirectUriLength characters',
      );
    }
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

  static final RegExp _loopbackRedirect = RegExp(
    r'^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?([/?].*)?$',
  );

  /// [uri] without its port when it is an `http` loopback address, else
  /// null.
  static String? _withoutLoopbackPort(String uri) {
    Match? match = _loopbackRedirect.firstMatch(uri);
    if (match == null) return null;
    return 'http://${match.group(1)}${match.group(3) ?? ''}';
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

  /// The S256 challenge of [verifier]. Throws `invalid_request` when the
  /// verifier is not 43 to 128 of `A-Z a-z 0-9 - . _ ~` (RFC 7636 4.1).
  static String _challenge(String verifier) {
    if (!_verifierShape.hasMatch(verifier)) {
      throw const McpOAuthException(
        'invalid_request',
        'code_verifier must be 43 to 128 characters of A-Z a-z 0-9 - . _ ~',
      );
    }
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

class _CachedClient {
  const _CachedClient(
    this.client, {
    required this.expires,
    required this.busyUntil,
    required this.staleUntil,
  });

  final McpOAuthClient client;

  /// Fresh until then.
  final DateTime expires;

  /// Used when no load can start, and by the sync methods, until then.
  final DateTime busyUntil;

  /// Used when the host gave no answer, until then.
  final DateTime staleUntil;

  DateTime get keepUntil =>
      busyUntil.isAfter(staleUntil) ? busyUntil : staleUntil;
}

/// A load got no answer: a timeout, no connection, or a `5xx` status.
class _NoAnswer implements Exception {
  const _NoAnswer();
}

/// The fetcher had no free slot.
class _NoSlot implements Exception {
  const _NoSlot();
}
