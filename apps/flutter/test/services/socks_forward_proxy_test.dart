import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/byte_reader.dart';
import 'package:stash_player_flutter/services/socks_forward_proxy.dart';

void main() {
  group('SocksEndpoint.tryParse', () {
    test('reads an explicit host and port', () {
      final endpoint = SocksEndpoint.tryParse('127.0.0.1:1055');

      expect(endpoint?.host, '127.0.0.1');
      expect(endpoint?.port, 1055);
    });

    test(
      'falls back to the registered SOCKS port when only a host is given',
      () {
        final endpoint = SocksEndpoint.tryParse('socks.example');

        expect(endpoint?.host, 'socks.example');
        expect(endpoint?.port, 1080);
      },
    );

    test('treats a blank setting as no proxy', () {
      expect(SocksEndpoint.tryParse('   '), isNull);
    });

    test('rejects a non-numeric port rather than ignoring it', () {
      expect(SocksEndpoint.tryParse('127.0.0.1:socks'), isNull);
    });

    test('rejects text that cannot be a host name', () {
      expect(SocksEndpoint.tryParse('not a proxy'), isNull);
      expect(SocksEndpoint.tryParse('http://socks.example'), isNull);
    });

    test('rejects a port outside the addressable range', () {
      expect(SocksEndpoint.tryParse('127.0.0.1:70000'), isNull);
    });
  });

  group('SocksForwardProxy', () {
    test('CONNECT tunnels bytes both ways through the SOCKS5 proxy', () async {
      final origin = await _UppercasingEchoServer.start();
      final socks = await _FakeSocksServer.start();
      final proxy = await SocksForwardProxy.bind();
      proxy.endpoint = SocksEndpoint(host: '127.0.0.1', port: socks.port);
      addTearDown(() async {
        await proxy.close();
        await socks.close();
        await origin.close();
      });

      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        proxy.port,
      );
      socket.write(
        'CONNECT 127.0.0.1:${origin.port} HTTP/1.1\r\n'
        'Host: 127.0.0.1:${origin.port}\r\n\r\n',
      );
      await socket.flush();

      final reader = ByteReader(socket);
      final established = ascii.decode(await reader.readHead(limit: 4096));
      expect(established, startsWith('HTTP/1.1 200'));

      socket.write('ping');
      await socket.flush();

      expect(ascii.decode(await reader.readExactly(4)), 'PING');
      expect(socks.requestedTargets, ['127.0.0.1:${origin.port}']);
      await socket.close();
    });

    test(
      'rewrites an absolute-form request to origin-form for the server',
      () async {
        final origin = await _RecordingOriginServer.start(
          response:
              'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok',
        );
        final socks = await _FakeSocksServer.start();
        final proxy = await SocksForwardProxy.bind();
        proxy.endpoint = SocksEndpoint(host: '127.0.0.1', port: socks.port);
        addTearDown(() async {
          await proxy.close();
          await socks.close();
          await origin.close();
        });

        final client = HttpClient()
          ..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
        addTearDown(() => client.close(force: true));

        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${origin.port}/graphql?page=2'),
        );
        final response = await request.close();

        expect(await response.transform(utf8.decoder).join(), 'ok');
        expect(
          origin.heads.single.split('\r\n').first,
          'GET /graphql?page=2 HTTP/1.1',
        );
        expect(socks.requestedTargets, ['127.0.0.1:${origin.port}']);
      },
    );

    test('forwards a request body to the origin', () async {
      final origin = await _RecordingOriginServer.start(
        response:
            'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n'
            'Connection: close\r\n\r\nok',
      );
      final socks = await _FakeSocksServer.start();
      final proxy = await SocksForwardProxy.bind();
      proxy.endpoint = SocksEndpoint(host: '127.0.0.1', port: socks.port);
      addTearDown(() async {
        await proxy.close();
        await socks.close();
        await origin.close();
      });

      final client = HttpClient()
        ..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
      addTearDown(() => client.close(force: true));

      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${origin.port}/graphql'),
      );
      // package:http always sets this, so a chunked body is not a shape
      // this proxy ever sees in production.
      request.contentLength = '{"query":"{version}"}'.length;
      request.write('{"query":"{version}"}');
      await request.close();

      expect(origin.bodies.single, '{"query":"{version}"}');
    });

    test(
      'keeps sequential requests on one client from crossing over',
      () async {
        final first = await _RecordingOriginServer.start(
          response: 'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfirst',
        );
        final second = await _RecordingOriginServer.start(
          response: 'HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nsecond',
        );
        final socks = await _FakeSocksServer.start();
        final proxy = await SocksForwardProxy.bind();
        proxy.endpoint = SocksEndpoint(host: '127.0.0.1', port: socks.port);
        addTearDown(() async {
          await proxy.close();
          await socks.close();
          await first.close();
          await second.close();
        });

        final client = HttpClient()
          ..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
        addTearDown(() => client.close(force: true));

        Future<String> fetch(int port, String path) async {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:$port$path'),
          );
          final response = await request.close();
          return response.transform(utf8.decoder).join();
        }

        expect(await fetch(first.port, '/one'), 'first');
        expect(await fetch(second.port, '/two'), 'second');
        expect(socks.requestedTargets, [
          '127.0.0.1:${first.port}',
          '127.0.0.1:${second.port}',
        ]);
      },
    );

    test('passes a Range response through byte for byte', () async {
      final body = List.generate(4096, (index) => index % 256);
      final origin = await _RangeServingOriginServer.start(body: body);
      final socks = await _FakeSocksServer.start();
      final proxy = await SocksForwardProxy.bind();
      proxy.endpoint = SocksEndpoint(host: '127.0.0.1', port: socks.port);
      addTearDown(() async {
        await proxy.close();
        await socks.close();
        await origin.close();
      });

      final client = HttpClient()
        ..findProxy = (_) => 'PROXY 127.0.0.1:${proxy.port}';
      addTearDown(() => client.close(force: true));

      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${origin.port}/scene/1/stream'),
      );
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=1000-1099');
      final response = await request.close();
      final received = await response.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );

      expect(response.statusCode, HttpStatus.partialContent);
      expect(received, body.sublist(1000, 1100));
    });

    test('answers 502 when the SOCKS proxy refuses the CONNECT', () async {
      final socks = await _FakeSocksServer.start()
        ..connectStatus = 0x05;
      final proxy = await SocksForwardProxy.bind();
      proxy.endpoint = SocksEndpoint(host: '127.0.0.1', port: socks.port);
      addTearDown(() async {
        await proxy.close();
        await socks.close();
      });

      final response = await _refusalFor(proxy, 'stash.example.ts.net:443');

      expect(response, startsWith('HTTP/1.1 502'));
      expect(response, contains('status 0x05'));
    });

    test('answers 502 when the SOCKS handshake is rejected', () async {
      final socks = await _FakeSocksServer.start()
        ..refuseHandshake = true;
      final proxy = await SocksForwardProxy.bind();
      proxy.endpoint = SocksEndpoint(host: '127.0.0.1', port: socks.port);
      addTearDown(() async {
        await proxy.close();
        await socks.close();
      });

      final response = await _refusalFor(proxy, 'stash.example.ts.net:443');

      expect(response, startsWith('HTTP/1.1 502'));
      expect(response, contains('rejected the no-auth handshake'));
    });

    test('answers 502 when no SOCKS endpoint is configured', () async {
      final proxy = await SocksForwardProxy.bind();
      addTearDown(proxy.close);

      final response = await _refusalFor(proxy, 'stash.example.ts.net:443');

      expect(response, startsWith('HTTP/1.1 502'));
      expect(response, contains('no SOCKS5 proxy is configured'));
    });

    test('advertises DIRECT while no endpoint is configured', () async {
      final proxy = await SocksForwardProxy.bind();
      addTearDown(proxy.close);

      expect(proxy.proxyDirective, 'DIRECT');
      expect(proxy.httpProxyUrl, isNull);
    });

    test('advertises its own address once an endpoint is configured', () async {
      final proxy = await SocksForwardProxy.bind();
      addTearDown(proxy.close);

      proxy.endpoint = const SocksEndpoint(host: '127.0.0.1', port: 1055);

      expect(proxy.proxyDirective, 'PROXY 127.0.0.1:${proxy.port}');
      expect(proxy.httpProxyUrl, 'http://127.0.0.1:${proxy.port}');
    });
  });
}

