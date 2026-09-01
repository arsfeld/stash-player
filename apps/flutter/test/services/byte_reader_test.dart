import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stash_player_flutter/services/byte_reader.dart';

Stream<Uint8List> _chunks(List<List<int>> chunks) =>
    Stream.fromIterable(chunks.map(Uint8List.fromList));

void main() {
  test('readExactly assembles bytes that arrive split across chunks', () async {
    final reader = ByteReader(
      _chunks([
        [0x05, 0x01],
        [0x00],
      ]),
    );

    expect(await reader.readExactly(3), [0x05, 0x01, 0x00]);
  });

  test('readExactly reports a peer that closed mid-read', () async {
    final reader = ByteReader(
      _chunks([
        [0x05],
      ]),
    );

    await expectLater(reader.readExactly(3), throwsA(isA<ByteReaderClosed>()));
  });

  test(
    'readHead returns everything through the blank-line terminator',
    () async {
      final reader = ByteReader(
        _chunks([
          ascii.encode('GET / HTTP/1.1\r\nHost: exam'),
          ascii.encode('ple\r\n\r\nbody'),
        ]),
      );

      final head = await reader.readHead(limit: 1024);

      expect(ascii.decode(head), 'GET / HTTP/1.1\r\nHost: example\r\n\r\n');
    },
  );

  test(
    'release replays the over-read bytes ahead of the rest of the stream',
    () async {
      final reader = ByteReader(
        _chunks([
          ascii.encode('GET / HTTP/1.1\r\n\r\nfirst'),
          ascii.encode('second'),
        ]),
      );
      await reader.readHead(limit: 1024);

      final tail = await reader.release().expand((chunk) => chunk).toList();

      expect(ascii.decode(tail), 'firstsecond');
    },
  );

  test('readHead refuses a head that never terminates', () async {
    final reader = ByteReader(
      _chunks([ascii.encode('GET / HTTP/1.1\r\nX: ${'a' * 64}')]),
    );

    await expectLater(
      reader.readHead(limit: 32),
      throwsA(isA<ByteReaderClosed>()),
    );
  });
}
