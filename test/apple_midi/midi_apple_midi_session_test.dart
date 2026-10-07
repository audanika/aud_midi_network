// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';
import 'dart:math';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  final sessions = <MidiAppleMidiSession>[];
  final proxies = <MidiLossyUdpProxy>[];
  final sockets = <RawDatagramSocket>[];
  const clock = MidiSystemClock();

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

  const fast = MidiAppleMidiSettings(
    invitationInterval: Duration(milliseconds: 50),
    maxInvitationInterval: Duration(milliseconds: 100),
    invitationAttempts: 4,
    initialSyncInterval: Duration(milliseconds: 30),
    initialSyncCount: 6,
    syncInterval: Duration(milliseconds: 200),
    missedSyncLimit: 3,
    sessionTimeout: Duration(milliseconds: 800),
    feedbackInterval: Duration(milliseconds: 20),
    reconnectInterval: Duration(seconds: 10),
  );

  Future<MidiAppleMidiSession> start(
    String name, {
    MidiNetworkAccess? access,
    MidiAppleMidiSettings settings = fast,
    int port = 0,
  }) async {
    final session = MidiAppleMidiSession(
      localName: name,
      requestedPort: port,
      address: InternetAddress.loopbackIPv4,
      access: access,
      settings: settings,
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
    MidiAppleMidiSession session, {
    String address = '127.0.0.1',
    int? port,
  }) => MidiNetworkHostInfo(
    name: session.localName,
    address: address,
    port: port ?? session.port,
  );

  Future<void> eventually(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('The condition did not become true in $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  List<MidiNetworkReceived> collect(MidiAppleMidiSession session) {
    final received = <MidiNetworkReceived>[];
    session.received.listen(received.add);
    return received;
  }

  String hexOf(MidiNetworkReceived received) =>
      (received.packet as MidiBytesPacket).bytes.toHex();

  MidiBytesPacket bytes(List<int> data) =>
      MidiBytesPacket(bytes: MidiBytes(data), time: clock.now());

  Future<RawDatagramSocket> openSocket() async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    sockets.add(socket);
    return socket;
  }

  group('MidiAppleMidiSession', () {
    group('open(), close()', () {
      test('bind adjacent control and data ports', () async {
        final session = MidiAppleMidiSession(
          localName: 'S',
          requestedPort: 0,
          address: InternetAddress.loopbackIPv4,
        );
        sessions.add(session);
        expect(session.isOpen, isFalse);
        expect((session.port, session.dataPort), (0, 0));
        await session.open();
        await session.open();
        expect(session.isOpen, isTrue);
        expect(session.dataPort, session.port + 1);
        await session.close();
        await session.close();
        expect(session.isOpen, isFalse);
        expect(session.port, 0);
      });

      test('bind the requested port and fail when it is taken', () async {
        final probe = await midiBindAdjacent(
          address: InternetAddress.loopbackIPv4,
          count: 2,
        );
        final port = probe.first.port;
        for (final socket in probe) {
          socket.close();
        }
        final session = await retryBind(() => start('S', port: port));
        expect(session.port, port);
        expect(session.requestedPort, port);
        await expectLater(
          start('T', port: port),
          throwsA(isA<SocketException>()),
        );
      });

      test('say bye to every peer', () async {
        final responder = await start('Responder');
        final initiator = await start('Initiator');
        final connection = await initiator.connect(hostOf(responder));
        await responder.close();
        await eventually(
          () => connection.state == MidiNetworkConnectionState.disconnected,
        );
        expect(connection.endReason, 'the peer ended the session');
      });
    });

    group('connect(host)', () {
      test('carries MIDI in both directions', () async {
        final responder = await start('Responder');
        final initiator = await start('Initiator');
        final atResponder = collect(responder);
        final atInitiator = collect(initiator);
        final connection = await initiator.connect(hostOf(responder));
        expect(connection.state, MidiNetworkConnectionState.connected);
        expect(connection.remoteName, 'Responder');
        expect(initiator.connections, equals([connection]));
        await eventually(() => responder.connections.isNotEmpty);
        final incoming = responder.connections.single;
        expect(incoming.remoteName, 'Initiator');
        expect(incoming.isIncoming, isTrue);
        final sysEx = [0xF0, for (var i = 0; i < 3000; i++) i % 128, 0xF7];
        await connection.send(bytes([0x90, 60, 100]));
        await connection.send(bytes(sysEx));
        await incoming.send(bytes([0xB0, 7, 127]));
        await eventually(
          () => atResponder.length == 2 && atInitiator.length == 1,
        );
        expect(hexOf(atResponder.first), '90 3c 64');
        expect(
          (atResponder.last.packet as MidiBytesPacket).bytes,
          MidiBytes(sysEx),
        );
        expect(hexOf(atInitiator.single), 'b0 07 7f');
        expect(
          identical(await initiator.connect(hostOf(responder)), connection),
          isTrue,
        );
      });

      test('maps the times of the peer to the package clock', () async {
        final responder = await start('Responder');
        final initiator = await start('Initiator');
        final atResponder = collect(responder);
        final connection = await initiator.connect(hostOf(responder));
        await eventually(
          () =>
              connection.clockSync.sampleCount >= 5 &&
              responder.connections.isNotEmpty &&
              responder.connections.single.clockSync.sampleCount >= 5,
        );
        final sentTimes = <MidiTime>[];
        for (var i = 0; i < 20; i++) {
          final packet = bytes([0x90, 60 + i, 100]);
          sentTimes.add(packet.time);
          await connection.send(packet);
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        await eventually(() => atResponder.length == 20);
        final errors = [
          for (var i = 0; i < 20; i++)
            atResponder[i].packet.time.difference(sentTimes[i]).inMicroseconds,
        ];
        expect(errors.map((e) => e.abs()).reduce(max), lessThan(1000));
        final incoming = responder.connections.single;
        final sum = connection.clockSync.offset! + incoming.clockSync.offset!;
        expect(sum.inMicroseconds.abs(), lessThan(1000));
        expect(connection.info.clockOffset, connection.clockSync.offset);
      });

      test('resolves host names', () async {
        final responder = await start('Responder');
        final initiator = await start('Initiator');
        final connection = await initiator.connect(
          hostOf(responder, address: 'localhost'),
        );
        expect(connection.state, MidiNetworkConnectionState.connected);
        await initiator.disconnect(hostOf(responder, address: 'localhost'));
        expect(connection.state, MidiNetworkConnectionState.disconnected);
      });

      test('throws while the session is closed', () async {
        await expectLater(
          MidiAppleMidiSession(localName: 'Closed').connect(
            const MidiNetworkHostInfo(name: 'H', address: '127.0.0.1', port: 1),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'The session Closed is closed',
            ),
          ),
        );
      });

      test('fails when nobody answers', () async {
        final silent = await midiBindAdjacent(
          address: InternetAddress.loopbackIPv4,
          count: 2,
        );
        sockets.addAll(silent);
        final initiator = await start('Initiator');
        final connection = await initiator.connect(
          MidiNetworkHostInfo(
            name: 'Nobody',
            address: '127.0.0.1',
            port: silent.first.port,
          ),
        );
        expect(connection.state, MidiNetworkConnectionState.failed);
        expect(initiator.connections, isEmpty);
      });
    });

    group('access', () {
      test('rejects peers outside the allowed list', () async {
        final responder = await start(
          'Responder',
          access: MidiNetworkAccess(
            policy: MidiNetworkConnectionPolicy.specificPeers,
            allowedPeers: {'Friend'},
          ),
        );
        final stranger = await (await start(
          'Stranger',
        )).connect(hostOf(responder));
        expect(stranger.state, MidiNetworkConnectionState.failed);
        expect(stranger.endReason, 'the peer rejected the invitation');
        final friend = await (await start('Friend')).connect(hostOf(responder));
        expect(friend.state, MidiNetworkConnectionState.connected);
        expect(responder.connections.length, 1);
      });
    });

    group('disconnect(host)', () {
      test('ends connections of both roles', () async {
        final responder = await start('Responder');
        final initiator = await start('Initiator');
        final outgoing = await initiator.connect(hostOf(responder));
        await eventually(() => responder.connections.isNotEmpty);
        final incoming = responder.connections.single;
        await responder.disconnect(incoming.host);
        expect(incoming.state, MidiNetworkConnectionState.disconnected);
        await eventually(
          () => outgoing.state == MidiNetworkConnectionState.disconnected,
        );
        final again = await initiator.connect(hostOf(responder));
        await initiator.disconnect(hostOf(responder));
        expect(again.state, MidiNetworkConnectionState.disconnected);
        expect(initiator.connections, isEmpty);
        await initiator.disconnect(
          const MidiNetworkHostInfo(
            name: 'Unknown',
            address: 'example.invalid',
            port: 1,
          ),
        );
      });
    });

    group('datagrams', () {
      test('ignore what is no session command and adopt data ports', () async {
        final responder = await start('Responder');
        final control = await openSocket();
        final data = await openSocket();
        final answers = <(int, MidiAppleMidiCommand)>[];
        for (final socket in [control, data]) {
          socket.listen((event) {
            final datagram = event == RawSocketEvent.read
                ? socket.receive()
                : null;
            if (datagram != null) {
              answers.add((
                socket.port,
                MidiAppleMidiCommand.decode(datagram.data),
              ));
            }
          });
        }
        void send(RawDatagramSocket from, List<int> datagram, int port) =>
            from.send(datagram, InternetAddress.loopbackIPv4, port);
        const invitation = MidiAppleMidiInvitation(
          token: 9,
          ssrc: 0x77,
          name: 'Raw',
        );
        send(control, [0x80, 0x61, 0, 1], responder.port);
        send(control, [0xFF, 0xFF, 0x58, 0x58], responder.port);
        send(
          control,
          const MidiAppleMidiEndSession(token: 9, ssrc: 1).encode(),
          responder.port,
        );
        send(data, [0x80, 0x61, 0, 1], responder.dataPort);
        send(data, [0xFF, 0xFF, 0x58, 0x58], responder.dataPort);
        send(control, invitation.encode(), responder.port);
        await eventually(() => answers.isNotEmpty);
        send(
          data,
          const MidiAppleMidiInvitation(token: 9, ssrc: 0x55).encode(),
          responder.dataPort,
        );
        send(data, invitation.encode(), responder.dataPort);
        send(
          data,
          MidiAppleMidiSync(
            ssrc: 0x77,
            count: 0,
            timestamps: const [5, 0, 0],
          ).encode(),
          responder.dataPort,
        );
        await eventually(() => answers.length >= 3);
        expect(
          [for (final (port, command) in answers) (port, command.runtimeType)],
          equals([
            (control.port, MidiAppleMidiInvitationAccepted),
            (data.port, MidiAppleMidiInvitationAccepted),
            (data.port, MidiAppleMidiSync),
          ]),
        );
        expect(
          responder.connections.single.state,
          MidiNetworkConnectionState.connected,
        );
      });
    });

    group('under failures', () {
      test('times out and invites again', () async {
        const settings = MidiAppleMidiSettings(
          invitationInterval: Duration(milliseconds: 50),
          maxInvitationInterval: Duration(milliseconds: 100),
          invitationAttempts: 4,
          initialSyncInterval: Duration(milliseconds: 30),
          syncInterval: Duration(milliseconds: 100),
          sessionTimeout: Duration(milliseconds: 500),
          reconnectInterval: Duration(milliseconds: 300),
        );
        final responder = await start('Responder', settings: settings);
        final initiator = await start('Initiator', settings: settings);
        final proxy = await MidiLossyUdpProxy.start(
          target: InternetAddress.loopbackIPv4,
          targetPort: responder.port,
          portCount: 2,
        );
        proxies.add(proxy);
        final connection = await initiator.connect(
          hostOf(responder, port: proxy.port),
        );
        await eventually(() => responder.connections.isNotEmpty);
        final first = responder.connections.single;
        proxy.blocked = true;
        await eventually(
          () =>
              connection.isReconnecting &&
              first.state == MidiNetworkConnectionState.failed,
        );
        expect(responder.connections, isEmpty);
        proxy.blocked = false;
        await eventually(
          () =>
              connection.state == MidiNetworkConnectionState.connected &&
              responder.connections.isNotEmpty,
        );
        expect(identical(responder.connections.single, first), isFalse);
        final replaced = await initiator.connect(
          hostOf(responder, port: proxy.port),
        );
        expect(identical(replaced, connection), isTrue);
      });

      test('replaces a connection that waits to reconnect', () async {
        final responder = await start('Responder');
        final initiator = await start('Initiator');
        final proxy = await MidiLossyUdpProxy.start(
          target: InternetAddress.loopbackIPv4,
          targetPort: responder.port,
          portCount: 2,
        );
        proxies.add(proxy);
        final host = hostOf(responder, port: proxy.port);
        final first = await initiator.connect(host);
        proxy.blocked = true;
        await eventually(() => first.isReconnecting);
        proxy.blocked = false;
        final second = await initiator.connect(host);
        expect(identical(second, first), isFalse);
        expect(second.state, MidiNetworkConnectionState.connected);
        expect(first.state, MidiNetworkConnectionState.disconnected);
      });

      test('repairs losses with the recovery journal', () async {
        const settings = MidiAppleMidiSettings(
          initialSyncInterval: Duration(milliseconds: 30),
          syncInterval: Duration(milliseconds: 200),
          missedSyncLimit: 20,
          sessionTimeout: Duration(seconds: 10),
          feedbackInterval: Duration(milliseconds: 20),
        );
        final responder = await start('Responder', settings: settings);
        final initiator = await start('Initiator', settings: settings);
        final atResponder = collect(responder);
        final losses = <MidiNetworkLoss>[];
        responder.losses.listen(losses.add);
        final proxy = await MidiLossyUdpProxy.start(
          target: InternetAddress.loopbackIPv4,
          targetPort: responder.port,
          portCount: 2,
          seed: 11,
        );
        proxies.add(proxy);
        final connection = await initiator.connect(
          hostOf(responder, port: proxy.port),
        );
        proxy.impairment = const MidiNetworkImpairment(
          loss: 0.1,
          burstStart: 0.04,
          burstEnd: 0.4,
          reorder: 0.05,
          reorderDelay: Duration(milliseconds: 3),
          duplicate: 0.03,
        );
        final random = Random(5);
        final sounding = <int>{};
        final controllers = <int, int>{};
        for (var i = 0; i < 400; i++) {
          final choice = random.nextInt(3);
          if (choice == 0 || sounding.isEmpty) {
            final note = 40 + random.nextInt(40);
            sounding.add(note);
            await connection.send(bytes([0x90, note, 100]));
          } else if (choice == 1) {
            final note = sounding.elementAt(random.nextInt(sounding.length));
            sounding.remove(note);
            await connection.send(bytes([0x80, note, 64]));
          } else {
            final controller = 1 + random.nextInt(10);
            final value = random.nextInt(128);
            controllers[controller] = value;
            await connection.send(bytes([0xB0, controller, value]));
          }
          if (i % 4 == 3) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        }
        proxy.impairment = MidiNetworkImpairment.none;
        bool converged() {
          final notes = <int>{};
          final values = <int, int>{};
          for (final received in atResponder) {
            final data = (received.packet as MidiBytesPacket).bytes;
            final status = data[0] & 0xF0;
            if (status == 0x90 && data[2] > 0) {
              notes.add(data[1]);
            } else if (status == 0x80 || status == 0x90) {
              notes.remove(data[1]);
            } else if (status == 0xB0) {
              values[data[1]] = data[2];
            }
          }
          return notes.length == sounding.length &&
              notes.containsAll(sounding) &&
              controllers.entries.every((e) => values[e.key] == e.value);
        }

        await eventually(converged);
        final stats = responder.connections.single.lossStats;
        expect(proxy.dropped, greaterThan(10));
        expect(stats.packetsLost, greaterThan(0));
        expect(stats.journalRepairs, greaterThan(0));
        expect(losses, isNotEmpty);
        expect(losses.first.connection, same(responder.connections.single));
      });
    });

    group('fields', () {
      test('describe the session', () {
        final session = MidiAppleMidiSession(localName: 'Desk');
        expect(session.protocol, MidiNetworkProtocol.appleMidi);
        expect(session.requestedPort, MidiAppleMidiSession.defaultPort);
        expect(MidiAppleMidiSession.defaultPort, 5004);
        expect(MidiAppleMidiSession.serviceType, '_apple-midi._udp');
        expect(session.address, InternetAddress.anyIPv4);
        expect(session.access, MidiNetworkAccess());
        expect(session.settings.syncInterval, const Duration(seconds: 10));
        expect(session.ssrc, inInclusiveRange(0, 0xFFFFFFFF));
        expect(session.connections, isEmpty);
        expect(session.connectionChanges, isA<Stream<MidiNetworkConnection>>());
      });
    });
  });
}