/// Sends [target] through [proxy] as a CONNECT and returns everything it
/// answers with, status line and explanatory body alike. The body matters:
/// a 502 whose text does not say which hop failed leaves the user with
/// nothing to act on.
Future<String> _refusalFor(SocksForwardProxy proxy, String target) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxy.port);
  socket.write('CONNECT $target HTTP/1.1\r\nHost: $target\r\n\r\n');
  await socket.flush();
  final response = await socket.fold<List<int>>(
    <int>[],
    (all, chunk) => all..addAll(chunk),
  );
  await socket.close();
  return ascii.decode(response);
}

/// Serves byte ranges out of a fixed body, so a test can prove the exact
/// slice a seeking player asked for survived the hop.
class _RangeServingOriginServer {
  _RangeServingOriginServer._(this._server);

  final HttpServer _server;

  int get port => _server.port;

  static Future<_RangeServingOriginServer> start({
    required List<int> body,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final bounds = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range ?? '');
      if (bounds == null) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final start = int.parse(bounds.group(1)!);
      final end = int.parse(bounds.group(2)!);
      request.response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${body.length}',
        )
        ..add(body.sublist(start, end + 1));
      await request.response.close();
    });
    return _RangeServingOriginServer._(server);
  }

  Future<void> close() => _server.close(force: true);
}

