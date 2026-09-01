import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'byte_reader.dart';

/// The SOCKS5 proxy the forward proxy hops through, as configured.
class SocksEndpoint {
  const SocksEndpoint({required this.host, required this.port});

  final String host;
  final int port;

  /// Parses a `host` or `host:port` setting. Returns null for anything
  /// unusable, blank included, so callers can treat "not configured" and
  /// "typed wrong" as the single question "is there an endpoint here".
  static SocksEndpoint? tryParse(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;

    final separator = trimmed.lastIndexOf(':');
    if (separator < 0) {
      return _hostPattern.hasMatch(trimmed)
          ? SocksEndpoint(host: trimmed, port: defaultPort)
          : null;
    }

    final host = trimmed.substring(0, separator);
    final port = int.tryParse(trimmed.substring(separator + 1));
    if (!_hostPattern.hasMatch(host)) return null;
    if (port == null || port < 1 || port > 65535) return null;
    return SocksEndpoint(host: host, port: port);
  }

  /// A host name or IPv4 literal. Deliberately narrow: everything this
  /// rejects (spaces, a URL scheme, a bare IPv6 address) would otherwise be
  /// accepted as a host and fail much later, as an unexplained timeout.
  static final RegExp _hostPattern = RegExp(r'^[A-Za-z0-9._-]+$');

  /// The registered SOCKS port, used when the setting names only a host.
  /// Tailscale's userspace mode listens on 1055 instead, so its users have
  /// to say so; every other SOCKS proxy defaults here.
  static const int defaultPort = 1080;

  @override
  String toString() => '$host:$port';
}

/// Loopback HTTP forward proxy that hops through a SOCKS5 proxy.
///
/// Tailscale in userspace mode (`--tun=userspace-networking`) reaches the
/// tailnet only through a SOCKS5 port: there is no interface, so a tailnet
/// hostname does not resolve and its 100.x address does not route. Nothing
/// in this app's media path can use that directly. `package:http` offers no
/// SOCKS, and playback is libmpv, which does its own networking in C and
/// understands only `--http-proxy`.
///
/// Both of them do speak HTTP proxying, so that is what this is: a listener
/// on `127.0.0.1` that accepts `CONNECT` and absolute-form requests and
/// re-issues them over the SOCKS hop.
///
/// Being a *forward* proxy rather than a reverse one is what keeps it small.
/// The client asks for the real upstream URL, so nothing here has to rewrite
/// the absolute URLs Stash returns when `external_host` is configured, and
/// nothing has to understand ranges, redirects or chunked encoding. For
/// `CONNECT` the payload stays inside the client's own TLS session, so this
/// proxy never sees the API key or a response body.
class SocksForwardProxy {
  SocksForwardProxy._(this._server);

  final ServerSocket _server;

  /// The SOCKS5 proxy to hop through, or null when none is configured.
  ///
  /// Read per connection rather than captured at bind time, so changing the
  /// setting takes effect on the next request without rebinding the listener
  /// and invalidating a URL the player is already streaming from.
  SocksEndpoint? endpoint;

  /// A request head longer than this is a client bug or an attack, not a
  /// request worth serving.
  static const int _headLimit = 64 * 1024;

  int get port => _server.port;

  /// What to hand `HttpClient.findProxy`. Evaluated per request, so a
  /// settings change reaches in-flight clients without rebuilding them.
  String get proxyDirective =>
      endpoint == null ? 'DIRECT' : 'PROXY 127.0.0.1:$port';

  /// What to hand libmpv's `http-proxy`, or null when nothing should be
  /// proxied. mpv has no equivalent of `DIRECT`, so absence is the signal.
  String? get httpProxyUrl =>
      endpoint == null ? null : 'http://127.0.0.1:$port';

