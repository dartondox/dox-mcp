import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:dox_core/dox_core.dart';
import 'package:dox_core/testing.dart';
import 'package:dox_mcp/dox_mcp.dart';
import 'package:test/test.dart';

/// Tokens in memory: `tok-<n>` stands for the subject it was issued to.
class MemoryTokens extends McpOAuthTokens {
  final Map<String, String> issued = <String, String>{};
  final List<McpOAuthGrant> grants = <McpOAuthGrant>[];

  @override
  Future<String> issue(McpOAuthGrant grant) async {
    if (grant.subject == 'full') {
      throw const McpOAuthException('access_denied', 'Too many clients');
    }
    grants.add(grant);
    String token = 'tok-${issued.length + 1}';
    issued[token] = grant.subject;
    return token;
  }

  @override
  Future<Object?> verify(String token) async => issued[token];
}

final MemoryTokens tokens = MemoryTokens();

final McpOAuth oauth = McpOAuth(
  issuer: 'https://app.test/',
  tokens: tokens,
  key: utf8.encode('o' * 32),
  resourceName: 'Test',
);

/// The fake time of [clockOAuth].
DateTime fakeNow = DateTime.utc(2026);

DateTime readFakeNow() => fakeNow;

/// The same server, but on a fake clock.
final McpOAuth clockOAuth = McpOAuth(
  issuer: 'https://app.test/',
  tokens: tokens,
  key: utf8.encode('o' * 32),
  now: readFakeNow,
);

/// A lock that is never free and throws on a timeout, like a cache with
/// `CacheFlags(lockThrows: true)`.
class BusyLock extends CacheLock {
  BusyLock(super.name, super.ttl);

  @override
  Future<bool> get() async => false;

  @override
  Future<bool> release() async => false;

  @override
  Future<T> block<T>(Duration timeout, [Object? callback]) {
    throw LockTimeoutException(name, timeout);
  }
}

/// A cache whose locks are [BusyLock]s.
class BusyCache extends Cache {
  @override
  CacheLock lock(String name, [Duration? ttl, String? owner]) {
    return BusyLock(name, ttl);
  }
}

/// The same server, with a lock that always times out.
final McpOAuth lockedOAuth = McpOAuth(
  issuer: 'https://app.test/',
  tokens: tokens,
  key: utf8.encode('o' * 32),
  codes: BusyCache(),
);

final McpServer mcp = McpServer(
  name: 'test-server',
  version: '1.0.0',
  tools: <McpTool>[],
);

class OAuthRouter extends Router {
  @override
  void register() {
    oauth.routes();
    Route.match(<String>['GET', 'POST', 'DELETE'], '/mcp', handleMcp);
    // the app's own "yes" endpoint; the user comes from the app's login
    Route.post('/approve', approve);
    Route.post('/clock/token', clockOAuth.token);
    Route.post('/locked/token', lockedOAuth.token);
  }

  Future<DoxResponse> handleMcp(DoxRequest req) async {
    Object? user = await oauth.authenticate(req);
    if (user == null) return oauth.unauthorized();
    return mcp.handle(req, auth: user, scope: '$user');
  }

  Future<DoxResponse> approve(DoxRequest req) async {
    Map<String, dynamic> body = req.body;
    try {
      String url = await oauth.approve(
        subject: '${body['user']}',
        clientId: '${body['client_id']}',
        redirectUri: '${body['redirect_uri']}',
        codeChallenge: '${body['code_challenge']}',
        state: body['state'] as String?,
        resource: body['resource'] as String?,
      );
      return response(<String, String>{'url': url});
    } on McpOAuthException catch (error) {
      return response(error.toJson()).statusCode(error.status);
    }
  }
}

String challengeOf(String verifier) {
  return base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
}