/// A SOCKS5 proxy that speaks just enough of RFC 1928 to prove the client
/// half correct: no-auth handshake, CONNECT by domain name or IPv4, then a
/// blind splice to the requested target.
class _FakeSocksServer {
  _FakeSocksServer._(this._server);

  final ServerSocket _server;

  /// Every `host:port` a client asked this proxy to reach, in order.
  final requestedTargets = <String>[];

  /// Reply code for CONNECT. Non-zero refuses the request, per RFC 1928.
  int connectStatus = 0x00;

  /// When set, the no-auth handshake is rejected before CONNECT is read.
  bool refuseHandshake = false;

  int get port => _server.port;

  static Future<_FakeSocksServer> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeSocksServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close();

  Future<void> _handle(Socket client) async {
    final reader = ByteReader(client);
    final greeting = await reader.readExactly(2);
    await reader.readExactly(greeting[1]);
    if (refuseHandshake) {
      client.add([0x05, 0xff]);
      await client.close();
      return;
    }
    client.add([0x05, 0x00]);

    final request = await reader.readExactly(4);
    final host = switch (request[3]) {
      0x01 => (await reader.readExactly(4)).join('.'),
      0x03 => ascii.decode(
        await reader.readExactly((await reader.readExactly(1))[0]),
      ),
      _ => throw StateError('unsupported address type ${request[3]}'),
    };
    final portBytes = await reader.readExactly(2);
    final targetPort = (portBytes[0] << 8) | portBytes[1];
    requestedTargets.add('$host:$targetPort');

    if (connectStatus != 0x00) {
      client.add([0x05, connectStatus, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      await client.close();
      return;
    }

    final upstream = await Socket.connect(host, targetPort);
    client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
    unawaited(
      upstream.addStream(reader.release()).whenComplete(upstream.close),
    );
    unawaited(client.addStream(upstream).whenComplete(client.close));
  }
}

/// Captures the raw request head it is sent and answers with a canned
/// response, so a test can assert on the exact bytes an origin server saw
/// rather than on whatever an HTTP library chose to re-serialise.
class _RecordingOriginServer {
  _RecordingOriginServer._(this._server);

  final ServerSocket _server;

  /// One entry per request, as received on the wire.
  final heads = <String>[];

  /// The body of each request, for the requests that carried one.
  final bodies = <String>[];

  int get port => _server.port;

  static Future<_RecordingOriginServer> start({
    required String response,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final origin = _RecordingOriginServer._(server);
    server.listen((socket) async {
      final reader = ByteReader(socket);
      final head = ascii.decode(await reader.readHead(limit: 64 * 1024));
      origin.heads.add(head);
      final length = RegExp(
        r'content-length:\s*(\d+)',
        caseSensitive: false,
      ).firstMatch(head);
      if (length != null) {
        origin.bodies.add(
          ascii.decode(await reader.readExactly(int.parse(length.group(1)!))),
        );
      }
      socket.write(response);
      await socket.flush();
      await socket.close();
    });
    return origin;
  }

  Future<void> close() => _server.close();
}

/// Echoes back whatever it is sent, uppercased, so a test can tell bytes
/// that made the full round trip apart from bytes echoed nearer to home.
class _UppercasingEchoServer {
  _UppercasingEchoServer._(this._server);

  final ServerSocket _server;

  int get port => _server.port;

  static Future<_UppercasingEchoServer> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      socket.listen(
        (chunk) => socket.add(ascii.encode(ascii.decode(chunk).toUpperCase())),
        onDone: socket.close,
        onError: (_) => socket.close(),
      );
    });
    return _UppercasingEchoServer._(server);
  }

  Future<void> close() => _server.close();
}
