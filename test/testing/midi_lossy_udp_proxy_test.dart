// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  final sockets = <RawDatagramSocket>[];
  final inboxes = <RawDatagramSocket, List<Datagram>>{};
  final proxies = <MidiLossyUdpProxy>[];

  tearDown(() async {
    for (final proxy in proxies) {
      await proxy.close();
    }
    proxies.clear();
    for (final socket in sockets) {
      socket.close();
    }
    sockets.clear();
    inboxes.clear();
  });

  RawDatagramSocket watch(RawDatagramSocket socket) {
    sockets.add(socket);
    final inbox = inboxes[socket] = [];
    socket.listen((event) {
      final datagram = event == RawSocketEvent.read ? socket.receive() : null;
      if (datagram != null) {
        inbox.add(datagram);
      }
    });
    return socket;
  }

  Future<RawDatagramSocket> open({InternetAddress? address}) async => watch(
    await RawDatagramSocket.bind(address ?? InternetAddress.loopbackIPv4, 0),
  );

  Future<List<RawDatagramSocket>> openPair() async => [
    for (final socket in await midiBindAdjacent(
      address: InternetAddress.loopbackIPv4,
      count: 2,
    ))
      watch(socket),
  ];

  Future<List<Datagram>> waitFor(
    RawDatagramSocket socket,
    int count, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (inboxes[socket]!.length < count &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    return inboxes[socket]!;
  }

  Future<MidiLossyUdpProxy> startProxy(
    RawDatagramSocket target, {
    int portCount = 1,
    InternetAddress? address,
  }) async {
    final proxy = await MidiLossyUdpProxy.start(
      target: target.address,
      targetPort: target.port,
      portCount: portCount,
      address: address,
    );
    proxies.add(proxy);
    return proxy;
  }

  group('MidiLossyUdpProxy', () {
    group(
      'start(target, targetPort, portCount, address, impairment, seed)',
      () {
        test('forwards in both directions', () async {
          final target = await open();
          final proxy = await startProxy(target);
          final client = await open();
          expect(proxy.target, target.address);
          expect(proxy.targetPort, target.port);
          expect(proxy.address, InternetAddress.loopbackIPv4);
          expect(proxy.portCount, 1);
          expect(proxy.impairment, MidiNetworkImpairment.none);
          client.send([1, 2, 3], proxy.address, proxy.port);
          final request = (await waitFor(target, 1)).single;
          expect(request.data, equals([1, 2, 3]));
          target.send([4], request.address, request.port);
          final reply = (await waitFor(client, 1)).single;
          expect(reply.data, equals([4]));
          expect(reply.port, proxy.port);
          expect(proxy.delivered, 2);
          expect(proxy.dropped, 0);
        });

        test('keeps adjacent ports together', () async {
          final target = await openPair();
          final proxy = await startProxy(
            target.first,
            portCount: 2,
            address: InternetAddress.loopbackIPv4,
          );
          final client = await openPair();
          client[0].send([0], proxy.address, proxy.port);
          client[1].send([1], proxy.address, proxy.port + 1);
          final control = (await waitFor(target[0], 1)).single;
          final data = (await waitFor(target[1], 1)).single;
          expect(data.port, control.port + 1);
          target[1].send([2], data.address, data.port);
          final reply = (await waitFor(client[1], 1)).single;
          expect(reply.data, equals([2]));
          expect(reply.port, proxy.port + 1);
        });

        test('reaches an IPv6 target', () async {
          final target = await open(address: InternetAddress.loopbackIPv6);
          final proxy = await startProxy(target);
          final client = await open();
          client.send([6], proxy.address, proxy.port);
          expect((await waitFor(target, 1)).single.data, equals([6]));
        });
      },
    );

    group('blocked, dropWhere', () {
      test('drop datagrams', () async {
        final target = await open();
        final proxy = await startProxy(target);
        final client = await open();
        proxy.blocked = true;
        client.send([1], proxy.address, proxy.port);
        await waitFor(target, 1, timeout: const Duration(milliseconds: 100));
        expect(inboxes[target], isEmpty);
        proxy
          ..blocked = false
          ..dropWhere = (index, toTarget, data) =>
              index == 0 && toTarget && data.first == 9;
        client
          ..send([9], proxy.address, proxy.port)
          ..send([8], proxy.address, proxy.port);
        final received = await waitFor(target, 1);
        expect(received.map((d) => d.data.first), equals([8]));
        expect(proxy.dropped, 2);
      });
    });

    group('impairment', () {
      test('loses and duplicates datagrams', () async {
        final target = await open();
        final proxy = await startProxy(target);
        final client = await open();
        proxy.impairment = const MidiNetworkImpairment(loss: 1);
        client.send([1], proxy.address, proxy.port);
        await waitFor(target, 1, timeout: const Duration(milliseconds: 100));
        expect(proxy.dropped, 1);
        proxy.impairment = const MidiNetworkImpairment(duplicate: 1);
        client.send([2], proxy.address, proxy.port);
        final received = await waitFor(target, 2);
        expect(received.map((d) => d.data.first), equals([2, 2]));
        expect(proxy.duplicated, 1);
        expect(proxy.delivered, 2);
      });

      test('lets later datagrams overtake a reordered one', () async {
        final target = await open();
        final proxy = await startProxy(target);
        final client = await open();
        proxy.impairment = const MidiNetworkImpairment(
          reorder: 1,
          reorderDelay: Duration(milliseconds: 50),
        );
        client.send([1], proxy.address, proxy.port);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        proxy.impairment = MidiNetworkImpairment.none;
        client.send([2], proxy.address, proxy.port);
        final received = await waitFor(target, 2);
        expect(received.map((d) => d.data.first), equals([2, 1]));
        expect(proxy.reordered, 1);
      });
    });

    group('close()', () {
      test('drops the datagrams in flight', () async {
        final target = await open();
        final proxy = await startProxy(target);
        final client = await open();
        proxy.impairment = const MidiNetworkImpairment(
          delay: Duration(milliseconds: 100),
        );
        client.send([1], proxy.address, proxy.port);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await proxy.close();
        await proxy.close();
        await waitFor(target, 1, timeout: const Duration(milliseconds: 200));
        expect(inboxes[target], isEmpty);
      });
    });
  });
}