void main() {
  late DoxTestClient client;
  String verifier = 'v' * 50;
  String redirect = 'http://127.0.0.1:33418/callback';
  Map<String, String> json = <String, String>{
    'content-type': 'application/json',
  };

  setUpAll(() async {
    client = await DoxTestClient.start(
      AppConfig(
        appKey: 'mcp-test-key-0123456789abcdef!!!',
        routers: <Router>[OAuthRouter()],
      ),
    );
  });

  tearDownAll(() async {
    await client.close();
  });

  Future<String> registerClient([
    String uri = 'http://127.0.0.1:33418/callback',
  ]) async {
    TestResponse res = await client.post(
      '/oauth/register',
      headers: json,
      body: jsonEncode(<String, dynamic>{
        'client_name': 'Claude',
        'redirect_uris': <String>[uri],
      }),
    );
    res.expectStatus(201);
    return res.json['client_id'] as String;
  }

  Future<String> codeFor(String clientId, {String user = 'ann'}) async {
    TestResponse res = await client.post(
      '/approve',
      headers: json,
      body: jsonEncode(<String, dynamic>{
        'user': user,
        'client_id': clientId,
        'redirect_uri': redirect,
        'code_challenge': challengeOf(verifier),
        'state': 'xyz',
        'resource': 'https://app.test/mcp',
      }),
    );
    res.expectStatus(200);
    Uri url = Uri.parse(res.json['url'] as String);
    expect(url.queryParameters['state'], 'xyz');
    expect(url.queryParameters['iss'], 'https://app.test');
    return url.queryParameters['code']!;
  }

  Future<TestResponse> swap(
    String clientId,
    String code, {
    String? verifierOverride,
    String? redirectOverride,
    String path = '/oauth/token',
    Map<String, String> headers = const <String, String>{},
  }) {
    return client.post(
      path,
      headers: <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
        ...headers,
      },
      body: Uri(
        queryParameters: <String, String>{
          'grant_type': 'authorization_code',
          'code': code,
          'client_id': clientId,
          'redirect_uri': redirectOverride ?? redirect,
          'code_verifier': verifierOverride ?? verifier,
        },
      ).query,
    );
  }

  group('discovery', () {
    test('the MCP route says where to sign in', () async {
      TestResponse res = await client.post('/mcp', headers: json, body: '{}');
      res.expectStatus(401);
      expect(
        res.header('www-authenticate'),
        'Bearer resource_metadata="https://app.test/.well-known/oauth-protected-resource/mcp"',
      );
    });

    test('both resource files name the server and the issuer', () async {
      for (String path in <String>[
        '/.well-known/oauth-protected-resource',
        '/.well-known/oauth-protected-resource/mcp',
      ]) {
        TestResponse res = await client.get(path);
        res.expectStatus(200);
        expect(res.json['resource'], 'https://app.test/mcp');
        expect(res.json['authorization_servers'], <String>['https://app.test']);
        expect(res.header('access-control-allow-origin'), '*');
      }
    });

    test('the server file lists the endpoints, PKCE S256 only', () async {
      TestResponse res = await client.get(
        '/.well-known/oauth-authorization-server',
      );
      res.expectStatus(200);
      expect(res.json, <String, dynamic>{
        'issuer': 'https://app.test',
        'authorization_endpoint': 'https://app.test/oauth/authorize',
        'token_endpoint': 'https://app.test/oauth/token',
        'registration_endpoint': 'https://app.test/oauth/register',
        'response_types_supported': <String>['code'],
        'grant_types_supported': <String>['authorization_code'],
        'code_challenge_methods_supported': <String>['S256'],
        'token_endpoint_auth_methods_supported': <String>['none'],
        'authorization_response_iss_parameter_supported': true,
      });
    });

    test('a preflight from any site is allowed', () async {
      TestResponse res = await client.send(
        'OPTIONS',
        '/oauth/token',
        headers: <String, String>{
          'origin': 'https://claude.ai',
          'access-control-request-method': 'POST',
        },
      );
      res.expectStatus(204);
      expect(res.header('access-control-allow-origin'), '*');
    });
  });

  group('register', () {
    test('a bad redirect address is refused', () async {
      for (String uri in <String>[
        'http://evil.test/cb',
        'javascript:alert(1)',
        'https://ok.test/cb#frag',
      ]) {
        TestResponse res = await client.post(
          '/oauth/register',
          headers: json,
          body: jsonEncode(<String, dynamic>{
            'redirect_uris': <String>[uri],
          }),
        );
        res.expectStatus(400);
        expect(res.json['error'], 'invalid_redirect_uri');
      }
    });

    test('the client id holds the name and addresses, signed', () async {
      String id = await registerClient('https://claude.ai/api/callback');
      McpOAuthClient found = oauth.client(id);
      expect(found.name, 'Claude');
      expect(found.redirectUris, <String>['https://claude.ai/api/callback']);
      String forged = '${id.substring(0, id.lastIndexOf('.'))}.AAAA';
      expect(() => oauth.client(forged), throwsA(isA<McpOAuthException>()));
    });
  });

  group('register limits', () {
    test('a too long redirect address is refused', () async {
      String base = 'https://ok.test/';
      String tooLong =
          base + 'a' * (McpOAuth.maxRedirectUriLength - base.length + 1);
      TestResponse res = await client.post(
        '/oauth/register',
        headers: json,
        body: jsonEncode(<String, dynamic>{
          'redirect_uris': <String>[tooLong],
        }),
      );
      res.expectStatus(400);
      expect(res.json['error'], 'invalid_redirect_uri');

      String justRight = tooLong.substring(0, tooLong.length - 1);
      await registerClient(justRight);
    });
  });

  group('sign-in', () {
    test('code -> token -> MCP, and the code works once', () async {
      String clientId = await registerClient();
      String code = await codeFor(clientId);

      TestResponse res = await swap(clientId, code);
      res.expectStatus(200);
      expect(res.json['token_type'], 'Bearer');
      expect(res.header('cache-control'), 'no-store');
      String token = res.json['access_token'] as String;
      expect(tokens.grants.last.client.name, 'Claude');
      expect(tokens.grants.last.redirectUri, redirect);

      TestResponse init = await client.post(
        '/mcp',
        headers: <String, String>{
          ...json,
          'accept': 'application/json, text/event-stream',
          'authorization': 'Bearer $token',
        },
        body: jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{
            'protocolVersion': '2025-06-18',
            'capabilities': <String, dynamic>{},
            'clientInfo': <String, dynamic>{'name': 't', 'version': '1'},
          },
        }),
      );
      init.expectStatus(200);

      TestResponse again = await swap(clientId, code);
      again.expectStatus(400);
      expect(again.json['error'], 'invalid_grant');
    });

    test('a wrong verifier or redirect address burns the code', () async {
      String clientId = await registerClient();
      String code = await codeFor(clientId);
      TestResponse wrong = await swap(
        clientId,
        code,
        verifierOverride: 'w' * 50,
      );
      expect(wrong.json['error'], 'invalid_grant');
      // the right verifier is too late now
      expect((await swap(clientId, code)).json['error'], 'invalid_grant');

      String code2 = await codeFor(clientId);
      TestResponse otherRedirect = await swap(
        clientId,
        code2,
        redirectOverride: 'http://127.0.0.1:1/other',
      );
      expect(otherRedirect.json['error'], 'invalid_grant');
    });

    test('a bad verifier gives invalid_request, not a crash', () async {
      String clientId = await registerClient();
      String code = await codeFor(clientId);
      for (String bad in <String>[
        'ü' * 50, // not ASCII
        'v' * 42, // too short
        'v' * 129, // too long
        '${'v' * 49}+', // not an allowed character
      ]) {
        TestResponse res = await swap(clientId, code, verifierOverride: bad);
        res.expectStatus(400);
        expect(res.json['error'], 'invalid_request');
      }
      // a bad verifier does not take the code
      (await swap(clientId, code)).expectStatus(200);
    });

    test('a code works until codeTtl, then it is refused', () async {
      String clientId = await registerClient();
      Future<String> code() async {
        String url = await clockOAuth.approve(
          subject: 'ann',
          clientId: clientId,
          redirectUri: redirect,
          codeChallenge: challengeOf(verifier),
        );
        return Uri.parse(url).queryParameters['code']!;
      }

      String onTime = await code();
      fakeNow = fakeNow.add(const Duration(minutes: 1));
      (await swap(clientId, onTime, path: '/clock/token')).expectStatus(200);

      String late = await code();
      fakeNow = fakeNow.add(const Duration(minutes: 1, milliseconds: 1));
      TestResponse res = await swap(clientId, late, path: '/clock/token');
      res.expectStatus(400);
      expect(res.json['error'], 'invalid_grant');
    });

    test('a lock timeout that throws gives invalid_grant, not 500', () async {
      String clientId = await registerClient();
      String url = await lockedOAuth.approve(
        subject: 'ann',
        clientId: clientId,
        redirectUri: redirect,
        codeChallenge: challengeOf(verifier),
      );
      String code = Uri.parse(url).queryParameters['code']!;
      TestResponse res = await swap(clientId, code, path: '/locked/token');
      res.expectStatus(400);
      expect(res.json['error'], 'invalid_grant');
    });

    test('a verifier of 43 or 128 characters works (RFC 7636)', () async {
      String clientId = await registerClient();
      for (String good in <String>['a' * 43, 'Z' * 128]) {
        String url = await oauth.approve(
          subject: 'ann',
          clientId: clientId,
          redirectUri: redirect,
          codeChallenge: challengeOf(good),
        );
        String code = Uri.parse(url).queryParameters['code']!;
        (await swap(clientId, code, verifierOverride: good)).expectStatus(200);
      }
    });

    test('a client id with a changed signature is refused', () async {
      String clientId = await registerClient();
      String code = await codeFor(clientId);
      String last = clientId.substring(clientId.length - 1);
      String tampered =
          clientId.substring(0, clientId.length - 1) +
          (last == 'A' ? 'B' : 'A');
      TestResponse res = await swap(tampered, code);
      res.expectStatus(401);
      expect(res.json['error'], 'invalid_client');
      expect(res.header('www-authenticate'), isNull);

      // RFC 6749 5.2: with an Authorization header, name its scheme
      TestResponse basic = await swap(
        tampered,
        code,
        headers: <String, String>{'authorization': 'Basic eDp5'},
      );
      basic.expectStatus(401);
      expect(basic.json['error'], 'invalid_client');
      expect(
        basic.header('www-authenticate'),
        'Basic realm="https://app.test"',
      );
    });

    test('a code of one client does not work for another', () async {
      String first = await registerClient();
      String second = await registerClient('http://localhost:9/cb');
      String code = await codeFor(first);
      expect((await swap(second, code)).json['error'], 'invalid_grant');
    });

    test('approve refuses a wrong redirect, method or resource', () async {
      String clientId = await registerClient();
      Future<TestResponse> ask(Map<String, dynamic> extra) {
        return client.post(
          '/approve',
          headers: json,
          body: jsonEncode(<String, dynamic>{
            'user': 'ann',
            'client_id': clientId,
            'redirect_uri': redirect,
            'code_challenge': challengeOf(verifier),
            ...extra,
          }),
        );
      }

      expect(
        (await ask(<String, dynamic>{'redirect_uri': 'https://evil.test/cb'}))
            .json['error'],
        'invalid_request',
      );
      expect(
        (await ask(<String, dynamic>{'code_challenge': 'short'})).json['error'],
        'invalid_request',
      );
      expect(
        (await ask(<String, dynamic>{'code_challenge': 'ü' * 43}))
            .json['error'],
        'invalid_request',
      );
      expect(
        (await ask(<String, dynamic>{'resource': 'https://other.test/mcp'}))
            .json['error'],
        'invalid_target',
      );
    });

    test('the app can say no when it makes the token', () async {
      String clientId = await registerClient();
      String code = await codeFor(clientId, user: 'full');
      TestResponse res = await swap(clientId, code);
      res.expectStatus(400);
      expect(res.json['error'], 'access_denied');
    });

    test('deny sends the browser back with access_denied', () async {
      String clientId = await registerClient();
      Uri url = Uri.parse(
        oauth.deny(clientId: clientId, redirectUri: redirect, state: 's'),
      );
      expect(url.queryParameters['error'], 'access_denied');
      expect(url.queryParameters['state'], 's');
      expect(
        () => oauth.deny(clientId: clientId, redirectUri: 'https://evil.test'),
        throwsA(isA<McpOAuthException>()),
      );
    });
  });
}
