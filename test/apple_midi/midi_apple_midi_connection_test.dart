// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

typedef _Datagram = ({Uint8List data, bool toDataPort, bool toResponder});

void main() {
  late MidiFakeClock clock;
  late MidiFakeTimers timers;
  late MidiNetworkSessionEvents events;
  late List<MidiNetworkReceived> packets;
  late List<MidiNetworkLoss> losses;
  late List<_Datagram> wire;
  bool Function(_Datagram datagram)? drop;

  setUp(() {
    clock = MidiFakeClock();
    timers = MidiFakeTimers(clock: clock);
    events = MidiNetworkSessionEvents();
    packets = [];
    losses = [];
    wire = [];
    drop = null;
    events.received.listen(packets.add);
    events.losses.listen(losses.add);
  });

  const responderHost = MidiNetworkHostInfo(
    name: 'Responder host',
    address: '10.0.0.2',
    port: 5004,
  );
  const initiatorHost = MidiNetworkHostInfo(
    name: 'Initiator host',
    address: '10.0.0.1',
    port: 5004,
  );

  ({MidiAppleMidiConnection initiator, MidiAppleMidiConnection responder})
  pair({
    MidiAppleMidiSettings settings = const MidiAppleMidiSettings(),
    MidiAppleMidiSettings? responderSettings,
  }) {
    late final MidiAppleMidiConnection initiator;
    late final MidiAppleMidiConnection responder;
    void link(Uint8List data, bool toDataPort, bool toResponder) {
      final datagram = (
        data: data,
        toDataPort: toDataPort,
        toResponder: toResponder,
      );
      wire.add(datagram);
      if (drop?.call(datagram) ?? false) {
        return;
      }
      final target = toResponder ? responder : initiator;
      if (MidiAppleMidiCommand.isCommand(data)) {
        target.handleCommand(
          MidiAppleMidiCommand.decode(data),
          onDataPort: toDataPort,
        );
      } else {
        target.handleRtp(data);
      }
    }

    initiator = MidiAppleMidiConnection(
      host: responderHost,
      isIncoming: false,
      localName: 'Initiator',
      localSsrc: 0x11111111,
      transmit: (data, {required toDataPort}) => link(data, toDataPort, true),
      listener: events,
      settings: settings,
      clock: clock,
      timerFactory: timers.create,
      random: Random(1),
    );
    responder = MidiAppleMidiConnection(
      host: initiatorHost,
      isIncoming: true,
      localName: 'Responder',
      localSsrc: 0x22222222,
      transmit: (data, {required toDataPort}) => link(data, toDataPort, false),
      listener: events,
      settings: responderSettings ?? settings,
      clock: clock,
      timerFactory: timers.create,
      random: Random(2),
    );
    return (initiator: initiator, responder: responder);
  }

  MidiAppleMidiConnection single({
    required List<_Datagram> outbox,
    bool incoming = false,
    MidiAppleMidiSettings settings = const MidiAppleMidiSettings(),
  }) => MidiAppleMidiConnection(
    host: incoming ? initiatorHost : responderHost,
    isIncoming: incoming,
    localName: incoming ? 'Responder' : 'Initiator',
    localSsrc: incoming ? 0x22222222 : 0x11111111,
    transmit: (data, {required toDataPort}) => outbox.add((
      data: data,
      toDataPort: toDataPort,
      toResponder: !incoming,
    )),
    listener: events,
    settings: settings,
    clock: clock,
    timerFactory: timers.create,
    random: Random(3),
  );

  List<MidiAppleMidiCommand> commandsOf(Iterable<_Datagram> datagrams) => [
    for (final d in datagrams)
      if (MidiAppleMidiCommand.isCommand(d.data))
        MidiAppleMidiCommand.decode(d.data),
  ];

  List<T> sent<T extends MidiAppleMidiCommand>(Iterable<_Datagram> datagrams) =>
      commandsOf(datagrams).whereType<T>().toList();

  int rtpCount(Iterable<_Datagram> datagrams) =>
      datagrams.where((d) => !MidiAppleMidiCommand.isCommand(d.data)).length;

  List<String> bytesAt(MidiNetworkConnection connection) => [
    for (final received in packets)
      if (identical(received.connection, connection))
        (received.packet as MidiBytesPacket).bytes.toHex(),
  ];

  MidiBytesPacket bytes(String hex, {MidiTime? time}) =>
      MidiBytesPacket(bytes: MidiBytes.fromHex(hex), time: time ?? clock.now());

  Future<
    ({MidiAppleMidiConnection initiator, MidiAppleMidiConnection responder})
  >
  connected({
    MidiAppleMidiSettings settings = const MidiAppleMidiSettings(),
    MidiAppleMidiSettings? responderSettings,
  }) async {
    final p = pair(settings: settings, responderSettings: responderSettings);
    await p.initiator.invite();
    return p;
  }

  group('MidiAppleMidiConnection', () {
    group('invite()', () {
      test('invites both ports and synchronises the clocks', () async {
        final p = await connected();
        expect(p.initiator.state, MidiNetworkConnectionState.connected);
        expect(p.responder.state, MidiNetworkConnectionState.connected);
        expect(p.initiator.remoteName, 'Responder');
        expect(p.responder.remoteName, 'Initiator');
        expect(p.initiator.remoteSsrc, 0x22222222);
        expect(p.responder.remoteSsrc, 0x11111111);
        expect(
          wire
              .where((d) => MidiAppleMidiCommand.isCommand(d.data))
              .map(
                (d) => (
                  MidiAppleMidiCommand.decode(d.data).runtimeType,
                  d.toDataPort,
                  d.toResponder,
                ),
              ),
          equals([
            (MidiAppleMidiInvitation, false, true),
            (MidiAppleMidiInvitationAccepted, false, false),
            (MidiAppleMidiInvitation, true, true),
            (MidiAppleMidiInvitationAccepted, true, false),
            (MidiAppleMidiSync, true, true),
            (MidiAppleMidiSync, true, false),
            (MidiAppleMidiSync, true, true),
          ]),
        );
        expect(p.initiator.clockSync.sampleCount, 1);
        expect(p.responder.clockSync.sampleCount, 1);
        expect(p.initiator.clockSync.offset, -p.responder.clockSync.offset!);
        expect(
          p.initiator.info,
          MidiNetworkConnectionInfo(
            host: responderHost,
            state: MidiNetworkConnectionState.connected,
            clockOffset: p.initiator.clockSync.offset,
            roundTrip: Duration.zero,
          ),
        );
        expect(p.initiator.endReason, isNull);
        expect(p.initiator.isReconnecting, isFalse);
      });

      test('waits longer between invitations and gives up', () async {
        final outbox = <_Datagram>[];
        final initiator = single(outbox: outbox);
        final times = <int>[];
        var done = false;
        unawaited(initiator.invite().then((_) => done = true));
        for (var i = 0; i < 4100; i++) {
          if (sent<MidiAppleMidiInvitation>(outbox).length > times.length) {
            times.add(clock.now().microseconds ~/ 1000);
          }
          timers.advance(const Duration(milliseconds: 10));
        }
        await Future<void>.delayed(Duration.zero);
        expect(
          times,
          equals([
            0,
            1000,
            2500,
            4750,
            8130,
            12130,
            16130,
            20130,
            24130,
            28130,
            32130,
            36130,
          ]),
        );
        expect(done, isTrue);
        expect(initiator.state, MidiNetworkConnectionState.failed);
        expect(initiator.endReason, 'the peer did not answer the invitation');
      });

      test('repeats the invitation of the data port', () async {
        final p = pair();
        var dropped = false;
        drop = (d) {
          if (!dropped && d.toDataPort && d.toResponder) {
            dropped = true;
            return true;
          }
          return false;
        };
        final invitation = p.initiator.invite();
        expect(p.initiator.state, MidiNetworkConnectionState.inviting);
        timers.advance(const Duration(seconds: 1));
        await invitation;
        expect(p.initiator.state, MidiNetworkConnectionState.connected);
        expect(
          sent<MidiAppleMidiInvitation>(wire.where((d) => d.toDataPort)),
          hasLength(2),
        );
      });

      test('fails on rejection and ends of the invitation', () {
        for (final answer in ['NO', 'BY']) {
          final outbox = <_Datagram>[];
          final initiator = single(outbox: outbox);
          unawaited(initiator.invite());
          final token = sent<MidiAppleMidiInvitation>(outbox).single.token;
          initiator.handleCommand(
            const MidiAppleMidiInvitationRejected(token: 1, ssrc: 2),
            onDataPort: false,
          );
          expect(initiator.state, MidiNetworkConnectionState.inviting);
          initiator.handleCommand(
            answer == 'NO'
                ? MidiAppleMidiInvitationRejected(token: token, ssrc: 2)
                : MidiAppleMidiEndSession(token: token, ssrc: 2),
            onDataPort: false,
          );
          expect(initiator.state, MidiNetworkConnectionState.failed);
          expect(
            initiator.endReason,
            answer == 'NO'
                ? 'the peer rejected the invitation'
                : 'the peer ended the invitation',
          );
        }
      });

      test('ignores answers with other tokens or ports', () {
        final outbox = <_Datagram>[];
        final initiator = single(outbox: outbox);
        unawaited(initiator.invite());
        final token = sent<MidiAppleMidiInvitation>(outbox).single.token;
        initiator
          ..handleCommand(
            MidiAppleMidiInvitationAccepted(token: token + 1, ssrc: 2),
            onDataPort: false,
          )
          ..handleCommand(
            MidiAppleMidiInvitationAccepted(token: token, ssrc: 2),
            onDataPort: true,
          );
        expect(outbox.length, 1);
        initiator.handleCommand(
          MidiAppleMidiInvitationAccepted(token: token, ssrc: 2),
          onDataPort: false,
        );
        expect(outbox.length, 2);
        expect(outbox.last.toDataPort, isTrue);
        expect(initiator.remoteName, 'Responder host');
      });

      test('starts over after a failure', () async {
        final p = pair(
          settings: const MidiAppleMidiSettings(invitationAttempts: 1),
        );
        drop = (d) => true;
        final first = p.initiator.invite();
        timers.advance(const Duration(seconds: 1));
        await first;
        expect(p.initiator.state, MidiNetworkConnectionState.failed);
        drop = null;
        await p.initiator.invite();
        expect(p.initiator.state, MidiNetworkConnectionState.connected);
      });
    });

    group('responding', () {
      test('answers repeated and unknown invitations', () {
        final outbox = <_Datagram>[];
        final responder = single(outbox: outbox, incoming: true);
        const invitation = MidiAppleMidiInvitation(
          token: 7,
          ssrc: 0x11111111,
          name: 'Initiator',
        );
        responder
          ..handleCommand(invitation, onDataPort: false)
          ..handleCommand(invitation, onDataPort: false)
          ..handleCommand(
            const MidiAppleMidiInvitation(token: 8, ssrc: 0x11111111),
            onDataPort: true,
          );
        expect(responder.state, MidiNetworkConnectionState.inviting);
        responder
          ..handleCommand(invitation, onDataPort: true)
          ..handleCommand(invitation, onDataPort: true);
        expect(responder.state, MidiNetworkConnectionState.connected);
        expect(
          commandsOf(outbox).map(
            (c) => (
              c.runtimeType,
              c is MidiAppleMidiSessionCommand ? c.token : null,
            ),
          ),
          equals([
            (MidiAppleMidiInvitationAccepted, 7),
            (MidiAppleMidiInvitationAccepted, 7),
            (MidiAppleMidiInvitationRejected, 8),
            (MidiAppleMidiInvitationAccepted, 7),
            (MidiAppleMidiInvitationAccepted, 7),
          ]),
        );
        expect(
          outbox.map((d) => d.toDataPort),
          equals([false, false, true, true, true]),
        );
      });

      test('gives up when the data port is not invited', () {
        final outbox = <_Datagram>[];
        final responder = single(outbox: outbox, incoming: true)
          ..handleCommand(
            const MidiAppleMidiInvitation(token: 7, ssrc: 1),
            onDataPort: false,
          );
        timers.advance(const Duration(seconds: 75));
        expect(responder.state, MidiNetworkConnectionState.failed);
        expect(responder.endReason, 'the peer did not invite the data port');
      });

      test('starts a new session when the peer invites anew', () async {
        final p = await connected();
        await p.initiator.send(bytes('90 3c 64'));
        p.responder.handleCommand(
          const MidiAppleMidiInvitation(
            token: 99,
            ssrc: 0x11111111,
            name: 'Again',
          ),
          onDataPort: false,
        );
        expect(p.responder.state, MidiNetworkConnectionState.inviting);
        expect(bytesAt(p.responder).last, '80 3c 40');
        p.responder.handleCommand(
          const MidiAppleMidiInvitation(token: 99, ssrc: 0x11111111),
          onDataPort: true,
        );
        expect(p.responder.state, MidiNetworkConnectionState.connected);
        expect(p.responder.remoteName, 'Again');
        expect(p.responder.lossStats.packetsReceived, 1);
      });

      test('rejects invitations as initiator', () async {
        final p = await connected();
        p.initiator.handleCommand(
          const MidiAppleMidiInvitation(token: 5, ssrc: 0x22222222),
          onDataPort: true,
        );
        expect(
          commandsOf([wire.last]),
          equals([
            const MidiAppleMidiInvitationRejected(
              token: 5,
              ssrc: 0x11111111,
              name: 'Initiator',
            ),
          ]),
        );
        expect(wire.last.toDataPort, isTrue);
      });
    });

    group('send(packet)', () {
      test('carries MIDI with its time', () async {
        final p = await connected();
        clock.advance(const Duration(milliseconds: 3));
        final time = clock.now();
        await p.initiator.send(bytes('90 3c 64 f0 01 02 03 f7', time: time));
        await p.responder.send(bytes('b0 07 7f'));
        expect(bytesAt(p.responder), equals(['90 3c 64', 'f0 01 02 03 f7']));
        expect(bytesAt(p.initiator), equals(['b0 07 7f']));
        expect([
          for (final r in packets) r.packet.time,
        ], equals([time, time, time]));
        expect(
          p.responder.lossStats,
          const MidiNetworkLossStats(packetsReceived: 1),
        );
      });

      test('maps times across the wrap of the RTP timestamp', () async {
        const settings = MidiAppleMidiSettings(initialTimestamp: 0xFFFFFFF0);
        final p = await connected(settings: settings);
        expect(p.initiator.sessionTime, 0xFFFFFFF0);
        clock.advance(const Duration(milliseconds: 1));
        final before = clock.now();
        await p.initiator.send(bytes('90 3c 64'));
        clock.advance(const Duration(milliseconds: 2));
        final after = clock.now();
        await p.initiator.send(bytes('80 3c 40'));
        expect(p.initiator.sessionTime, 0x10000000E);
        expect([
          for (final r in packets) r.packet.time,
        ], equals([before, after]));
      });

      test(
        'uses the arrival time before the clocks are synchronised',
        () async {
          drop = (d) =>
              MidiAppleMidiCommand.isCommand(d.data) &&
              MidiAppleMidiCommand.decode(d.data) is MidiAppleMidiSync;
          final p = await connected();
          expect(p.responder.clockSync.isSynchronized, isFalse);
          final sentAt = clock.now();
          clock.advance(const Duration(milliseconds: 5));
          await p.initiator.send(bytes('90 3c 64', time: sentAt));
          expect(packets.single.packet.time, clock.now());
        },
      );

      test('never reports a time in the future', () async {
        final p = await connected();
        await p.initiator.send(
          bytes('90 3c 64', time: clock.now() + const Duration(seconds: 1)),
        );
        expect(packets.single.packet.time, clock.now());
      });

      test('sends nothing for an incomplete message', () async {
        final p = await connected();
        final before = wire.length;
        await p.initiator.send(bytes('f0 01'));
        expect(wire.length, before);
      });

      test('refuses UMP and closed connections', () async {
        final p = pair();
        await expectLater(
          p.initiator.send(bytes('90 3c 64')),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'The connection to Responder host is not established',
            ),
          ),
        );
        await expectLater(
          p.initiator.send(
            MidiUmpPacket(words: const [0], time: MidiTime.zero),
          ),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('handleRtp(packet)', () {
      test('ignores foreign and short packets', () async {
        final p = await connected();
        await p.initiator.send(bytes('90 3c 64'));
        final rtp = wire
            .lastWhere((d) => !MidiAppleMidiCommand.isCommand(d.data))
            .data;
        final foreign = Uint8List.fromList(rtp)..[8] = 0x33;
        p.responder
          ..handleRtp(foreign)
          ..handleRtp(Uint8List(8));
        single(outbox: [], incoming: true).handleRtp(rtp);
        expect(bytesAt(p.responder), equals(['90 3c 64']));
      });

      test('repairs a lost packet from the journal', () async {
        final p = await connected();
        await p.initiator.send(bytes('90 3c 64'));
        drop = (d) => !MidiAppleMidiCommand.isCommand(d.data);
        await p.initiator.send(bytes('80 3c 40'));
        drop = null;
        await p.initiator.send(bytes('90 3e 64'));
        expect(
          bytesAt(p.responder),
          equals(['90 3c 64', '80 3c 40', '90 3e 64']),
        );
        expect(losses.single.count, 1);
        expect(losses.single.cause, contains('recovered from the journal'));
        final stats = p.responder.lossStats;
        expect(stats.packetsLost, 1);
        expect(stats.packetsRecovered, 1);
        expect(stats.journalRepairs, greaterThan(0));
      });
    });

    group('guards and feedback', () {
      test('guard packets repair a lost last packet', () async {
        final p = await connected();
        await p.initiator.send(bytes('90 3c 64'));
        drop = (d) => !MidiAppleMidiCommand.isCommand(d.data);
        await p.initiator.send(bytes('80 3c 40'));
        drop = null;
        expect(bytesAt(p.responder), equals(['90 3c 64']));
        timers.advance(const Duration(milliseconds: 20));
        expect(bytesAt(p.responder), equals(['90 3c 64', '80 3c 40']));
        timers.advance(const Duration(milliseconds: 600));
        expect(rtpCount(wire), 5);
      });

      test('feedback acknowledges the data and stops the guards', () async {
        final p = await connected(
          settings: const MidiAppleMidiSettings(
            feedbackInterval: Duration(milliseconds: 10),
          ),
        );
        await p.initiator.send(bytes('90 3c 64'));
        timers.advance(const Duration(milliseconds: 10));
        final feedback = sent<MidiAppleMidiReceiverFeedback>(
          wire.where((d) => !d.toResponder),
        );
        expect(feedback.length, 1);
        expect(feedback.single.ssrc, 0x22222222);
        timers.advance(const Duration(seconds: 1));
        expect(rtpCount(wire), 1);
        expect(
          sent<MidiAppleMidiReceiverFeedback>(
            wire.where((d) => !d.toResponder),
          ).length,
          1,
        );
        p.initiator.handleCommand(
          const MidiAppleMidiReceiverFeedback(ssrc: 0x99, sequenceNumber: 0),
          onDataPort: false,
        );
      });

      test('keeps the bit rate limit of the peer', () async {
        final p = await connected();
        expect(p.initiator.bitrateLimit, isNull);
        p.initiator.handleCommand(
          const MidiAppleMidiBitrateLimit(ssrc: 0x22222222, limit: 31250),
          onDataPort: false,
        );
        expect(p.initiator.bitrateLimit, 31250);
      });
    });

    group('clock synchronisation', () {
      test('repeats often at the start and seldom later', () async {
        final p = await connected(
          settings: const MidiAppleMidiSettings(
            initialSyncCount: 3,
            initialSyncInterval: Duration(milliseconds: 100),
            syncInterval: Duration(seconds: 1),
          ),
        );
        List<MidiAppleMidiSync> starts() => [
          for (final sync in sent<MidiAppleMidiSync>(
            wire.where((d) => d.toResponder),
          ))
            if (sync.count == 0) sync,
        ];
        expect(starts().length, 1);
        timers.advance(const Duration(milliseconds: 200));
        expect(starts().length, 3);
        timers.advance(const Duration(milliseconds: 999));
        expect(starts().length, 3);
        timers.advance(const Duration(milliseconds: 1));
        expect(starts().length, 4);
        expect(p.initiator.clockSync.sampleCount, 4);
      });

      test('ignores unknown replies and syncs outside a session', () async {
        final p = await connected();
        p.initiator.handleCommand(
          MidiAppleMidiSync(
            ssrc: 0x22222222,
            count: 1,
            timestamps: const [1, 2, 0],
          ),
          onDataPort: true,
        );
        p.responder.handleCommand(
          MidiAppleMidiSync(
            ssrc: 0x11111111,
            count: 2,
            timestamps: const [10, 20, 30],
          ),
          onDataPort: true,
        );
        expect(p.initiator.clockSync.sampleCount, 1);
        expect(p.responder.clockSync.sampleCount, 2);
        expect(
          p.responder.clockSync.roundTrip,
          const Duration(milliseconds: 2),
        );
        final idle = single(outbox: []);
        idle.handleCommand(
          MidiAppleMidiSync(ssrc: 1, count: 0, timestamps: const [1, 0, 0]),
          onDataPort: true,
        );
        expect(idle.clockSync.isSynchronized, isFalse);
      });

      test(
        'ends the session after missed synchronisations and reconnects',
        () async {
          final p = await connected(
            settings: const MidiAppleMidiSettings(
              reconnectInterval: Duration(seconds: 2),
            ),
          );
          drop = (d) =>
              !d.toResponder ||
              commandsOf([d]).whereType<MidiAppleMidiEndSession>().isNotEmpty;
          // The synchronisation at 1.5 s goes unanswered; those at 3 s,
          // 4.5 s and 6 s find it missing, the one at 6 s ends the session.
          timers.advance(const Duration(milliseconds: 5999));
          expect(p.initiator.state, MidiNetworkConnectionState.connected);
          timers.advance(const Duration(milliseconds: 1));
          expect(p.initiator.state, MidiNetworkConnectionState.failed);
          expect(
            p.initiator.endReason,
            'the peer stopped answering the clock synchronisation',
          );
          expect(p.initiator.isReconnecting, isTrue);
          expect(p.responder.state, MidiNetworkConnectionState.connected);
          drop = null;
          timers.advance(const Duration(seconds: 2));
          expect(p.initiator.state, MidiNetworkConnectionState.connected);
          expect(p.initiator.isReconnecting, isFalse);
          expect(p.responder.state, MidiNetworkConnectionState.connected);
        },
      );
    });

    group('reconnection', () {
      test(
        'keeps inviting after a lost session until the peer answers',
        () async {
          final p = await connected(
            settings: const MidiAppleMidiSettings(
              reconnectInterval: Duration(seconds: 2),
              invitationAttempts: 2,
            ),
          );
          drop = (d) => true;
          timers.advance(const Duration(seconds: 6));
          expect(p.initiator.isReconnecting, isTrue);
          timers.advance(const Duration(milliseconds: 4500));
          expect(p.initiator.state, MidiNetworkConnectionState.failed);
          expect(p.initiator.isReconnecting, isTrue);
          expect(
            p.initiator.endReason,
            'the peer did not answer the invitation',
          );
          drop = null;
          timers.advance(const Duration(seconds: 2));
          expect(p.initiator.state, MidiNetworkConnectionState.connected);
          expect(p.responder.state, MidiNetworkConnectionState.connected);
        },
      );

      test('ignores the bye of an earlier session while inviting', () {
        final outbox = <_Datagram>[];
        final initiator = single(outbox: outbox);
        unawaited(initiator.invite());
        initiator.handleCommand(
          const MidiAppleMidiEndSession(token: 12345, ssrc: 0x22222222),
          onDataPort: false,
        );
        expect(initiator.state, MidiNetworkConnectionState.inviting);
        initiator.handleCommand(
          const MidiAppleMidiEndSession(token: 0, ssrc: 0x22222222),
          onDataPort: false,
        );
        expect(initiator.state, MidiNetworkConnectionState.failed);
      });

      test('ends a session on a bye with any token', () async {
        final p = await connected();
        p.initiator.handleCommand(
          const MidiAppleMidiEndSession(token: 12345, ssrc: 0x22222222),
          onDataPort: false,
        );
        expect(p.initiator.state, MidiNetworkConnectionState.disconnected);
      });
    });

    group('timeouts', () {
      test('end a silent session without reconnecting', () async {
        final p = await connected(
          settings: const MidiAppleMidiSettings(reconnectInterval: null),
        );
        drop = (d) => true;
        timers.advance(const Duration(seconds: 100));
        expect(p.initiator.state, MidiNetworkConnectionState.failed);
        expect(p.initiator.isReconnecting, isFalse);
        expect(p.responder.state, MidiNetworkConnectionState.failed);
        expect(p.responder.endReason, 'the peer went silent');
        expect(p.responder.isReconnecting, isFalse);
      });
    });

    group('close()', () {
      test('says bye and ends the notes of the peer', () async {
        final p = await connected();
        await p.initiator.send(bytes('90 3c 64'));
        await p.responder.close();
        expect(p.responder.state, MidiNetworkConnectionState.disconnected);
        expect(p.responder.endReason, 'closed by this side');
        expect(bytesAt(p.responder), equals(['90 3c 64', '80 3c 40']));
        expect(p.initiator.state, MidiNetworkConnectionState.disconnected);
        expect(p.initiator.endReason, 'the peer ended the session');
        await p.responder.close();
        p.responder.handleCommand(
          const MidiAppleMidiInvitation(token: 1, ssrc: 1),
          onDataPort: false,
        );
        expect(p.responder.state, MidiNetworkConnectionState.disconnected);
      });

      test('ignores the bye of another participant', () async {
        final p = await connected();
        p.initiator.handleCommand(
          const MidiAppleMidiEndSession(token: 0, ssrc: 0x33),
          onDataPort: false,
        );
        expect(p.initiator.state, MidiNetworkConnectionState.connected);
      });

      test('ends invitations, idle and failed connections', () async {
        final outbox = <_Datagram>[];
        final inviting = single(outbox: outbox);
        unawaited(inviting.invite());
        await inviting.close();
        expect(sent<MidiAppleMidiEndSession>(outbox), hasLength(1));
        expect(inviting.state, MidiNetworkConnectionState.disconnected);
        final idle = single(outbox: outbox);
        await idle.close();
        expect(idle.endReason, 'closed by this side');
        final p = await connected();
        drop = (d) => true;
        timers.advance(const Duration(seconds: 6));
        expect(p.initiator.isReconnecting, isTrue);
        await p.initiator.close();
        expect(p.initiator.isReconnecting, isFalse);
        expect(p.initiator.state, MidiNetworkConnectionState.disconnected);
        expect(
          p.initiator.endReason,
          'the peer stopped answering the clock synchronisation',
        );
        final ended = single(outbox: outbox, incoming: true)
          ..handleCommand(
            const MidiAppleMidiInvitation(token: 1, ssrc: 1),
            onDataPort: false,
          )
          ..handleCommand(
            const MidiAppleMidiEndSession(token: 1, ssrc: 1),
            onDataPort: false,
          );
        expect(ended.state, MidiNetworkConnectionState.disconnected);
      });
    });

    group('fields', () {
      test('keep the configuration', () {
        final connection = MidiAppleMidiConnection(
          host: responderHost,
          isIncoming: false,
          localName: 'Local',
          localSsrc: 5,
          transmit: (_, {required toDataPort}) {},
          listener: events,
        );
        expect(connection.host, responderHost);
        expect(connection.localName, 'Local');
        expect(connection.localSsrc, 5);
        expect(connection.settings.invitationAttempts, 12);
        expect(connection.remoteSsrc, isNull);
        expect(connection.lossStats, const MidiNetworkLossStats());
        expect(connection.state, MidiNetworkConnectionState.inviting);
      });
    });
  });
}
