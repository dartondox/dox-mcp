import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What a [McpOAuthClientFetcher] got back for a client metadata document.
class McpOAuthFetchedDocument {
  const McpOAuthFetchedDocument({
    required this.statusCode,
    required this.body,
    this.contentType,
    this.cacheControl,
  });

  /// The HTTP status. Only `200` is a good answer.
  final int statusCode;

  /// The body, as text.
  final String body;

  /// The `Content-Type` header, like `application/json`.
  final String? contentType;

  /// The `Cache-Control` header, like `max-age=300`.
  final String? cacheControl;
}

/// The fetch failed: a network error, a timeout, a blocked address or a
/// body that is too big. The text is for logs only. The client never sees
/// it.
class McpOAuthFetchException implements Exception {
  const McpOAuthFetchException(this.message);

  final String message;

  @override
  String toString() => 'McpOAuthFetchException: $message';
}

/// Loads a client metadata document (a `client_id` that is an `https`
/// address). [McpOAuth] uses [McpOAuthHttpFetcher] by default. A test can
/// give its own fetcher with fake documents.
///
/// [McpOAuth] checks the address rules before it calls [fetch], and checks
/// the status, the content type and the document after it.
abstract class McpOAuthClientFetcher {
  const McpOAuthClientFetcher();

  /// Loads [url]. Throw on any failure.
  Future<McpOAuthFetchedDocument> fetch(Uri url);
}

/// The default [McpOAuthClientFetcher]. It uses `dart:io` and guards the
/// server against SSRF (a client that makes the server call an inside
/// address):
///
/// - It looks up the host once. It refuses the fetch when any address is
///   not a public one (see [isPublicAddress]). Then it connects to that
///   checked address, so a second DNS answer cannot point it somewhere
///   else. TLS still checks the certificate of the host name.
/// - No proxy, no redirects, no cookies.
/// - [connectTimeout] for the connection, [timeout] for all of it.
/// - It reads at most [maxBytes] of the body. A bigger body is an error.
class McpOAuthHttpFetcher extends McpOAuthClientFetcher {
  const McpOAuthHttpFetcher({
    this.connectTimeout = const Duration(seconds: 3),
    this.timeout = const Duration(seconds: 5),
    this.maxBytes = 5120,
  });

  final Duration connectTimeout;
  final Duration timeout;

  /// The biggest body it reads. The draft asks for about 5 KB.
  final int maxBytes;

  @override
  Future<McpOAuthFetchedDocument> fetch(Uri url) async {
    if (url.scheme != 'https') {
      throw const McpOAuthFetchException('Only https is fetched');
    }
    HttpClient client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..findProxy = _direct
      ..connectionFactory = _connect;
    try {
      return await _get(client, url).timeout(timeout);
    } on TimeoutException {
      throw const McpOAuthFetchException('Timed out');
    } finally {
      client.close(force: true);
    }
  }

  Future<McpOAuthFetchedDocument> _get(HttpClient client, Uri url) async {
    HttpClientRequest request = await client.getUrl(url);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    HttpClientResponse response = await request.close();
    if (response.contentLength > maxBytes) {
      throw const McpOAuthFetchException('The body is too big');
    }
    Uint8List bytes = await readLimited(response, maxBytes);
    return McpOAuthFetchedDocument(
      statusCode: response.statusCode,
      body: utf8.decode(bytes, allowMalformed: true),
      contentType: response.headers.value(HttpHeaders.contentTypeHeader),
      cacheControl: response.headers.value(HttpHeaders.cacheControlHeader),
    );
  }

  static String _direct(Uri url) => 'DIRECT';

  /// Looks up the host, checks every address, then connects to the first.
  Future<ConnectionTask<Socket>> _connect(
    Uri url,
    String? proxyHost,
    int? proxyPort,
  ) async {
    List<InternetAddress> found;
    try {
      found = await InternetAddress.lookup(url.host).timeout(connectTimeout);
    } on Object {
      throw const McpOAuthFetchException('The host was not found');
    }
    if (found.isEmpty || !found.every(isPublicAddress)) {
      throw const McpOAuthFetchException('The host is not a public address');
    }
    // the address keeps the host name, so TLS sends it (SNI) and checks
    // the certificate for it
    return SecureSocket.startConnect(found.first, url.port);
  }

  /// Reads [stream] into bytes. Throws when it has more than [maxBytes].
  /// It stops reading at once then.
  static Future<Uint8List> readLimited(
    Stream<List<int>> stream,
    int maxBytes,
  ) async {
    BytesBuilder bytes = BytesBuilder(copy: false);
    await for (List<int> chunk in stream) {
      if (bytes.length + chunk.length > maxBytes) {
        throw const McpOAuthFetchException('The body is too big');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  /// True when [address] is a normal public address on the internet.
  ///
  /// IPv4: false for `0/8`, `10/8`, `100.64/10` (CGNAT), `127/8`,
  /// `169.254/16`, `172.16/12`, `192.0.0/24`, `192.0.2/24`, `192.88.99/24`,
  /// `192.168/16`, `198.18/15`, `198.51.100/24`, `203.0.113/24`, and
  /// `224/3` (multicast, reserved and broadcast).
  ///
  /// IPv6: true only for global unicast (`2000::/3`), but not
  /// `2001::/23` (special use, like Teredo), `2001:db8::/32` (docs) or
  /// `2002::/16` (6to4). So loopback, unspecified, mapped IPv4 (`::ffff:`),
  /// NAT64, unique-local (`fc00::/7`), link-local and multicast are all
  /// false.
  static bool isPublicAddress(InternetAddress address) {
    Uint8List b = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && b.length == 4) {
      return _isPublicIPv4(b);
    }
    if (address.type == InternetAddressType.IPv6 && b.length == 16) {
      return _isPublicIPv6(b);
    }
    return false;
  }

  static bool _isPublicIPv4(Uint8List b) {
    int a = b[0];
    int c = b[1];
    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && c >= 64 && c <= 127) return false;
    if (a == 169 && c == 254) return false;
    if (a == 172 && c >= 16 && c <= 31) return false;
    if (a == 192 && c == 168) return false;
    if (a == 192 && c == 0 && (b[2] == 0 || b[2] == 2)) return false;
    if (a == 192 && c == 88 && b[2] == 99) return false;
    if (a == 198 && (c == 18 || c == 19)) return false;
    if (a == 198 && c == 51 && b[2] == 100) return false;
    if (a == 203 && c == 0 && b[2] == 113) return false;
    return true;
  }

  static bool _isPublicIPv6(Uint8List b) {
    if ((b[0] & 0xe0) != 0x20) return false; // not 2000::/3
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] < 0x02) return false;
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) {
      return false;
    }
    if (b[0] == 0x20 && b[1] == 0x02) return false;
    return true;
  }
}
