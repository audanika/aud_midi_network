// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  final sessions = <MidiNetworkMidi2Session>[];
  final proxies = <MidiLossyUdpProxy>[];
  final sockets = <RawDatagramSocket>[];

  tearDown(() async {
    for (final session in sessions) {
      await session.close();
    }
    sessions.clear();
    for (final proxy in proxies) {
      await proxy.close();
    }
    proxies.clear();
    for (final socket in sockets) {
      socket.close();
    }
    sockets.clear();
  });

  const fast = MidiNetworkMidi2Settings(
    invitationInterval: Duration(milliseconds: 50),
    invitationAttempts: 3,
    pingInterval: Duration(milliseconds: 100),
    missedPingLimit: 3,
    byeTimeout: Duration(milliseconds: 50),
    byeAttempts: 2,
    reconnectInterval: Duration(seconds: 10),
    retransmitDelay: Duration(milliseconds: 5),
  );

  Future<MidiNetworkMidi2Session> start(
    String name, {
    MidiNetworkAccess? access,
    MidiNetworkMidi2Settings settings = fast,
    MidiNetworkMidi2SharedSecret? requiredSecret,
    MidiNetworkMidi2Credentials? Function(MidiNetworkHostInfo host)?
    credentialsFor,
    int port = 0,
  }) async {
    final session = MidiNetworkMidi2Session(
      localName: name,
      productInstanceId: '$name-ID',
      requestedPort: port,
      address: InternetAddress.loopbackIPv4,
      access: access,
      settings: settings,
      requiredSecret: requiredSecret,
      credentialsFor: credentialsFor,
    );
    sessions.add(session);
    await session.open();
    return session;
  }

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

  MidiNetworkHostInfo hostOf(
    MidiNetworkMidi2Session session, {
    String address = '127.0.0.1',
    int? port,
  }) => MidiNetworkHostInfo(
    name: session.localName,
    address: address,
    port: port ?? session.port,
    serviceType: MidiNetworkMidi2Session.serviceType,
  );

  Future<void> eventually(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('The condition did not become true in $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  List<int> collect(MidiNetworkMidi2Session session) {
    final words = <int>[];
    session.received.listen(
      (received) => words.addAll((received.packet as MidiUmpPacket).words),
    );
    return words;
  }

  MidiUmpPacket ump(List<int> words) =>
      MidiUmpPacket(words: words, time: MidiTime.zero);

  int note(int number) => 0x20900064 | ((number & 0x7F) << 8);

  group('MidiNetworkMidi2Session', () {
    group('open(), close()', () {
      test('bind and release the socket', () async {
        final session = MidiNetworkMidi2Session(localName: 'S');
        sessions.add(session);
        expect(session.isOpen, isFalse);
        expect(session.port, 0);
        await session.open();
        final port = session.port;
        expect(port, greaterThan(0));
        expect(session.isOpen, isTrue);
        await session.open();
        expect(session.port, port);
        await session.close();
        await session.close();
        expect(session.isOpen, isFalse);
        expect(session.port, 0);
      });

      test('bind the requested port', () async {
        final probe = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final port = probe.port;
        probe.close();
        final session = await retryBind(() => start('S', port: port));
        expect(session.port, port);
        expect(session.requestedPort, port);
      });

      test('say bye to every peer', () async {
        final host = await start('Host');
        final client = await start('Client');
        final connection = await client.connect(hostOf(host));
        await host.close();
        await eventually(
          () => connection.state == MidiNetworkConnectionState.disconnected,
        );
        expect(host.connections, isEmpty);
      });
    });

    group('connect(host, credentials)', () {
      test('carries packets in both directions', () async {
        final host = await start('Host');
        final client = await start('Client');
        final atHost = collect(host);
        final atClient = collect(client);
        final changed = <MidiNetworkConnection>[];
        host.connectionChanges.listen(changed.add);
        final connection = await client.connect(hostOf(host));
        expect(connection.state, MidiNetworkConnectionState.connected);
        expect(connection.remoteName, 'Host');
        expect(connection.remoteProductInstanceId, 'Host-ID');
        expect(client.connections, equals([connection]));
        await eventually(() => host.connections.isNotEmpty);
        final incoming = host.connections.single;
        expect(incoming.isIncoming, isTrue);
        expect(incoming.remoteName, 'Client');
        expect(changed, contains(incoming));
        await connection.send(ump([note(1), note(2)]));
        await incoming.send(ump([0x40903C00, 0xC8000000]));
        await eventually(() => atHost.length == 2 && atClient.length == 2);
        expect(atHost, equals([note(1), note(2)]));
        expect(atClient, equals([0x40903C00, 0xC8000000]));
        expect(
          identical(await client.connect(hostOf(host)), connection),
          isTrue,
        );
      });

      test('resolves host names', () async {
        final host = await start('Host');
        final client = await start('Client');
        final connection = await client.connect(
          hostOf(host, address: 'localhost'),
        );
        expect(connection.state, MidiNetworkConnectionState.connected);
        await client.disconnect(hostOf(host, address: 'localhost'));
        expect(connection.state, MidiNetworkConnectionState.disconnected);
      });

      test('throws while the session is closed', () async {
        final client = MidiNetworkMidi2Session(localName: 'Client');
        await expectLater(
          client.connect(
            const MidiNetworkHostInfo(name: 'H', address: '127.0.0.1', port: 1),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'The session Client is closed',
            ),
          ),
        );
      });

      test('fails when nobody answers', () async {
        final silent = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        sockets.add(silent);
        final client = await start('Client');
        final connection = await client.connect(
          MidiNetworkHostInfo(
            name: 'Nobody',
            address: '127.0.0.1',
            port: silent.port,
          ),
        );
        expect(connection.state, MidiNetworkConnectionState.failed);
        expect(client.connections, isEmpty);
      });

      test('authenticates with the shared secret', () async {
        const secret = MidiNetworkMidi2SharedSecret('s3cret');
        final host = await start('Host', requiredSecret: secret);
        final client = await start(
          'Client',
          credentialsFor: (host) => host.name == 'Host' ? secret : null,
        );
        final first = await client.connect(hostOf(host));
        expect(first.state, MidiNetworkConnectionState.connected);
        final other = await start('Other');
        final second = await other.connect(
          hostOf(host),
          credentials: const MidiNetworkMidi2SharedSecret('wrong'),
        );
        expect(second.state, MidiNetworkConnectionState.failed);
        expect(second.endReason, 'the host rejected the credentials');
      });

      test('replaces a connection that failed', () async {
        final host = await start('Host');
        final client = await start('Client');
        final proxy = await MidiLossyUdpProxy.start(
          target: InternetAddress.loopbackIPv4,
          targetPort: host.port,
        );
        proxies.add(proxy);
        final target = hostOf(host, port: proxy.port);
        final first = await client.connect(target);
        proxy.blocked = true;
        await eventually(
          () => first.state == MidiNetworkConnectionState.failed,
        );
        expect(first.isReconnecting, isTrue);
        expect(client.connections, equals([first]));
        proxy.blocked = false;
        final second = await client.connect(target);
        expect(identical(second, first), isFalse);
        expect(second.state, MidiNetworkConnectionState.connected);
        expect(first.state, MidiNetworkConnectionState.disconnected);
      });
    });

    group('access', () {
      test('admits the allowed peers only', () async {
        final host = await start(
          'Host',
          access: MidiNetworkAccess(
            policy: MidiNetworkConnectionPolicy.specificPeers,
            allowedPeers: {'Friend'},
          ),
        );
        final stranger = await start('Stranger');
        final refused = await stranger.connect(hostOf(host));
        expect(refused.state, MidiNetworkConnectionState.failed);
        expect(refused.endReason, 'the peer said bye (reason 66)');
        final friend = await start('Friend');
        final admitted = await friend.connect(hostOf(host));
        expect(admitted.state, MidiNetworkConnectionState.connected);
      });

      test('admits no more than the most sessions', () async {
        final host = await start(
          'Host',
          settings: const MidiNetworkMidi2Settings(maxSessions: 1),
        );
        final first = await (await start('A')).connect(hostOf(host));
        expect(first.state, MidiNetworkConnectionState.connected);
        final second = await (await start('B')).connect(hostOf(host));
        expect(second.state, MidiNetworkConnectionState.failed);
        expect(second.endReason, 'the peer said bye (reason 64)');
      });
    });

    group('peers without session', () {
      test('get stateless answers', () async {
        final host = await start('Host');
        final peer = await RawDatagramSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        sockets.add(peer);
        final answers = <List<MidiNetworkMidi2Command>>[];
        peer.listen((event) {
          final datagram = event == RawSocketEvent.read ? peer.receive() : null;
          if (datagram != null) {
            answers.add(MidiNetworkMidi2Command.decodePacket(datagram.data));
          }
        });
        void send(List<MidiNetworkMidi2Command> commands) => peer.send(
          MidiNetworkMidi2Command.encodePacket(commands),
          InternetAddress.loopbackIPv4,
          host.port,
        );
        peer.send([1, 2, 3, 4], InternetAddress.loopbackIPv4, host.port);
        send([MidiNetworkMidi2UnknownCommand(code: 0x55)]);
        send([
          const MidiNetworkMidi2Ping(pingId: 5),
          const MidiNetworkMidi2Bye(reason: 1),
          MidiNetworkMidi2InvitationWithAuthentication(
            digest: List.filled(32, 0),
          ),
          MidiNetworkMidi2UmpData(sequenceNumber: 0),
          const MidiNetworkMidi2SessionReset(),
        ]);
        await eventually(() => answers.isNotEmpty);
        expect(
          answers.single,
          equals([
            const MidiNetworkMidi2PingReply(pingId: 5),
            const MidiNetworkMidi2ByeReply(),
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonMissingPriorInvitation,
            ),
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonSessionNotEstablished,
            ),
          ]),
        );
        expect(host.connections, isEmpty);
      });
    });

    group('disconnect(host)', () {
      test('ends connections of both roles', () async {
        final host = await start('Host');
        final client = await start('Client');
        final outgoing = await client.connect(hostOf(host));
        await eventually(() => host.connections.isNotEmpty);
        final incoming = host.connections.single;
        await host.disconnect(incoming.host);
        expect(incoming.state, MidiNetworkConnectionState.disconnected);
        await eventually(
          () => outgoing.state == MidiNetworkConnectionState.disconnected,
        );
        final again = await client.connect(hostOf(host));
        await client.disconnect(hostOf(host));
        expect(again.state, MidiNetworkConnectionState.disconnected);
        expect(client.connections, isEmpty);
        await client.disconnect(
          const MidiNetworkHostInfo(
            name: 'Unknown',
            address: 'example.invalid',
            port: 1,
          ),
        );
      });
    });

    group('under loss', () {
      test('repairs loss with error correction and retransmission', () async {
        final host = await start(
          'Host',
          settings: const MidiNetworkMidi2Settings(
            missedPingLimit: 20,
            retransmitAttempts: 6,
          ),
        );
        final client = await start(
          'Client',
          settings: const MidiNetworkMidi2Settings(missedPingLimit: 20),
        );
        final atHost = collect(host);
        final losses = <MidiNetworkLoss>[];
        host.losses.listen(losses.add);
        final proxy = await MidiLossyUdpProxy.start(
          target: InternetAddress.loopbackIPv4,
          targetPort: host.port,
          seed: 7,
        );
        proxies.add(proxy);
        final connection = await client.connect(hostOf(host, port: proxy.port));
        proxy.impairment = const MidiNetworkImpairment(
          loss: 0.1,
          burstStart: 0.03,
          burstEnd: 0.4,
          reorder: 0.05,
          duplicate: 0.05,
        );
        final sent = <int>[];
        for (var i = 0; i < 300; i++) {
          sent.add(note(i));
          await connection.send(ump([note(i)]));
          if (i % 10 == 9) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
        }
        await eventually(() => atHost.length == sent.length);
        expect(atHost, equals(sent));
        expect(losses, isEmpty);
        expect(proxy.dropped, greaterThan(10));
        final stats = (host.connections.single).lossStats;
        expect(stats.packetsLost, stats.packetsRecovered);
      });

      test('reports what the error correction cannot repair', () async {
        final host = await start(
          'Host',
          settings: const MidiNetworkMidi2Settings(missedPingLimit: 20),
        );
        final client = await start(
          'Client',
          settings: const MidiNetworkMidi2Settings(
            missedPingLimit: 20,
            retransmitBufferSize: 0,
            forwardErrorCorrection: 1,
          ),
        );
        final atHost = collect(host);
        final losses = <MidiNetworkLoss>[];
        host.losses.listen(losses.add);
        final proxy = await MidiLossyUdpProxy.start(
          target: InternetAddress.loopbackIPv4,
          targetPort: host.port,
          seed: 3,
        );
        proxies.add(proxy);
        final connection = await client.connect(hostOf(host, port: proxy.port));
        var index = 0;
        proxy.dropWhere = (portIndex, toTarget, data) {
          final commands = MidiNetworkMidi2Command.decodePacket(data);
          final carriesData = commands.whereType<MidiNetworkMidi2UmpData>().any(
            (d) => d.words.isNotEmpty,
          );
          return toTarget && carriesData && (index++ % 10) < 3;
        };
        for (var i = 0; i < 50; i++) {
          await connection.send(ump([note(i)]));
        }
        await eventually(() => losses.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final lost = losses.fold(0, (sum, loss) => sum + loss.count);
        expect(atHost.length + lost, greaterThanOrEqualTo(50));
        expect(losses.first.cause, 'the peer does not retransmit');
        expect(
          identical(losses.first.connection, host.connections.single),
          isTrue,
        );
      });
    });

    group('fields', () {
      test('describe the session', () {
        final session = MidiNetworkMidi2Session(localName: 'Desk');
        expect(session.protocol, MidiNetworkProtocol.networkMidi2);
        expect(session.productInstanceId, matches(RegExp(r'^[0-9A-F]{16}$')));
        expect(session.address, InternetAddress.anyIPv4);
        expect(session.access, MidiNetworkAccess());
        expect(session.requiredSecret, isNull);
        expect(session.requiredUsers, isEmpty);
        expect(session.credentialsFor, isNull);
        expect(session.settings.forwardErrorCorrection, 2);
        expect(session.connections, isEmpty);
        expect(
          session.txtRecord,
          equals({
            'UMPEndpointName': 'Desk',
            'ProductInstanceId': session.productInstanceId,
          }),
        );
        expect(MidiNetworkMidi2Session.serviceType, '_midi2._udp');
      });
    });
  });
}