  static Future<SocksForwardProxy> bind() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = SocksForwardProxy._(server);
    server.listen(proxy._accept, onError: (_) {});
    return proxy;
  }

  Future<void> close() => _server.close();

  Future<void> _accept(Socket client) async {
    client.setOption(SocketOption.tcpNoDelay, true);
    final reader = ByteReader(client);
    try {
      final head = ascii.decode(await reader.readHead(limit: _headLimit));
      final request = _ProxiedRequest.parse(head);
      final via = endpoint;
      if (via == null) {
        await _refuse(client, 'no SOCKS5 proxy is configured');
        return;
      }
      final upstream = await _socksConnect(via, request.host, request.port);
      final rewritten = request.rewrittenHead;
      if (rewritten == null) {
        client.write('HTTP/1.1 200 Connection established\r\n\r\n');
        _splice(client, reader, upstream.socket, upstream.incoming);
        return;
      }
      await _forward(client, reader, upstream, rewritten);
    } on Object catch (error) {
      await _refuse(client, '$error');
    }
  }

  /// Answers a request this proxy cannot serve with a real status line.
  ///
  /// A bare connection reset would reach the player as an opaque decode
  /// failure; a 502 reaches it as a failed request, which is what it is.
  Future<void> _refuse(Socket client, String reason) async {
    try {
      client
        ..write('HTTP/1.1 502 Bad Gateway\r\n')
        ..write('Content-Type: text/plain\r\n')
        ..write('Connection: close\r\n\r\n')
        ..write('stash-player: $reason\n');
      await client.flush();
    } on Object {
      // The client is already gone; there is nowhere to report that.
    }
    await client.close();
  }

  /// Replays a rewritten request head upstream, then hands the response
  /// back with its connection headers replaced by `Connection: close`.
  ///
  /// The rewrite is what makes one-request-per-connection safe. This proxy
  /// commits each accepted connection to a single upstream, so a client that
  /// reused one for a second request, to a different host even, would
  /// find it already spoken for. A client decides reuse from the *response*,
  /// so telling it here is the only way to be sure, rather than hoping the
  /// origin honours the `Connection: close` sent with the request.
  Future<void> _forward(
    Socket client,
    ByteReader reader,
    _Upstream upstream,
    String rewrittenHead,
  ) async {
    upstream.socket.write(rewrittenHead);
    // Started before the response is awaited: an origin waiting on a request
    // body would otherwise never answer, and both sides would sit still.
    unawaited(
      upstream.socket
          .addStream(reader.release())
          .whenComplete(upstream.socket.close)
          .catchError((_) {}),
    );

    final response = ByteReader(upstream.incoming);
    final head = ascii.decode(await response.readHead(limit: _headLimit));
    client.write(_closingHead(head));
    unawaited(
      client
          .addStream(response.release())
          .whenComplete(client.close)
          .catchError((_) {}),
    );
  }

  /// Re-emits a response head with every connection-management header
  /// replaced by a single `Connection: close`.
  static String _closingHead(String head) {
    final rewritten = StringBuffer();
    final lines = head.split('\r\n');
    rewritten.write('${lines.first}\r\n');
    for (final line in lines.skip(1)) {
      if (line.isEmpty) break;
      if (_ProxiedRequest.isHopByHop(line)) continue;
      rewritten.write('$line\r\n');
    }
    rewritten.write('Connection: close\r\n\r\n');
    return rewritten.toString();
  }

  void _splice(
    Socket client,
    ByteReader reader,
    Socket upstream,
    Stream<Uint8List> incoming,
  ) {
    unawaited(
      upstream
          .addStream(reader.release())
          .whenComplete(upstream.close)
          .catchError((_) {}),
    );
    unawaited(
      client.addStream(incoming).whenComplete(client.close).catchError((_) {}),
    );
  }

  /// Opens a TCP connection to [host]:[port] through the SOCKS5 proxy,
  /// per RFC 1928: no-auth handshake, then CONNECT by domain name so the
  /// proxy resolves the name on the tailnet side, where it is resolvable.
  Future<_Upstream> _socksConnect(
    SocksEndpoint via,
    String host,
    int port,
  ) async {
    final socket = await Socket.connect(
      via.host,
      via.port,
      timeout: const Duration(seconds: 10),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    final reader = ByteReader(socket);
    try {
      socket.add(const [0x05, 0x01, 0x00]);
      final greeting = await reader.readExactly(2);
      if (greeting[0] != 0x05 || greeting[1] != 0x00) {
        throw SocksFailure('proxy rejected the no-auth handshake');
      }

      final name = ascii.encode(host);
      if (name.length > 255) throw SocksFailure('host name too long: $host');
      socket.add([
        0x05, 0x01, 0x00, 0x03, //
        name.length, ...name,
        (port >> 8) & 0xff, port & 0xff,
      ]);

      final reply = await reader.readExactly(4);
      if (reply[1] != 0x00) {
        throw SocksFailure(
          'CONNECT to $host:$port failed with '
          'status 0x${reply[1].toRadixString(16).padLeft(2, '0')}',
        );
      }
      await _drainBoundAddress(reader, reply[3]);
      return _Upstream(socket, reader.release());
    } on Object {
      socket.destroy();
      rethrow;
    }
  }

  /// Reads past the BND.ADDR/BND.PORT the proxy echoes after CONNECT, so the
  /// stream handed to the splice starts at the first payload byte.
  Future<void> _drainBoundAddress(ByteReader reader, int addressType) async {
    switch (addressType) {
      case 0x01:
        await reader.readExactly(4);
      case 0x03:
        await reader.readExactly((await reader.readExactly(1))[0]);
      case 0x04:
        await reader.readExactly(16);
      default:
        throw SocksFailure('proxy returned unknown address type $addressType');
    }
    await reader.readExactly(2);
  }
}

