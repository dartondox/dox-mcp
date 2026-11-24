import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dox_http_client/dox_http_client.dart';

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
  const McpOAuthFetchException(this.message, {this.hostFailed = false});

  final String message;

  /// True when the host itself failed: not found, not a public address, no
  /// connection, or no answer in time. [McpOAuth] then loads nothing from
  /// that host for a short time. False when the host answered, like a body
  /// that is too big.
  final bool hostFailed;

  @override
  String toString() => 'McpOAuthFetchException: $message';
}

/// The fetcher has no free slot now, like [McpOAuthHttpFetcher] with
/// [McpOAuthHttpFetcher.maxFetchesPerAddress] loads to the same address.
/// Nothing failed: [McpOAuth] does not remember it.
class McpOAuthFetchBusyException extends McpOAuthFetchException {
  const McpOAuthFetchBusyException(super.message);
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

/// The default [McpOAuthClientFetcher]. It uses the native client of
/// `dox_http_client` and guards the
/// server against SSRF (a client that makes the server call an inside
/// address):
///
/// - It looks up the host once. It refuses the fetch when any address is
///   not a public one (see [isPublicAddress]). Then it connects to that
///   checked address, so a second DNS answer cannot point it somewhere
///   else. TLS still checks the certificate of the host name.
/// - No proxy, no redirects, no cookies.
/// - [connectTimeout] for the lookup of the host, [timeout] for all of it.
/// - It reads at most [maxBytes] of the body. A bigger body is an error.
/// - At most [maxFetchesPerAddress] loads go to one IP address at the same
///   time (per isolate). So many host names on one slow server can not take
///   all the slots of [McpOAuth.maxClientFetches].
class McpOAuthHttpFetcher extends McpOAuthClientFetcher {
  const McpOAuthHttpFetcher({
    this.connectTimeout = const Duration(seconds: 3),
    this.timeout = const Duration(seconds: 5),
    this.maxBytes = 5120,
    this.maxFetchesPerAddress = 2,
  });

  final Duration connectTimeout;
  final Duration timeout;

  /// The biggest body it reads. The draft asks for about 5 KB.
  final int maxBytes;

  /// How many loads may go to one IP address at the same time. Past it, a
  /// load throws [McpOAuthFetchBusyException] at once. Default: 2.
  final int maxFetchesPerAddress;

  /// The loads per IP address, in this isolate.
  static final McpOAuthAddressSlots addressSlots = McpOAuthAddressSlots();

  @override
  Future<McpOAuthFetchedDocument> fetch(Uri url) async {
    if (url.scheme != 'https') {
      throw const McpOAuthFetchException('Only https is fetched');
    }
    _Connection connection = _Connection(this);
    DoxHttpClient client = DoxHttpClient(
      // 0 is "no limit" for the client, but not for the fetcher
      timeout: timeout > Duration.zero
          ? timeout
          : const Duration(milliseconds: 1),
      followRedirects: false,
      maxResponseSize: maxBytes < 1 ? 1 : maxBytes,
      lookup: connection.lookup,
    );
    try {
      // the client asks no lookup for an IP address: check it here
      if (InternetAddress.tryParse(url.host) != null) {
        await connection.lookup(url.host);
      }
      DoxHttpClientResponse response = await client.get(
        url,
        headers: const <String, String>{'accept': 'application/json'},
      );
      if (response.bodyBytes.length > maxBytes) {
        throw const McpOAuthFetchException('The body is too big');
      }
      return McpOAuthFetchedDocument(
        statusCode: response.statusCode,
        body: response.body,
        contentType: response.header('content-type'),
        cacheControl: response.header('cache-control'),
      );
    } on DoxHttpClientException catch (error) {
      // the lookup refused the host: its own exception says why
      McpOAuthFetchException? refused = connection.refused;
      if (refused != null) throw refused;
      throw switch (error.failure) {
        DoxHttpFailure.responseTooBig => const McpOAuthFetchException(
          'The body is too big',
        ),
        DoxHttpFailure.timeout => const McpOAuthFetchException(
          'Timed out',
          hostFailed: true,
        ),
        DoxHttpFailure.tlsFailed => const McpOAuthFetchException(
          'TLS failed',
          hostFailed: true,
        ),
        _ => const McpOAuthFetchException('No connection', hostFailed: true),
      };
    } finally {
      client.close();
      connection.end();
    }
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

/// The loads per IP address. [McpOAuthHttpFetcher] takes a slot before it
/// connects and gives it back when the load ends.
class McpOAuthAddressSlots {
  final Map<String, int> _loads = <String, int>{};

  /// How many loads go to [address] now.
  int loads(String address) => _loads[address] ?? 0;

  /// Takes a slot for [address]. False when it has [max] already.
  bool take(String address, int max) {
    int now = loads(address);
    if (now >= max) return false;
    _loads[address] = now + 1;
    return true;
  }

  /// Gives back a slot of [address].
  void release(String address) {
    int now = loads(address) - 1;
    if (now > 0) {
      _loads[address] = now;
    } else {
      _loads.remove(address);
    }
  }
}

/// One load of [McpOAuthHttpFetcher]: it holds the slot of its address.
class _Connection {
  _Connection(this.fetcher);

  final McpOAuthHttpFetcher fetcher;
  String? _address;
  bool _done = false;

  /// Why [lookup] refused the host, or null.
  McpOAuthFetchException? refused;

  /// Looks up [host], checks every address and takes a slot. It gives only
  /// the first address, so the client connects to the checked address and
  /// to no other.
  Future<List<InternetAddress>> lookup(String host) async {
    try {
      return await _lookup(host);
    } on McpOAuthFetchException catch (error) {
      if (!_done) refused = error;
      rethrow;
    }
  }

  Future<List<InternetAddress>> _lookup(String host) async {
    List<InternetAddress> found;
    try {
      found = await InternetAddress.lookup(host)
          .timeout(fetcher.connectTimeout);
    } on Object {
      throw const McpOAuthFetchException(
        'The host was not found',
        hostFailed: true,
      );
    }
    // the load ended while the lookup ran (a timeout): take no slot,
    // nobody would give it back
    if (_done) {
      throw const McpOAuthFetchException('Timed out', hostFailed: true);
    }
    if (found.isEmpty || !found.every(McpOAuthHttpFetcher.isPublicAddress)) {
      throw const McpOAuthFetchException(
        'The host is not a public address',
        hostFailed: true,
      );
    }
    String address = found.first.address;
    if (_address != address) {
      if (!McpOAuthHttpFetcher.addressSlots.take(
        address,
        fetcher.maxFetchesPerAddress,
      )) {
        throw const McpOAuthFetchBusyException('This address is busy');
      }
      release();
      _address = address;
    }
    return <InternetAddress>[found.first];
  }

  /// Ends the load: gives back the slot, once. A lookup that is still
  /// running takes no slot after it.
  void end() {
    _done = true;
    release();
  }

  /// Gives back the slot, once.
  void release() {
    String? address = _address;
    if (address == null) return;
    _address = null;
    McpOAuthHttpFetcher.addressSlots.release(address);
  }
}
