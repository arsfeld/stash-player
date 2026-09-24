import 'dart:typed_data';

import 'package:async/async.dart';

/// Byte-granular reads over a chunk-granular socket stream.
///
/// `Socket` hands out whatever the kernel had ready, so a SOCKS5 reply or an
/// HTTP request head can arrive split across chunks or glued to the payload
/// that follows it. This buffers the difference: callers ask for exact byte
/// counts or for everything up to a delimiter, and whatever over-read into
/// the buffer is handed back by [release] rather than dropped.
class ByteReader {
  ByteReader(Stream<Uint8List> stream)
    : _queue = StreamQueue<Uint8List>(stream);

  final StreamQueue<Uint8List> _queue;
  Uint8List _buffer = Uint8List(0);

  /// Reads exactly [count] bytes, waiting across chunk boundaries.
  Future<Uint8List> readExactly(int count) async {
    while (_buffer.length < count) {
      if (!await _queue.hasNext) {
        throw const ByteReaderClosed('stream ended mid-read');
      }
      _append(await _queue.next);
    }
    return _take(count);
  }

  /// Reads up to and including the `\r\n\r\n` that ends an HTTP message head.
  ///
  /// [limit] bounds the buffer so a peer that never sends the terminator
  /// cannot make this grow without end.
  Future<Uint8List> readHead({required int limit}) async {
    var searched = 0;
    while (true) {
      final end = _indexOfTerminator(searched);
      if (end != null) return _take(end);
      if (_buffer.length > limit) {
        throw const ByteReaderClosed('head exceeded its size limit');
      }
      // Re-scan the last 3 bytes: the terminator can straddle two chunks.
      searched = _buffer.length - 3;
      if (searched < 0) searched = 0;
      if (!await _queue.hasNext) {
        throw const ByteReaderClosed(
          'stream ended before the head was complete',
        );
      }
      _append(await _queue.next);
    }
  }

  int? _indexOfTerminator(int from) {
    for (var i = from; i + 3 < _buffer.length; i++) {
      if (_buffer[i] == 0x0d &&
          _buffer[i + 1] == 0x0a &&
          _buffer[i + 2] == 0x0d &&
          _buffer[i + 3] == 0x0a) {
        return i + 4;
      }
    }
    return null;
  }

  /// Hands back everything not yet consumed: the bytes this reader buffered
  /// past the last read, followed by the remainder of the stream. Call once,
  /// when switching from parsing a preamble to splicing the body.
  Stream<Uint8List> release() async* {
    if (_buffer.isNotEmpty) yield _buffer;
    _buffer = Uint8List(0);
    yield* _queue.rest;
  }

  void _append(Uint8List chunk) {
    final grown = Uint8List(_buffer.length + chunk.length)
      ..setRange(0, _buffer.length, _buffer)
      ..setRange(_buffer.length, _buffer.length + chunk.length, chunk);
    _buffer = grown;
  }

  Uint8List _take(int count) {
    final head = Uint8List.sublistView(_buffer, 0, count);
    _buffer = Uint8List.fromList(Uint8List.sublistView(_buffer, count));
    return Uint8List.fromList(head);
  }
}

/// The peer closed before the requested bytes arrived.
class ByteReaderClosed implements Exception {
  const ByteReaderClosed(this.message);

  final String message;

  @override
  String toString() => 'ByteReaderClosed: $message';
}