/// An open upstream socket plus the inbound bytes already read off it while
/// parsing the SOCKS5 reply, which would otherwise be lost to the splice.
class _Upstream {
  _Upstream(this.socket, this.incoming);

  final Socket socket;
  final Stream<Uint8List> incoming;
}

/// A request this proxy has been asked to forward.
class _ProxiedRequest {
  _ProxiedRequest({
    required this.host,
    required this.port,
    required this.rewrittenHead,
  });

  final String host;
  final int port;

  /// The head to replay upstream, in origin-form. Null for `CONNECT`,
  /// whose payload is opaque to this proxy by design.
  final String? rewrittenHead;

  static _ProxiedRequest parse(String head) {
    final lines = head.split('\r\n');
    final fields = lines.first.split(' ');
    if (fields.length < 3) throw SocksFailure('malformed request line');
    final method = fields[0];
    final target = fields[1];
    final version = fields[2];

    if (method.toUpperCase() == 'CONNECT') return _tunnel(target);
    return _forward(lines, method, target, version);
  }

  /// `CONNECT host:port HTTP/1.1`. The client runs its own TLS session
  /// through the tunnel, so there is no head to rewrite.
  static _ProxiedRequest _tunnel(String authority) {
    final separator = authority.lastIndexOf(':');
    final port = separator < 0
        ? null
        : int.tryParse(authority.substring(separator + 1));
    if (port == null) throw SocksFailure('CONNECT target needs a port');
    return _ProxiedRequest(
      host: authority.substring(0, separator),
      port: port,
      rewrittenHead: null,
    );
  }

  /// `GET http://host/path HTTP/1.1`: a plain-HTTP upstream, which a proxy
  /// is asked for in absolute-form and an origin server expects in
  /// origin-form.
  static _ProxiedRequest _forward(
    List<String> lines,
    String method,
    String target,
    String version,
  ) {
    final uri = Uri.tryParse(target);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw SocksFailure('expected an absolute request target, got $target');
    }

    final head = StringBuffer('$method ${_originForm(target)} $version\r\n');
    for (final line in lines.skip(1)) {
      if (line.isEmpty) break;
      if (isHopByHop(line)) continue;
      head.write('$line\r\n');
    }
    // Each accepted connection is spliced to exactly one upstream, so a
    // client that reused this one for a second request, to a different
    // host even, would find it already committed elsewhere. Asking the
    // origin to close ends the exchange at the response, which is what
    // stops the client reusing it.
    head.write('Connection: close\r\n\r\n');

    return _ProxiedRequest(
      host: uri.host,
      port: uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80),
      rewrittenHead: head.toString(),
    );
  }

  /// Slices the path out of the raw target rather than re-serialising
  /// `Uri.path`, which decodes percent-escapes and would hand the origin a
  /// different path than the client asked for.
  static String _originForm(String target) {
    final authorityStart = target.indexOf('://') + 3;
    final pathStart =
        [
              target.indexOf('/', authorityStart),
              target.indexOf('?', authorityStart),
              target.indexOf('#', authorityStart),
            ]
            .where((index) => index >= 0)
            .fold<int>(-1, (a, b) => a < 0 ? b : (b < a ? b : a));
    return pathStart < 0 ? '/' : target.substring(pathStart);
  }

  /// Headers that address the hop rather than the origin, and so must not
  /// travel onward. The connection ones are replaced with `Connection:
  /// close` rather than merely dropped. See [SocksForwardProxy._forward].
  static bool isHopByHop(String line) {
    final name = line.split(':').first.trim().toLowerCase();
    return const {
      'proxy-connection',
      'proxy-authorization',
      'connection',
      'keep-alive',
    }.contains(name);
  }
}

/// The SOCKS hop could not be established.
class SocksFailure implements Exception {
  SocksFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
