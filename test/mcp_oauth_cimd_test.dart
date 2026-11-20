import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:dox_core/dox_core.dart';
import 'package:dox_core/testing.dart';
import 'package:dox_mcp/dox_mcp.dart';
import 'package:test/test.dart';

/// Gives fake documents. No network.
class FakeFetcher extends McpOAuthClientFetcher {
  final Map<String, McpOAuthFetchedDocument> docs =
      <String, McpOAuthFetchedDocument>{};
  final List<String> calls = <String>[];

  @override
  Future<McpOAuthFetchedDocument> fetch(Uri url) async {
    calls.add('$url');
    McpOAuthFetchedDocument? doc = docs['$url'];
    if (doc == null) {
      throw const McpOAuthFetchException('secret inside detail 10.0.0.7');
    }
    return doc;
  }

  void serve(
    String url,
    Map<String, dynamic> body, {
    int status = 200,
    String contentType = 'application/json',
    String? cacheControl,
  }) {
    docs[url] = McpOAuthFetchedDocument(
      statusCode: status,
      body: jsonEncode(body),
      contentType: contentType,
      cacheControl: cacheControl,
    );
  }
}

class MemoryTokens extends McpOAuthTokens {
  final List<McpOAuthGrant> grants = <McpOAuthGrant>[];

  @override
  Future<String> issue(McpOAuthGrant grant) async {
    grants.add(grant);
    return 'tok-${grants.length}';
  }

  @override
  Future<Object?> verify(String token) async => null;
}

const String clientUrl = 'https://client.example/oauth/metadata.json';
const String redirect = 'http://127.0.0.1:33418/callback';

Map<String, dynamic> goodDoc([String id = clientUrl]) {
  return <String, dynamic>{
    'client_id': id,
    'client_name': 'Example MCP Client',
    'redirect_uris': <String>[redirect, 'myapp://callback'],
    'grant_types': <String>['authorization_code', 'refresh_token'],
    'response_types': <String>['code'],
    'token_endpoint_auth_method': 'none',
  };
}

DateTime fakeNow = DateTime.utc(2026);

DateTime readFakeNow() => fakeNow;

final FakeFetcher fetcher = FakeFetcher();
final MemoryTokens tokens = MemoryTokens();

final McpOAuth oauth = McpOAuth(
  issuer: 'https://app.test',
  tokens: tokens,
  key: utf8.encode('o' * 32),
  clientFetcher: fetcher,
  now: readFakeNow,
);

/// Holds every fetch until [release] is called.
class BlockingFetcher extends McpOAuthClientFetcher {
  final List<String> calls = <String>[];
  Completer<void> gate = Completer<void>();
  bool fail = false;
  String cacheControl = 'no-store';

  void release() {
    gate.complete();
    gate = Completer<void>();
  }

  @override
  Future<McpOAuthFetchedDocument> fetch(Uri url) async {
    calls.add('$url');
    await gate.future;
    if (fail) throw const McpOAuthFetchException('down');
    return McpOAuthFetchedDocument(
      statusCode: 200,
      body: jsonEncode(goodDoc('$url')),
      contentType: 'application/json',
      cacheControl: cacheControl,
    );
  }
}

final BlockingFetcher blocking = BlockingFetcher();

/// Every host is down.
class HostDownFetcher extends McpOAuthClientFetcher {
  final List<String> calls = <String>[];

  @override
  Future<McpOAuthFetchedDocument> fetch(Uri url) async {
    calls.add('$url');
    throw const McpOAuthFetchException('Timed out', hostFailed: true);
  }
}

final McpOAuth capped = McpOAuth(
  issuer: 'https://app.test',
  tokens: tokens,
  key: utf8.encode('o' * 32),
  clientFetcher: blocking,
  maxClientFetches: 2,
);

final McpOAuth limited = McpOAuth(
  issuer: 'https://app.test',
  tokens: tokens,
  key: utf8.encode('o' * 32),
  clientFetcher: fetcher,
  allowedClientHosts: <String>{'Client.Example'},
);

