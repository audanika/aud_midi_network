// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  final opened = <RawDatagramSocket>[];

  tearDown(() {
    for (final socket in opened) {
      socket.close();
    }
    opened.clear();
  });

  // Retries [bind] while its port is still held by a socket that was just
  // closed: Dart releases closed sockets asynchronously.
  Future<T> retryBind<T>(Future<T> Function() bind) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await bind();
      } on SocketException {
        if (attempt == 50) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  // Binds like the system but fails the calls listed in [failing], counted
  // from 1.
  Future<RawDatagramSocket> Function(dynamic, int) failingBind(
    Set<int> failing,
  ) {
    var calls = 0;
    return (dynamic address, int port) async {
      calls++;
      if (failing.contains(calls)) {
        throw SocketException('Port $port is taken');
      }
      final socket = await retryBind(
        () => RawDatagramSocket.bind(address, port),
      );
      opened.add(socket);
      return socket;
    };
  }

  group('midiBindAdjacent(address, count, firstPort, attempts, bind)', () {
    test('binds adjacent ports', () async {
      final sockets = await midiBindAdjacent(
        address: InternetAddress.loopbackIPv4,
        count: 3,
      );
      opened.addAll(sockets);
      expect([
        for (final socket in sockets) socket.port - sockets.first.port,
      ], equals([0, 1, 2]));
    });

    test('binds the given first port', () async {
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = probe.port;
      probe.close();
      final sockets = await retryBind(
        () => midiBindAdjacent(
          address: InternetAddress.loopbackIPv4,
          count: 1,
          firstPort: port,
        ),
      );
      opened.addAll(sockets);
      expect(sockets.single.port, port);
    });

    test('tries again when a neighbour port is taken', () async {
      final sockets = await midiBindAdjacent(
        address: InternetAddress.loopbackIPv4,
        count: 2,
        bind: failingBind({2}),
      );
      expect(sockets[1].port, sockets[0].port + 1);
      expect(opened.length, 3);
    });

    test('gives up at once for a fixed first port', () async {
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = probe.port;
      probe.close();
      await expectLater(
        midiBindAdjacent(
          address: InternetAddress.loopbackIPv4,
          count: 2,
          firstPort: port,
          bind: failingBind({2, 4}),
        ),
        throwsA(
          isA<SocketException>().having(
            (e) => e.message,
            'message',
            'Port ${port + 1} is taken',
          ),
        ),
      );
      expect(opened.length, 1);
    });

    test('throws the last failure after all attempts', () async {
      await expectLater(
        midiBindAdjacent(
          address: InternetAddress.loopbackIPv4,
          count: 2,
          attempts: 2,
          bind: failingBind({2, 4}),
        ),
        throwsA(isA<SocketException>()),
      );
      expect(opened.length, 2);
    });
  });
}