class CimdRouter extends Router {
  @override
  void register() {
    oauth.routes();
  }
}

String challengeOf(String verifier) {
  return base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');
}

Matcher oauthError(String error) {
  return throwsA(
    isA<McpOAuthException>().having(
      (McpOAuthException e) => e.error,
      'error',
      error,
    ),
  );
}

void main() {
  late DoxTestClient client;
  String verifier = 'v' * 50;

  setUpAll(() async {
    client = await DoxTestClient.start(
      AppConfig(
        appKey: 'mcp-test-key-0123456789abcdef!!!',
        routers: <Router>[CimdRouter()],
      ),
    );
  });

  tearDownAll(() async {
    await client.close();
  });

  setUp(() {
    fetcher.docs.clear();
    fetcher.calls.clear();
    // jump past any cached document
    fakeNow = fakeNow.add(const Duration(days: 1));
  });

  Future<String> codeFor(String clientId) async {
    String url = await oauth.approve(
      subject: 'ann',
      clientId: clientId,
      redirectUri: redirect,
      codeChallenge: challengeOf(verifier),
      state: 'xyz',
    );
    return Uri.parse(url).queryParameters['code']!;
  }

  Future<TestResponse> swap(
    String clientId,
    String code, {
    Map<String, String> extra = const <String, String>{},
  }) {
    return client.post(
      '/oauth/token',
      headers: <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
      },
      body: Uri(
        queryParameters: <String, String>{
          'grant_type': 'authorization_code',
          'code': code,
          'client_id': clientId,
          'redirect_uri': redirect,
          'code_verifier': verifier,
          ...extra,
        },
      ).query,
    );
  }

  group('client id address rules', () {
    test('good addresses', () {
      for (String url in <String>[
        clientUrl,
        'https://client.example:8443/c',
        'https://client.example/c?v=1',
        'https://client.example/a/b.json',
      ]) {
        expect(McpOAuth.isValidClientIdUrl(url), isTrue, reason: url);
      }
    });

    test('bad addresses', () {
      for (String url in <String>[
        'http://client.example/c',
        'HTTPS://client.example/c',
        'https://client.example',
        'https://client.example/',
        'https://user:pw@client.example/c',
        'https://user@client.example/c',
        'https://client.example/c#frag',
        'https://client.example/./c',
        'https://client.example/a/../c',
        'https://client.example/a/%2e%2e/c',
        'https://client.example/a/..',
        'https://Client.example/c',
        'https://client.example:443/c',
        'https://client.example/a b',
        'https:///c',
        'https://client.example/${'a' * McpOAuth.maxClientIdUrlLength}',
      ]) {
        expect(McpOAuth.isValidClientIdUrl(url), isFalse, reason: url);
      }
    });

    test('a bad address is refused before any fetch', () async {
      await expectLater(
        oauth.findClient('https://client.example/'),
        oauthError('invalid_client'),
      );
      expect(fetcher.calls, isEmpty);
    });

    test('the address of this server is refused', () async {
      fetcher.serve('https://app.test/mcp', goodDoc('https://app.test/mcp'));
      await expectLater(
        oauth.findClient('https://app.test/mcp'),
        oauthError('invalid_client'),
      );
    });
  });

  group('address blocklist', () {
    test('inside and special addresses are not public', () {
      for (String ip in <String>[
        '0.0.0.0',
        '10.1.2.3',
        '100.64.0.1',
        '100.127.255.255',
        '127.0.0.1',
        '169.254.169.254',
        '172.16.0.1',
        '172.31.255.255',
        '192.0.0.8',
        '192.0.2.1',
        '192.88.99.1',
        '192.168.1.1',
        '198.18.0.1',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
        '240.0.0.1',
        '255.255.255.255',
        '::',
        '::1',
        '::ffff:8.8.8.8',
        '::ffff:127.0.0.1',
        '64:ff9b::808:808',
        'fc00::1',
        'fd12:3456::1',
        'fe80::1',
        'ff02::1',
        '2001::1',
        '2001:db8::1',
        '2002:c0a8:101::1',
      ]) {
        expect(
          McpOAuthHttpFetcher.isPublicAddress(InternetAddress(ip)),
          isFalse,
          reason: ip,
        );
      }
    });

    test('normal internet addresses are public', () {
      for (String ip in <String>[
        '8.8.8.8',
        '1.1.1.1',
        '100.63.255.255',
        '100.128.0.1',
        '172.15.0.1',
        '172.32.0.1',
        '2606:4700:4700::1111',
        '2a00:1450:4001::1',
      ]) {
        expect(
          McpOAuthHttpFetcher.isPublicAddress(InternetAddress(ip)),
          isTrue,
          reason: ip,
        );
      }
    });

    test('the real fetcher never calls an inside address', () async {
      McpOAuthHttpFetcher real = const McpOAuthHttpFetcher();
      for (String url in <String>[
        'https://127.0.0.1/c',
        'https://localhost/c',
        'https://10.0.0.1/c',
        'https://[::1]/c',
        'http://example.com/c',
      ]) {
        await expectLater(
          real.fetch(Uri.parse(url)),
          throwsA(isA<McpOAuthFetchException>()),
          reason: url,
        );
      }
    });

    test('readLimited stops past the limit', () async {
      Stream<List<int>> chunks(int count) {
        return Stream<List<int>>.fromIterable(<List<int>>[
          for (int i = 0; i < count; i++) Uint8List(1000),
        ]);
      }

      expect(
        (await McpOAuthHttpFetcher.readLimited(chunks(5), 5120)).length,
        5000,
      );
      await expectLater(
        McpOAuthHttpFetcher.readLimited(chunks(6), 5120),
        throwsA(isA<McpOAuthFetchException>()),
      );
    });
  });

  group('sign-in with a client metadata document', () {
    test('code -> token, bound to the client id address', () async {
      fetcher.serve(clientUrl, goodDoc());
      McpOAuthClient found = await oauth.verifyClient(clientUrl, redirect);
      expect(found.id, clientUrl);
      expect(found.name, 'Example MCP Client');
      // an address this server can not use is dropped
      expect(found.redirectUris, <String>[redirect]);
      // the consent page shows it next to the name
      expect(found.host, 'client.example');

      String code = await codeFor(clientUrl);
      TestResponse res = await swap(clientUrl, code);
      res.expectStatus(200);
      expect(res.json['token_type'], 'Bearer');
      expect(tokens.grants.last.client.id, clientUrl);
      expect(tokens.grants.last.client.name, 'Example MCP Client');
    });

    test('a code of a document client does not work for another', () async {
      String other = 'https://other.example/client';
      fetcher.serve(clientUrl, goodDoc());
      fetcher.serve(other, goodDoc(other));
      String code = await codeFor(clientUrl);
      TestResponse res = await swap(other, code);
      res.expectStatus(400);
      expect(res.json['error'], 'invalid_grant');
    });

    test('client authentication is refused (method none)', () async {
      fetcher.serve(clientUrl, goodDoc());
      String code = await codeFor(clientUrl);
      TestResponse res = await swap(
        clientUrl,
        code,
        extra: <String, String>{'client_secret': 'x'},
      );
      res.expectStatus(401);
      expect(res.json['error'], 'invalid_client');
    });

    test('a redirect address not in the document is refused', () async {
      fetcher.serve(clientUrl, goodDoc());
      await expectLater(
        oauth.verifyClient(clientUrl, 'http://127.0.0.1:1/other'),
        oauthError('invalid_request'),
      );
      await expectLater(
        oauth.verifyClient(clientUrl, 'myapp://callback'),
        oauthError('invalid_request'),
      );
    });

    test('a loopback redirect may use any port (RFC 8252 7.3)', () async {
      // like the real document of Claude Code
      fetcher.serve(clientUrl, <String, dynamic>{
        ...goodDoc(),
        'redirect_uris': <String>[
          'http://localhost/callback',
          'http://127.0.0.1/callback',
        ],
      });
      for (String uri in <String>[
        'http://localhost:49152/callback',
        'http://127.0.0.1:8080/callback',
        'http://localhost/callback',
      ]) {
        expect((await oauth.verifyClient(clientUrl, uri)).id, clientUrl);
      }
      for (String uri in <String>[
        'http://localhost:49152/other',
        'http://[::1]:49152/callback',
        'https://localhost:49152/callback',
        'http://localhost.evil.test:80/callback',
      ]) {
        await expectLater(
          oauth.verifyClient(clientUrl, uri),
          oauthError('invalid_request'),
          reason: uri,
        );
      }
    });

    test('signed clients keep the exact port', () async {
      TestResponse res = await client.post(
        '/oauth/register',
        headers: <String, String>{'content-type': 'application/json'},
        body: jsonEncode(<String, dynamic>{
          'redirect_uris': <String>['http://localhost/callback'],
        }),
      );
      await expectLater(
        oauth.verifyClient(
          res.json['client_id'] as String,
          'http://localhost:49152/callback',
        ),
        oauthError('invalid_request'),
      );
    });

    test('denyClient sends the browser back with access_denied', () async {
      fetcher.serve(clientUrl, goodDoc());
      Uri url = Uri.parse(
        await oauth.denyClient(
          clientId: clientUrl,
          redirectUri: redirect,
          state: 's',
        ),
      );
      expect(url.queryParameters['error'], 'access_denied');
      expect(url.queryParameters['state'], 's');
    });

    test('the sync methods still know signed clients only', () {
      expect(() => oauth.client(clientUrl), throwsA(isA<McpOAuthException>()));
    });

    test(
      'a load failure gives 401 invalid_client, with no inside text',
      () async {
        TestResponse res = await swap(clientUrl, 'some-code');
        res.expectStatus(401);
        expect(res.json['error'], 'invalid_client');
        expect(jsonEncode(res.json), isNot(contains('10.0.0.7')));
      },
    );
  });

  group('bad documents', () {
    Future<void> refused(
      Map<String, dynamic> body, {
      int status = 200,
      String contentType = 'application/json',
    }) async {
      fetcher.docs.clear();
      fetcher.serve(clientUrl, body, status: status, contentType: contentType);
      fakeNow = fakeNow.add(const Duration(days: 1));
      await expectLater(
        oauth.findClient(clientUrl),
        oauthError('invalid_client'),
        reason: '$status $contentType $body',
      );
    }

    Map<String, dynamic> withField(String key, Object? value) {
      return <String, dynamic>{...goodDoc(), key: value};
    }

    test('each broken rule gives invalid_client', () async {
      await refused(goodDoc('$clientUrl/'));
      await refused(goodDoc('https://client.example/OAuth/metadata.json'));
      await refused(<String, dynamic>{...goodDoc()}..remove('client_id'));
      await refused(<String, dynamic>{...goodDoc()}..remove('client_name'));
      await refused(<String, dynamic>{...goodDoc()}..remove('redirect_uris'));
      await refused(withField('client_name', ' '));
      await refused(withField('redirect_uris', <String>['myapp://cb']));
      await refused(withField('redirect_uris', <String>[]));
      await refused(withField('client_secret', 'x'));
      await refused(withField('client_secret_expires_at', 0));
      await refused(
        withField('token_endpoint_auth_method', 'client_secret_basic'),
      );
      await refused(withField('token_endpoint_auth_method', 'private_key_jwt'));
      await refused(
        withField('token_endpoint_auth_methods_supported', <String>[
          'none',
          'client_secret_post',
        ]),
      );
      await refused(
        withField('token_endpoint_auth_methods_supported', <String>[
          'private_key_jwt',
        ]),
      );
      await refused(<String, dynamic>{
        ...goodDoc(),
        'jwks': <String, dynamic>{},
        'jwks_uri': 'https://client.example/jwks',
      });
      await refused(withField('grant_types', <String>['client_credentials']));
      await refused(withField('response_types', <String>['token']));
      await refused(goodDoc(), status: 404);
      await refused(goodDoc(), status: 302);
      await refused(goodDoc(), contentType: 'text/html');
    });

    test('a document may list none with other methods', () async {
      fetcher.serve(clientUrl, <String, dynamic>{
        ...goodDoc()..remove('token_endpoint_auth_method'),
        'token_endpoint_auth_methods_supported': <String>[
          'private_key_jwt',
          'none',
        ],
        'jwks_uri': 'https://client.example/jwks',
      }, contentType: 'application/client-metadata+json; charset=utf-8');
      expect((await oauth.findClient(clientUrl)).id, clientUrl);
    });

    test('not JSON, or not an object, gives invalid_client', () async {
      for (String body in <String>['not json', '[1]', '"x"']) {
        fakeNow = fakeNow.add(McpOAuth.clientFailureAge);
        fetcher.docs[clientUrl] = McpOAuthFetchedDocument(
          statusCode: 200,
          body: body,
          contentType: 'application/json',
        );
        await expectLater(
          oauth.findClient(clientUrl),
          oauthError('invalid_client'),
        );
      }
    });
  });

  group('allowedClientHosts', () {
    test('another host is refused without a fetch', () async {
      fetcher.serve(
        'https://evil.example/c',
        goodDoc('https://evil.example/c'),
      );
      await expectLater(
        limited.findClient('https://evil.example/c'),
        oauthError('invalid_client'),
      );
      expect(fetcher.calls, isEmpty);
    });

    test(
      'an allowed host works (case of the setting does not matter)',
      () async {
        fetcher.serve(clientUrl, goodDoc());
        expect((await limited.findClient(clientUrl)).id, clientUrl);
      },
    );
  });

  group('cache', () {
    test('a document is kept for max-age, capped', () async {
      fetcher.serve(clientUrl, goodDoc(), cacheControl: 'public, max-age=60');
      await oauth.findClient(clientUrl);
      await oauth.findClient(clientUrl);
      expect(fetcher.calls, hasLength(1));
      fakeNow = fakeNow.add(const Duration(seconds: 61));
      await oauth.findClient(clientUrl);
      expect(fetcher.calls, hasLength(2));

      // a long max-age is cut to clientCacheMaxAge (5 minutes)
      fetcher.serve(clientUrl, goodDoc(), cacheControl: 'max-age=86400');
      fakeNow = fakeNow.add(const Duration(days: 1));
      await oauth.findClient(clientUrl);
      fakeNow = fakeNow.add(const Duration(minutes: 4));
      await oauth.findClient(clientUrl);
      expect(fetcher.calls, hasLength(3));
      fakeNow = fakeNow.add(const Duration(minutes: 1, seconds: 1));
      await oauth.findClient(clientUrl);
      expect(fetcher.calls, hasLength(4));
    });

    test('no-store is not kept', () async {
      fetcher.serve(clientUrl, goodDoc(), cacheControl: 'no-store');
      await oauth.findClient(clientUrl);
      await oauth.findClient(clientUrl);
      expect(fetcher.calls, hasLength(2));
    });

    test('a failure is kept for clientFailureAge, then loaded again', () async {
      for (int i = 0; i < 2; i++) {
        await expectLater(
          oauth.findClient(clientUrl),
          oauthError('invalid_client'),
        );
      }
      expect(fetcher.calls, hasLength(1));
      fetcher.serve(clientUrl, goodDoc());
      fakeNow = fakeNow.add(McpOAuth.clientFailureAge);
      expect((await oauth.findClient(clientUrl)).id, clientUrl);
      expect(fetcher.calls, hasLength(2));
    });

    test('a failed host is skipped for clientFailureAge', () async {
      HostDownFetcher down = HostDownFetcher();
      McpOAuth o = McpOAuth(
        issuer: 'https://app.test',
        tokens: tokens,
        key: utf8.encode('o' * 32),
        clientFetcher: down,
        now: readFakeNow,
      );
      for (String url in <String>[
        'https://down.example/a',
        'https://down.example/b',
      ]) {
        await expectLater(o.findClient(url), oauthError('invalid_client'));
      }
      expect(down.calls, <String>['https://down.example/a']);
      // another port of the host is another key
      await expectLater(
        o.findClient('https://down.example:8443/a'),
        oauthError('invalid_client'),
      );
      expect(down.calls, hasLength(2));
      fakeNow = fakeNow.add(McpOAuth.clientFailureAge);
      await expectLater(
        o.findClient('https://down.example/b'),
        oauthError('invalid_client'),
      );
      expect(down.calls, hasLength(3));
    });

    test('an old document is used when a new load fails', () async {
      fetcher.serve(clientUrl, goodDoc(), cacheControl: 'max-age=60');
      await oauth.findClient(clientUrl);
      fakeNow = fakeNow.add(const Duration(seconds: 61));
      fetcher.docs.clear();
      expect((await oauth.findClient(clientUrl)).id, clientUrl);
      expect(fetcher.calls, hasLength(2));
      // the failure is kept: no new load, the old document again
      expect((await oauth.findClient(clientUrl)).id, clientUrl);
      expect(fetcher.calls, hasLength(2));
      // too old: then it fails
      fakeNow = fakeNow.add(McpOAuth.clientStaleAge);
      await expectLater(
        oauth.findClient(clientUrl),
        oauthError('invalid_client'),
      );
    });

    test('two lookups at once make one fetch', () async {
      fetcher.serve(clientUrl, goodDoc(), cacheControl: 'no-store');
      List<McpOAuthClient> both = await Future.wait(<Future<McpOAuthClient>>[
        oauth.findClient(clientUrl),
        oauth.findClient(clientUrl),
      ]);
      expect(both, hasLength(2));
      expect(fetcher.calls, hasLength(1));
    });
  });

  group('maxClientFetches', () {
    test('a fetch past the cap fails at once, a slot frees after', () async {
      String a = 'https://a.example/c';
      String b = 'https://b.example/c';
      String c = 'https://c.example/c';
      Future<McpOAuthClient> first = capped.findClient(a);
      Future<McpOAuthClient> second = capped.findClient(b);
      // the same address shares the running load, it takes no new slot
      Future<McpOAuthClient> again = capped.findClient(a);
      await expectLater(capped.findClient(c), oauthError('invalid_client'));
      expect(blocking.calls, <String>[a, b]);

      // a load that finishes frees its slot
      blocking.release();
      expect((await first).id, a);
      expect((await second).id, b);
      expect((await again).id, a);

      // a load that fails frees its slot too
      blocking.fail = true;
      Future<McpOAuthClient> failing1 = capped.findClient(a);
      Future<McpOAuthClient> failing2 = capped.findClient(b);
      await expectLater(capped.findClient(c), oauthError('invalid_client'));
      blocking.release();
      await expectLater(failing1, oauthError('invalid_client'));
      await expectLater(failing2, oauthError('invalid_client'));

      blocking.fail = false;
      Future<McpOAuthClient> now = capped.findClient(c);
      blocking.release();
      expect((await now).id, c);
    });
  });

  group('per host and full slots', () {
    test('9 slow loads of one host do not block another host', () async {
      BlockingFetcher slow = BlockingFetcher();
      McpOAuth o = McpOAuth(
        issuer: 'https://app.test',
        tokens: tokens,
        key: utf8.encode('o' * 32),
        clientFetcher: slow,
      );
      // the id, or null when refused
      Future<String?> idOf(String url) async {
        try {
          return (await o.findClient(url)).id;
        } on McpOAuthException {
          return null;
        }
      }

      List<Future<String?>> tarpit = <Future<String?>>[
        for (int i = 0; i < 9; i++) idOf('https://tarpit.example/c$i'),
      ];
      expect(slow.calls, hasLength(o.maxClientFetchesPerHost));
      Future<String?> other = idOf(clientUrl);
      expect(slow.calls.last, clientUrl);
      slow.release();
      expect(await other, clientUrl);
      List<String?> ids = await Future.wait(tarpit);
      expect(ids.whereType<String>(), hasLength(2));
    });

    test('an old document is used when all slots are busy', () async {
      BlockingFetcher slow = BlockingFetcher()..cacheControl = 'max-age=60';
      McpOAuth o = McpOAuth(
        issuer: 'https://app.test',
        tokens: tokens,
        key: utf8.encode('o' * 32),
        clientFetcher: slow,
        now: readFakeNow,
        maxClientFetches: 1,
      );
      Future<McpOAuthClient> first = o.findClient(clientUrl);
      slow.release();
      await first;
      fakeNow = fakeNow.add(const Duration(seconds: 61));
      Future<McpOAuthClient> busy = o.findClient('https://b.example/c');
      expect((await o.findClient(clientUrl)).id, clientUrl);
      expect(slow.calls, <String>[clientUrl, 'https://b.example/c']);
      slow.release();
      await busy;
    });
  });

  group('old consent page: checkClient and deny', () {
    test('a document client works once it is loaded', () async {
      fetcher.serve(clientUrl, goodDoc());
      // not in memory: it starts the load and says no
      expect(
        () => oauth.checkClient(clientUrl, redirect),
        throwsA(isA<McpOAuthException>()),
      );
      expect(fetcher.calls, hasLength(1));
      await pumpEventQueue();

      McpOAuthClient found = oauth.checkClient(clientUrl, redirect);
      expect(found.name, 'Example MCP Client');
      expect(found.host, 'client.example');
      expect(fetcher.calls, hasLength(1));
      expect(
        () => oauth.checkClient(clientUrl, 'http://127.0.0.1:1/other'),
        throwsA(isA<McpOAuthException>()),
      );

      Uri denied = Uri.parse(
        oauth.deny(clientId: clientUrl, redirectUri: redirect, state: 's'),
      );
      expect(denied.queryParameters['error'], 'access_denied');
      expect(
        () =>
            oauth.deny(clientId: clientUrl, redirectUri: 'https://evil.test/'),
        throwsA(isA<McpOAuthException>()),
      );

      TestResponse res = await swap(clientUrl, await codeFor(clientUrl));
      res.expectStatus(200);
      expect(tokens.grants.last.client.id, clientUrl);
    });

    test('after verifyClient it works at once', () async {
      fetcher.serve(clientUrl, goodDoc());
      await oauth.verifyClient(clientUrl, redirect);
      expect(oauth.checkClient(clientUrl, redirect).id, clientUrl);
    });

    test('an old document is used, and loaded again', () async {
      fetcher.serve(clientUrl, goodDoc(), cacheControl: 'max-age=60');
      await oauth.findClient(clientUrl);
      fakeNow = fakeNow.add(const Duration(seconds: 61));
      expect(oauth.checkClient(clientUrl, redirect).id, clientUrl);
      expect(fetcher.calls, hasLength(2));
    });

    test('a bad address is refused with no load', () {
      expect(
        () => oauth.checkClient('https://client.example/', redirect),
        throwsA(isA<McpOAuthException>()),
      );
      expect(fetcher.calls, isEmpty);
    });
  });

  group('server metadata', () {
    test(
      'it says client metadata documents work, and keeps register',
      () async {
        TestResponse res = await client.get(
          '/.well-known/oauth-authorization-server',
        );
        expect(res.json['client_id_metadata_document_supported'], isTrue);
        expect(
          res.json['registration_endpoint'],
          'https://app.test/oauth/register',
        );
      },
    );
  });

  test('signed client ids still work with the async methods', () async {
    TestResponse res = await client.post(
      '/oauth/register',
      headers: <String, String>{'content-type': 'application/json'},
      body: jsonEncode(<String, dynamic>{
        'client_name': 'Old',
        'redirect_uris': <String>[redirect],
      }),
    );
    String id = res.json['client_id'] as String;
    expect((await oauth.verifyClient(id, redirect)).name, 'Old');
    expect(oauth.checkClient(id, redirect).host, isNull);
    expect(fetcher.calls, isEmpty);
  });
}
