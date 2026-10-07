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

void main() {
  late MidiFakeClock clock;
  late MidiFakeTimers timers;
  late MidiNetworkSessionEvents events;
  late List<MidiNetworkConnection> changes;
  late List<MidiNetworkReceived> packets;
  late List<MidiNetworkLoss> losses;
  late List<List<MidiNetworkMidi2Command>> toHost;
  late List<List<MidiNetworkMidi2Command>> toClient;
  bool Function(List<MidiNetworkMidi2Command> commands, bool toHost)? drop;

  setUp(() {
    clock = MidiFakeClock();
    timers = MidiFakeTimers(clock: clock);
    events = MidiNetworkSessionEvents();
    changes = [];
    packets = [];
    losses = [];
    toHost = [];
    toClient = [];
    drop = null;
    events.connectionChanges.listen(changes.add);
    events.received.listen(packets.add);
    events.losses.listen(losses.add);
  });

  const peer = MidiNetworkHostInfo(
    name: 'Peer',
    address: '127.0.0.1',
    port: 5507,
    serviceType: MidiNetworkHostInfo.networkMidi2ServiceType,
  );

  const secret = MidiNetworkMidi2SharedSecret('5483');
  const rosa = MidiNetworkMidi2UserCredentials(
    userName: 'Rosa',
    password: 'RPBqBno',
  );

  // Creates a connection whose datagrams land decoded in [outbox].
  MidiNetworkMidi2Connection single({
    required List<List<MidiNetworkMidi2Command>> outbox,
    bool incoming = false,
    MidiNetworkMidi2Credentials? credentials,
    MidiNetworkMidi2SharedSecret? requiredSecret,
    List<MidiNetworkMidi2UserCredentials> requiredUsers = const [],
    MidiNetworkMidi2Settings settings = const MidiNetworkMidi2Settings(),
  }) => MidiNetworkMidi2Connection(
    host: peer,
    isIncoming: incoming,
    localEndpointName: incoming ? 'Host' : 'Client',
    localProductInstanceId: incoming ? 'H1' : 'C1',
    transmit: (datagram) =>
        outbox.add(MidiNetworkMidi2Command.decodePacket(datagram)),
    listener: events,
    credentials: credentials,
    requiredSecret: requiredSecret,
    requiredUsers: requiredUsers,
    settings: settings,
    clock: clock,
    timerFactory: timers.create,
    random: Random(1),
  );

  // Wires a client and a host back to back; [drop] filters datagrams.
  ({MidiNetworkMidi2Connection client, MidiNetworkMidi2Connection host}) pair({
    MidiNetworkMidi2Credentials? credentials,
    MidiNetworkMidi2SharedSecret? requiredSecret,
    List<MidiNetworkMidi2UserCredentials> requiredUsers = const [],
    MidiNetworkMidi2Settings clientSettings = const MidiNetworkMidi2Settings(),
    MidiNetworkMidi2Settings hostSettings = const MidiNetworkMidi2Settings(),
  }) {
    late final MidiNetworkMidi2Connection client;
    late final MidiNetworkMidi2Connection host;
    void link(Uint8List datagram, bool up) {
      final commands = MidiNetworkMidi2Command.decodePacket(datagram);
      (up ? toHost : toClient).add(commands);
      if (!(drop?.call(commands, up) ?? false)) {
        (up ? host : client).handle(commands);
      }
    }

    client = MidiNetworkMidi2Connection(
      host: peer,
      isIncoming: false,
      localEndpointName: 'Client',
      localProductInstanceId: 'C1',
      transmit: (datagram) => link(datagram, true),
      listener: events,
      credentials: credentials,
      settings: clientSettings,
      clock: clock,
      timerFactory: timers.create,
      random: Random(2),
    );
    host = MidiNetworkMidi2Connection(
      host: peer.copyWith(name: 'Client side'),
      isIncoming: true,
      localEndpointName: 'Host',
      localProductInstanceId: 'H1',
      transmit: (datagram) => link(datagram, false),
      listener: events,
      requiredSecret: requiredSecret,
      requiredUsers: requiredUsers,
      settings: hostSettings,
      clock: clock,
      timerFactory: timers.create,
      random: Random(3),
    );
    return (client: client, host: host);
  }

  MidiUmpPacket ump(List<int> words) =>
      MidiUmpPacket(words: words, time: MidiTime.zero);

  List<int> wordsAt(MidiNetworkMidi2Connection connection) => [
    for (final received in packets)
      if (identical(received.connection, connection))
        ...(received.packet as MidiUmpPacket).words,
  ];

  List<T> sentOf<T>(List<List<MidiNetworkMidi2Command>> log) =>
      log.expand((datagram) => datagram).whereType<T>().toList();

  // Note On messages of the MIDI 1.0 protocol in UMP form, one word each.
  int note(int number) => 0x20900064 | (number << 8);

  group('MidiNetworkMidi2Connection', () {
    group('invite()', () {
      test('establishes a session without authentication', () async {
        final p = pair();
        expect(p.client.state, MidiNetworkConnectionState.inviting);
        await p.client.invite();
        expect(p.client.state, MidiNetworkConnectionState.connected);
        expect(p.host.state, MidiNetworkConnectionState.connected);
        expect(p.client.remoteName, 'Host');
        expect(p.client.remoteProductInstanceId, 'H1');
        expect(p.host.remoteName, 'Client');
        expect(p.host.remoteProductInstanceId, 'C1');
        expect(p.client.isIncoming, isFalse);
        expect(p.host.isIncoming, isTrue);
        expect(p.client.endReason, isNull);
        expect(
          sentOf<MidiNetworkMidi2Invitation>(toHost),
          equals([
            const MidiNetworkMidi2Invitation(
              endpointName: 'Client',
              productInstanceId: 'C1',
            ),
          ]),
        );
        expect(
          changes.map((c) => (c.remoteName, c.state)),
          containsAll([
            ('Client', MidiNetworkConnectionState.connected),
            ('Host', MidiNetworkConnectionState.connected),
          ]),
        );
        expect(
          p.client.info,
          MidiNetworkConnectionInfo(
            host: peer,
            state: MidiNetworkConnectionState.connected,
          ),
        );
      });

      test('invites again and gives up without answer', () async {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final client = single(outbox: outbox);
        var done = false;
        unawaited(client.invite().then((_) => done = true));
        timers.advance(const Duration(seconds: 4));
        expect(sentOf<MidiNetworkMidi2Invitation>(outbox).length, 5);
        expect(client.state, MidiNetworkConnectionState.inviting);
        timers.advance(const Duration(seconds: 1));
        await Future<void>.delayed(Duration.zero);
        expect(done, isTrue);
        expect(client.state, MidiNetworkConnectionState.failed);
        expect(client.endReason, 'the host did not answer');
        expect(
          outbox.last,
          equals([
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonInvitationCanceled,
            ),
          ]),
        );
      });

      test('waits after a pending reply', () async {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final client = single(
          outbox: outbox,
          settings: const MidiNetworkMidi2Settings(
            pendingTimeout: Duration(seconds: 30),
          ),
        );
        unawaitedInvite(client);
        const pending = MidiNetworkMidi2InvitationPending(
          endpointName: 'Host',
          productInstanceId: 'H1',
        );
        client.handle([pending]);
        timers.advance(const Duration(seconds: 29));
        expect(sentOf<MidiNetworkMidi2Invitation>(outbox).length, 1);
        client.handle([
          const MidiNetworkMidi2InvitationAccepted(
            endpointName: 'Host',
            productInstanceId: 'H1',
          ),
        ]);
        expect(client.state, MidiNetworkConnectionState.connected);
        client.handle([pending]);
        expect(client.state, MidiNetworkConnectionState.connected);
      });

      test('gives up when a pending host does not decide', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final client = single(outbox: outbox);
        unawaitedInvite(client);
        client.handle([
          const MidiNetworkMidi2InvitationPending(
            endpointName: 'Host',
            productInstanceId: 'H1',
          ),
        ]);
        timers.advance(const Duration(seconds: 120));
        expect(client.state, MidiNetworkConnectionState.failed);
        expect(client.endReason, 'the host did not decide in time');
      });

      test('fails when the host says bye or refuses with a NAK', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final first = single(outbox: outbox);
        unawaitedInvite(first);
        first.handle([
          const MidiNetworkMidi2Bye(
            reason: MidiNetworkMidi2Bye.reasonUserDidNotAccept,
          ),
        ]);
        expect(first.state, MidiNetworkConnectionState.failed);
        expect(first.endReason, 'the peer said bye (reason 66)');
        expect(outbox.last, equals([const MidiNetworkMidi2ByeReply()]));
        final second = single(outbox: outbox);
        unawaitedInvite(second);
        second.handle([
          MidiNetworkMidi2Nak(
            reason: MidiNetworkMidi2Nak.reasonCommandNotSupported,
            originalHeader: const MidiNetworkMidi2Invitation(
              endpointName: 'Client',
              productInstanceId: 'C1',
            ).header,
          ),
        ]);
        expect(second.state, MidiNetworkConnectionState.failed);
        expect(second.endReason, 'the host refused the invitation');
      });

      test('answers a late acceptance with bye', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final client = single(outbox: outbox);
        unawaitedInvite(client);
        timers.advance(const Duration(seconds: 5));
        client.handle([
          const MidiNetworkMidi2InvitationAccepted(
            endpointName: 'Host',
            productInstanceId: 'H1',
          ),
        ]);
        expect(
          outbox.last,
          equals([
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonNoPendingSession,
            ),
          ]),
        );
      });

      test('ignores a bye about an earlier session', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final client = single(outbox: outbox);
        unawaitedInvite(client);
        for (final reason in [
          MidiNetworkMidi2Bye.reasonTimeout,
          MidiNetworkMidi2Bye.reasonSessionNotEstablished,
        ]) {
          client.handle([MidiNetworkMidi2Bye(reason: reason)]);
          expect(client.state, MidiNetworkConnectionState.inviting);
          expect(outbox.last, equals([const MidiNetworkMidi2ByeReply()]));
        }
      });

      test('ignores a second acceptance', () async {
        final p = pair();
        await p.client.invite();
        final sent = toHost.length;
        p.client.handle([
          const MidiNetworkMidi2InvitationAccepted(
            endpointName: 'Other',
            productInstanceId: 'H1',
          ),
        ]);
        expect(toHost.length, sent);
        expect(p.client.remoteName, 'Host');
      });

      test('starts over after a failure', () async {
        final p = pair();
        drop = (commands, up) => true;
        final first = p.client.invite();
        timers.advance(const Duration(seconds: 5));
        await first;
        expect(p.client.state, MidiNetworkConnectionState.failed);
        drop = null;
        await p.client.invite();
        expect(p.client.state, MidiNetworkConnectionState.connected);
      });
    });

    group('authentication', () {
      test('admits a client with the shared secret', () async {
        final p = pair(credentials: secret, requiredSecret: secret);
        await p.client.invite();
        expect(p.client.state, MidiNetworkConnectionState.connected);
        expect(p.host.state, MidiNetworkConnectionState.connected);
        final invitation = sentOf<MidiNetworkMidi2Invitation>(toHost).single;
        expect(
          invitation.capabilities,
          MidiNetworkMidi2Invitation.capabilityAuthentication,
        );
        final challenge = sentOf<MidiNetworkMidi2AuthenticationRequired>(
          toClient,
        ).single;
        expect(
          sentOf<MidiNetworkMidi2InvitationWithAuthentication>(toHost).single,
          MidiNetworkMidi2InvitationWithAuthentication(
            digest: secret.digest(challenge.nonce),
          ),
        );
      });

      test('admits a user with name and password', () async {
        final p = pair(
          credentials: rosa,
          requiredUsers: [
            const MidiNetworkMidi2UserCredentials(
              userName: 'Ann',
              password: 'x',
            ),
            rosa,
          ],
        );
        await p.client.invite();
        expect(p.host.state, MidiNetworkConnectionState.connected);
        expect(
          sentOf<MidiNetworkMidi2Invitation>(toHost).single.capabilities,
          MidiNetworkMidi2Invitation.capabilityUserAuthentication,
        );
        expect(
          sentOf<MidiNetworkMidi2InvitationWithUserAuthentication>(
            toHost,
          ).single.userName,
          'Rosa',
        );
      });

      test('gives up after a wrong secret', () async {
        final p = pair(
          credentials: const MidiNetworkMidi2SharedSecret('wrong'),
          requiredSecret: secret,
        );
        await p.client.invite();
        expect(p.client.state, MidiNetworkConnectionState.failed);
        expect(p.client.endReason, 'the host rejected the credentials');
        expect(p.host.state, MidiNetworkConnectionState.disconnected);
        expect(
          sentOf<MidiNetworkMidi2AuthenticationRequired>(
            toClient,
          ).map((c) => c.authenticationState),
          equals([
            MidiNetworkMidi2AuthenticationRequired.firstRequest,
            MidiNetworkMidi2AuthenticationRequired.incorrectDigest,
          ]),
        );
      });

      test('is refused by a host it cannot satisfy', () async {
        for (final credentials in [null, rosa]) {
          final p = pair(credentials: credentials, requiredSecret: secret);
          await p.client.invite();
          expect(p.client.state, MidiNetworkConnectionState.failed);
          expect(p.client.endReason, 'the peer said bye (reason 69)');
          expect(p.host.endReason, 'the client cannot authenticate');
        }
      });

      test('gives up a challenge it cannot answer', () {
        final challenges = {
          null: MidiNetworkMidi2AuthenticationRequired(
            endpointName: 'Host',
            productInstanceId: 'H1',
            nonce: List.filled(16, 0x41),
          ),
          secret: MidiNetworkMidi2UserAuthenticationRequired(
            endpointName: 'Host',
            productInstanceId: 'H1',
            nonce: List.filled(16, 0x41),
          ),
        };
        for (final MapEntry(key: credentials, value: challenge)
            in challenges.entries) {
          final outbox = <List<MidiNetworkMidi2Command>>[];
          final client = single(outbox: outbox, credentials: credentials);
          unawaitedInvite(client);
          client.handle([challenge]);
          expect(client.state, MidiNetworkConnectionState.failed);
          expect(client.endReason, 'the host requires authentication');
        }
      });

      test('ends the invitation after repeated wrong digests', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final host = single(
          outbox: outbox,
          incoming: true,
          requiredSecret: secret,
          settings: const MidiNetworkMidi2Settings(authenticationAttempts: 2),
        );
        host.handle([
          const MidiNetworkMidi2Invitation(
            endpointName: 'Client',
            productInstanceId: 'C1',
            capabilities: MidiNetworkMidi2Invitation.capabilityAuthentication,
          ),
        ]);
        final wrong = MidiNetworkMidi2InvitationWithAuthentication(
          digest: List.filled(32, 0),
        );
        host.handle([wrong]);
        expect(host.state, MidiNetworkConnectionState.inviting);
        host.handle([wrong]);
        expect(host.state, MidiNetworkConnectionState.failed);
        expect(host.endReason, 'the client failed to authenticate');
        expect(
          outbox.last,
          equals([
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonAuthenticationFailed,
            ),
          ]),
        );
      });

      test('refuses unknown users and other methods', () {
        final cases = {
          MidiNetworkMidi2InvitationWithUserAuthentication(
            digest: List.filled(32, 0),
            userName: 'Bob',
          ): MidiNetworkMidi2Bye.reasonUserNameNotFound,
          MidiNetworkMidi2InvitationWithAuthentication(
            digest: List.filled(32, 0),
          ): MidiNetworkMidi2Bye.reasonNoMatchingAuthenticationMethod,
        };
        for (final MapEntry(key: answer, value: reason) in cases.entries) {
          final outbox = <List<MidiNetworkMidi2Command>>[];
          final host =
              single(outbox: outbox, incoming: true, requiredUsers: [rosa])
                ..handle([
                  const MidiNetworkMidi2Invitation(
                    endpointName: 'Client',
                    productInstanceId: 'C1',
                    capabilities:
                        MidiNetworkMidi2Invitation.capabilityUserAuthentication,
                  ),
                ]);
          expect(
            outbox.last.single,
            isA<MidiNetworkMidi2UserAuthenticationRequired>(),
          );
          host.handle([answer]);
          expect(host.state, MidiNetworkConnectionState.failed);
          expect(outbox.last, equals([MidiNetworkMidi2Bye(reason: reason)]));
        }
        final outbox = <List<MidiNetworkMidi2Command>>[];
        single(outbox: outbox, incoming: true, requiredSecret: secret)
          ..handle([
            const MidiNetworkMidi2Invitation(
              endpointName: 'Client',
              productInstanceId: 'C1',
              capabilities: 3,
            ),
          ])
          ..handle([
            MidiNetworkMidi2InvitationWithUserAuthentication(
              digest: List.filled(32, 0),
              userName: 'Rosa',
            ),
          ]);
        expect(
          outbox.last,
          equals([
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonNoMatchingAuthenticationMethod,
            ),
          ]),
        );
      });

      test('refuses an answer without challenge', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final host = single(outbox: outbox, incoming: true);
        host.handle([
          MidiNetworkMidi2InvitationWithAuthentication(
            digest: List.filled(32, 0),
          ),
        ]);
        expect(host.state, MidiNetworkConnectionState.failed);
        expect(
          outbox.last,
          equals([
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonMissingPriorInvitation,
            ),
          ]),
        );
      });

      test('repeats the challenge for a repeated invitation', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final host = single(
          outbox: outbox,
          incoming: true,
          requiredSecret: secret,
        );
        const invitation = MidiNetworkMidi2Invitation(
          endpointName: 'Client',
          productInstanceId: 'C1',
          capabilities: MidiNetworkMidi2Invitation.capabilityAuthentication,
        );
        host
          ..handle([invitation])
          ..handle([invitation]);
        expect(outbox.length, 2);
        expect(outbox[0], equals(outbox[1]));
      });

      test('ends a challenge the client leaves unanswered', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final host =
            single(
              outbox: outbox,
              incoming: true,
              requiredSecret: secret,
              settings: const MidiNetworkMidi2Settings(
                pendingTimeout: Duration(seconds: 5),
              ),
            )..handle([
              const MidiNetworkMidi2Invitation(
                endpointName: 'Client',
                productInstanceId: 'C1',
                capabilities:
                    MidiNetworkMidi2Invitation.capabilityAuthentication,
              ),
            ]);
        timers.advance(const Duration(seconds: 5));
        expect(host.state, MidiNetworkConnectionState.failed);
        expect(host.endReason, 'the client did not authenticate in time');
      });

      test('sends the answer again until the host replies', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final client = single(outbox: outbox, credentials: secret);
        unawaitedInvite(client);
        client.handle([
          MidiNetworkMidi2AuthenticationRequired(
            endpointName: 'Host',
            productInstanceId: 'H1',
            nonce: List.filled(16, 0x41),
          ),
        ]);
        timers.advance(const Duration(seconds: 1));
        expect(
          sentOf<MidiNetworkMidi2InvitationWithAuthentication>(outbox).length,
          2,
        );
      });

      test('restarts the sequences for a repeated invitation', () async {
        final p = pair();
        await p.client.invite();
        await p.client.send(ump([note(1)]));
        p.host
          ..handle([
            const MidiNetworkMidi2Invitation(
              endpointName: 'Client',
              productInstanceId: 'C1',
            ),
          ])
          ..handle([
            MidiNetworkMidi2UmpData(sequenceNumber: 0, words: [note(2)]),
          ]);
        expect(wordsAt(p.host), equals([note(1), note(2)]));
      });

      test('answers repeated invitations of an established client', () async {
        final p = pair(credentials: secret, requiredSecret: secret);
        await p.client.invite();
        final accepted = sentOf<MidiNetworkMidi2InvitationAccepted>(
          toClient,
        ).length;
        p.host.handle([
          const MidiNetworkMidi2Invitation(
            endpointName: 'Client',
            productInstanceId: 'C1',
          ),
        ]);
        p.host.handle([
          MidiNetworkMidi2InvitationWithAuthentication(
            digest: List.filled(32, 0),
          ),
        ]);
        expect(
          sentOf<MidiNetworkMidi2InvitationAccepted>(toClient).length,
          accepted + 2,
        );
      });

      test('ignores invitation commands in the wrong role', () async {
        final p = pair();
        await p.client.invite();
        final before = (toHost.length, toClient.length);
        p.client.handle([
          const MidiNetworkMidi2Invitation(
            endpointName: 'X',
            productInstanceId: 'Y',
          ),
          MidiNetworkMidi2InvitationWithAuthentication(
            digest: List.filled(32, 0),
          ),
          MidiNetworkMidi2AuthenticationRequired(
            endpointName: 'X',
            productInstanceId: 'Y',
            nonce: List.filled(16, 0),
          ),
        ]);
        p.host.handle([
          const MidiNetworkMidi2InvitationPending(
            endpointName: 'X',
            productInstanceId: 'Y',
          ),
        ]);
        expect((toHost.length, toClient.length), before);
        p.host.handle([
          const MidiNetworkMidi2InvitationAccepted(
            endpointName: 'X',
            productInstanceId: 'Y',
          ),
        ]);
        expect(toClient.last.single, isA<MidiNetworkMidi2Nak>());
        expect(p.client.state, MidiNetworkConnectionState.connected);
      });
    });

    group('send(packet)', () {
      test('delivers packets in both directions', () async {
        final p = pair();
        await p.client.invite();
        await p.client.send(ump([note(1), note(2)]));
        await p.host.send(ump([0x40903C00, 0xC8000000]));
        expect(wordsAt(p.host), equals([note(1), note(2)]));
        expect(wordsAt(p.client), equals([0x40903C00, 0xC8000000]));
        expect(p.host.lossStats.packetsReceived, 1);
        expect(p.host.datagramsReceived, greaterThan(0));
      });

      test('repeats the previous commands for error correction', () async {
        final p = pair();
        await p.client.invite();
        for (var i = 0; i < 4; i++) {
          await p.client.send(ump([note(i)]));
        }
        final last = toHost.last.cast<MidiNetworkMidi2UmpData>();
        expect(last.map((d) => d.sequenceNumber), equals([1, 2, 3]));
        expect(wordsAt(p.host), equals([for (var i = 0; i < 4; i++) note(i)]));
      });

      test('splits more than 64 words into several commands', () async {
        final p = pair();
        await p.client.invite();
        final words = [
          for (var i = 0; i < 40; i++) ...[0x40903C00 | i, 0xC8000000],
        ];
        await p.client.send(ump(words));
        final commands = toHost.last.cast<MidiNetworkMidi2UmpData>();
        expect(commands.map((d) => d.words.length), equals([64, 16]));
        expect(wordsAt(p.host), equals(words));
      });

      test('spreads large sends over several datagrams', () async {
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            forwardErrorCorrection: 3,
          ),
        );
        await p.client.invite();
        final words = [for (var i = 0; i < 64 * 8; i++) 0x00000000];
        await p.client.send(ump(words));
        final datagrams = toHost
            .where((d) => d.whereType<MidiNetworkMidi2UmpData>().isNotEmpty)
            .toList();
        expect(datagrams.length, 2);
        expect(
          datagrams.last.cast<MidiNetworkMidi2UmpData>().map(
            (d) => d.sequenceNumber,
          ),
          equals([3, 4, 5, 6, 7]),
        );
        expect(wordsAt(p.host).length, words.length);
      });

      test('refuses bytes and closed connections', () async {
        final p = pair();
        await expectLater(
          p.client.send(ump([note(1)])),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'The connection to Peer is not established',
            ),
          ),
        );
        await expectLater(
          p.client.send(
            MidiBytesPacket(
              bytes: MidiBytes(const [0x90, 60, 100]),
              time: MidiTime.zero,
            ),
          ),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('sends empty commands that carry the last data', () async {
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            keepAliveStart: Duration(milliseconds: 100),
            keepAliveStep: Duration(milliseconds: 100),
            keepAliveMax: Duration(milliseconds: 250),
          ),
        );
        await p.client.invite();
        await p.client.send(ump([note(7)]));
        toHost.clear();
        timers.advance(const Duration(milliseconds: 100));
        expect(
          toHost.single.cast<MidiNetworkMidi2UmpData>().map(
            (d) => (d.sequenceNumber, d.words.length),
          ),
          equals([(0, 1), (1, 0)]),
        );
        timers.advance(const Duration(milliseconds: 200));
        expect(toHost.length, 2);
        timers.advance(const Duration(milliseconds: 250));
        expect(toHost.length, 3);
        timers.advance(const Duration(milliseconds: 250));
        expect(toHost.length, 4);
        expect(wordsAt(p.host), equals([note(7)]));
      });
    });

    group('loss and repair', () {
      test('closes a gap with the error correction', () async {
        final p = pair();
        await p.client.invite();
        await p.client.send(ump([note(1)]));
        drop = (commands, up) => up;
        await p.client.send(ump([note(2)]));
        drop = null;
        await p.client.send(ump([note(3)]));
        expect(wordsAt(p.host), equals([note(1), note(2), note(3)]));
        expect(losses, isEmpty);
        expect(
          p.host.lossStats,
          const MidiNetworkLossStats(packetsReceived: 3),
        );
      });

      test('requests what the correction cannot repair', () async {
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            forwardErrorCorrection: 0,
          ),
        );
        await p.client.invite();
        drop = (commands, up) =>
            up && commands.whereType<MidiNetworkMidi2UmpData>().isNotEmpty;
        await p.client.send(ump([note(1)]));
        await p.client.send(ump([note(2)]));
        drop = null;
        await p.client.send(ump([note(3)]));
        expect(wordsAt(p.host), isEmpty);
        timers.advance(const Duration(milliseconds: 10));
        expect(
          sentOf<MidiNetworkMidi2RetransmitRequest>(toClient),
          equals([
            const MidiNetworkMidi2RetransmitRequest(
              sequenceNumber: 0,
              count: 2,
            ),
          ]),
        );
        expect(wordsAt(p.host), equals([note(1), note(2), note(3)]));
        expect(
          p.host.lossStats,
          const MidiNetworkLossStats(
            packetsReceived: 3,
            packetsLost: 2,
            packetsRecovered: 2,
          ),
        );
        expect(losses, isEmpty);
      });

      test('reports a loss when the peer cannot retransmit', () async {
        for (final size in [0, 1]) {
          losses.clear();
          final p = pair(
            clientSettings: MidiNetworkMidi2Settings(
              forwardErrorCorrection: 0,
              retransmitBufferSize: size,
            ),
          );
          await p.client.invite();
          drop = (commands, up) =>
              up && commands.whereType<MidiNetworkMidi2UmpData>().isNotEmpty;
          await p.client.send(ump([note(1)]));
          await p.client.send(ump([note(2)]));
          drop = null;
          await p.client.send(ump([note(3)]));
          timers.advance(const Duration(milliseconds: 10));
          expect(wordsAt(p.host), equals([note(3)]));
          expect(losses.single.count, 2);
          expect(
            losses.single.cause,
            size == 0
                ? 'the peer does not retransmit'
                : 'the peer cannot retransmit',
          );
          packets.clear();
        }
      });

      test('gives up a gap after the last request', () async {
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            forwardErrorCorrection: 0,
          ),
          hostSettings: const MidiNetworkMidi2Settings(retransmitAttempts: 2),
        );
        await p.client.invite();
        drop = (commands, up) => up
            ? commands.whereType<MidiNetworkMidi2UmpData>().any(
                (d) => d.sequenceNumber == 0,
              )
            : commands
                  .whereType<MidiNetworkMidi2RetransmitRequest>()
                  .isNotEmpty;
        await p.client.send(ump([note(1)]));
        await p.client.send(ump([note(2)]));
        timers.advance(const Duration(milliseconds: 10));
        timers.advance(const Duration(milliseconds: 20));
        timers.advance(const Duration(milliseconds: 40));
        expect(sentOf<MidiNetworkMidi2RetransmitRequest>(toClient).length, 2);
        expect(losses.single.cause, 'the peer did not retransmit in time');
        expect(wordsAt(p.host), equals([note(2)]));
      });

      test('gives up a gap when too much waits behind it', () async {
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            forwardErrorCorrection: 0,
          ),
          hostSettings: const MidiNetworkMidi2Settings(receiveBufferSize: 2),
        );
        await p.client.invite();
        drop = (commands, up) => up;
        await p.client.send(ump([note(0)]));
        drop = null;
        for (var i = 1; i <= 3; i++) {
          await p.client.send(ump([note(i)]));
        }
        expect(losses.single.cause, 'too many packets wait behind a gap');
        expect(wordsAt(p.host), equals([note(1), note(2), note(3)]));
      });

      test('requests the next gap after giving up one', () async {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final host =
            single(
              outbox: outbox,
              incoming: true,
              settings: const MidiNetworkMidi2Settings(retransmitAttempts: 0),
            )..handle([
              const MidiNetworkMidi2Invitation(
                endpointName: 'Client',
                productInstanceId: 'C1',
              ),
            ]);
        host.handle([
          MidiNetworkMidi2UmpData(sequenceNumber: 1, words: [note(1)]),
          MidiNetworkMidi2UmpData(sequenceNumber: 3, words: [note(3)]),
        ]);
        timers.advance(const Duration(milliseconds: 10));
        expect(wordsAt(host), equals([note(1)]));
        expect(losses.single.count, 1);
        timers.advance(const Duration(milliseconds: 10));
        expect(wordsAt(host), equals([note(1), note(3)]));
        expect(losses.length, 2);
      });

      test('ignores duplicates and old commands', () async {
        final p = pair();
        await p.client.invite();
        final data = MidiNetworkMidi2UmpData(
          sequenceNumber: 0,
          words: [note(1)],
        );
        p.host
          ..handle([data])
          ..handle([data])
          ..handle([
            MidiNetworkMidi2UmpData(sequenceNumber: 2, words: [note(3)]),
            MidiNetworkMidi2UmpData(sequenceNumber: 2, words: [note(3)]),
            MidiNetworkMidi2UmpData(sequenceNumber: 0xFFFF, words: [note(9)]),
          ]);
        expect(wordsAt(p.host), equals([note(1)]));
      });
    });

    group('retransmit requests', () {
      test('serve everything from a sequence number on', () async {
        final p = pair();
        await p.client.invite();
        for (var i = 0; i < 3; i++) {
          await p.client.send(ump([note(i)]));
        }
        toHost.clear();
        p.client.handle([
          const MidiNetworkMidi2RetransmitRequest(sequenceNumber: 1, count: 0),
        ]);
        expect(
          toHost.single.cast<MidiNetworkMidi2UmpData>().map(
            (d) => d.sequenceNumber,
          ),
          equals([1, 2]),
        );
        p.client.handle([
          const MidiNetworkMidi2RetransmitRequest(sequenceNumber: 0, count: 1),
        ]);
        expect(
          toHost.last.cast<MidiNetworkMidi2UmpData>().map(
            (d) => d.sequenceNumber,
          ),
          equals([0]),
        );
      });

      test('report data that is gone', () async {
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            retransmitBufferSize: 2,
            forwardErrorCorrection: 0,
          ),
        );
        await p.client.invite();
        p.client.handle([
          const MidiNetworkMidi2RetransmitRequest(sequenceNumber: 0, count: 1),
        ]);
        expect(
          toHost.last,
          equals([
            const MidiNetworkMidi2RetransmitError(
              reason: MidiNetworkMidi2RetransmitError.reasonDataNotAvailable,
              sequenceNumber: 0,
            ),
          ]),
        );
        for (var i = 0; i < 3; i++) {
          await p.client.send(ump([note(i)]));
        }
        p.client.handle([
          const MidiNetworkMidi2RetransmitRequest(sequenceNumber: 0, count: 1),
        ]);
        expect(
          toHost.last,
          equals([
            const MidiNetworkMidi2RetransmitError(
              reason: MidiNetworkMidi2RetransmitError.reasonDataNotAvailable,
              sequenceNumber: 1,
            ),
          ]),
        );
      });

      test('spread over several datagrams', () async {
        final p = pair();
        await p.client.invite();
        for (var i = 0; i < 8; i++) {
          await p.client.send(ump(List.filled(64, 0)));
        }
        toHost.clear();
        p.client.handle([
          const MidiNetworkMidi2RetransmitRequest(sequenceNumber: 0, count: 0),
        ]);
        expect(toHost.map((d) => d.length), equals([5, 3]));
      });
    });

    group('reset()', () {
      test('starts both sequences at zero', () async {
        final p = pair();
        await p.client.invite();
        await p.client.send(ump([note(1)]));
        p.client.reset();
        expect(toHost.last, equals([const MidiNetworkMidi2SessionReset()]));
        expect(
          toClient.last,
          equals([const MidiNetworkMidi2SessionResetReply()]),
        );
        await p.client.send(ump([note(2)]));
        expect(
          toHost.last.cast<MidiNetworkMidi2UmpData>().single.sequenceNumber,
          0,
        );
        expect(wordsAt(p.host), equals([note(1), note(2)]));
      });

      test('throws before the session is established', () {
        final client = single(outbox: []);
        expect(client.reset, throwsA(isA<StateError>()));
      });
    });

    group('handle(commands)', () {
      test('refuses session commands outside a session once', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final client = single(outbox: outbox);
        unawaitedInvite(client);
        client.handle([
          MidiNetworkMidi2UmpData(sequenceNumber: 0),
          const MidiNetworkMidi2RetransmitRequest(sequenceNumber: 0, count: 0),
          const MidiNetworkMidi2RetransmitError(reason: 0, sequenceNumber: 0),
          const MidiNetworkMidi2SessionReset(),
          const MidiNetworkMidi2SessionResetReply(),
        ]);
        expect(
          outbox.sublist(1),
          equals([
            [
              const MidiNetworkMidi2Bye(
                reason: MidiNetworkMidi2Bye.reasonSessionNotEstablished,
              ),
            ],
          ]),
        );
      });

      test('refuses unknown and malformed commands in a session', () async {
        final p = pair();
        await p.client.invite();
        p.host.handle([
          MidiNetworkMidi2UnknownCommand(code: 0x55),
          const MidiNetworkMidi2InvalidCommand(header: 0x20000000, reason: ''),
          const MidiNetworkMidi2SessionResetReply(),
          const MidiNetworkMidi2ByeReply(),
        ]);
        expect(
          sentOf<MidiNetworkMidi2Nak>(toClient),
          equals([
            const MidiNetworkMidi2Nak(
              reason: MidiNetworkMidi2Nak.reasonCommandNotSupported,
              originalHeader: 0x55000000,
            ),
            const MidiNetworkMidi2Nak(
              reason: MidiNetworkMidi2Nak.reasonCommandMalformed,
              originalHeader: 0x20000000,
            ),
          ]),
        );
        final outbox = <List<MidiNetworkMidi2Command>>[];
        single(
          outbox: outbox,
        ).handle([MidiNetworkMidi2UnknownCommand(code: 0x55)]);
        expect(outbox, isEmpty);
      });

      test('answers pings and measures the round trip', () async {
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            pingInterval: Duration(milliseconds: 500),
          ),
        );
        await p.client.invite();
        expect(p.client.roundTrip, isNull);
        timers.advance(const Duration(milliseconds: 500));
        expect(sentOf<MidiNetworkMidi2Ping>(toHost).length, 1);
        expect(sentOf<MidiNetworkMidi2PingReply>(toClient).length, 1);
        expect(p.client.roundTrip, Duration.zero);
        p.client.handle([const MidiNetworkMidi2PingReply(pingId: 1)]);
        expect(
          toHost.last,
          equals([
            MidiNetworkMidi2Nak(
              reason: MidiNetworkMidi2Nak.reasonBadPingReply,
              originalHeader: const MidiNetworkMidi2PingReply(pingId: 1).header,
            ),
          ]),
        );
      });

      test('ignores NAKs of other commands', () async {
        final p = pair();
        await p.client.invite();
        p.client.handle([
          const MidiNetworkMidi2Nak(reason: 0, originalHeader: 0x20010000),
        ]);
        expect(p.client.state, MidiNetworkConnectionState.connected);
      });

      test('ends the session on bye', () async {
        final p = pair();
        await p.client.invite();
        p.host.handle([const MidiNetworkMidi2Bye(reason: 1)]);
        expect(p.host.state, MidiNetworkConnectionState.disconnected);
        expect(p.host.endReason, 'the peer said bye (reason 1)');
        final sent = toClient.length;
        p.host.handle([const MidiNetworkMidi2Ping(pingId: 1)]);
        expect(toClient.length, sent);
      });

      test('answers a bye after a failure without ending again', () {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final client = single(outbox: outbox);
        unawaitedInvite(client);
        timers.advance(const Duration(seconds: 5));
        changes.clear();
        client.handle([const MidiNetworkMidi2Bye(reason: 1)]);
        expect(outbox.last, equals([const MidiNetworkMidi2ByeReply()]));
        expect(changes, isEmpty);
      });
    });

    group('liveness', () {
      test('times out and invites again', () async {
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            pingInterval: Duration(seconds: 1),
            missedPingLimit: 2,
            reconnectInterval: Duration(seconds: 3),
          ),
        );
        await p.client.invite();
        drop = (commands, up) => true;
        timers.advance(const Duration(seconds: 3));
        expect(p.client.state, MidiNetworkConnectionState.failed);
        expect(p.client.endReason, 'the peer stopped answering');
        expect(p.client.isReconnecting, isTrue);
        expect(
          sentOf<MidiNetworkMidi2Bye>(toHost).last.reason,
          MidiNetworkMidi2Bye.reasonTimeout,
        );
        // Only the new invitation and its answer get through, so the host
        // still holds its session and accepts the invitation again.
        drop = (commands, up) => !commands.any(
          (c) =>
              c is MidiNetworkMidi2Invitation ||
              c is MidiNetworkMidi2InvitationAccepted,
        );
        timers.advance(const Duration(seconds: 3));
        expect(p.client.isReconnecting, isFalse);
        expect(p.client.state, MidiNetworkConnectionState.connected);
      });

      test(
        'keeps inviting after a lost session until the host answers',
        () async {
          final p = pair(
            clientSettings: const MidiNetworkMidi2Settings(
              pingInterval: Duration(seconds: 1),
              missedPingLimit: 1,
              reconnectInterval: Duration(seconds: 2),
              invitationAttempts: 2,
            ),
          );
          await p.client.invite();
          drop = (commands, up) => true;
          timers.advance(const Duration(seconds: 2));
          expect(p.client.isReconnecting, isTrue);
          timers.advance(const Duration(seconds: 4));
          expect(p.client.state, MidiNetworkConnectionState.failed);
          expect(p.client.isReconnecting, isTrue);
          expect(p.client.endReason, 'the host did not answer');
          drop = (commands, up) => !commands.any(
            (c) =>
                c is MidiNetworkMidi2Invitation ||
                c is MidiNetworkMidi2InvitationAccepted,
          );
          timers.advance(const Duration(seconds: 2));
          expect(p.client.state, MidiNetworkConnectionState.connected);
        },
      );

      test('does not reconnect as host or without interval', () async {
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            pingInterval: Duration(seconds: 1),
            missedPingLimit: 1,
            reconnectInterval: null,
          ),
          hostSettings: const MidiNetworkMidi2Settings(
            pingInterval: Duration(seconds: 1),
            missedPingLimit: 1,
          ),
        );
        await p.client.invite();
        drop = (commands, up) => true;
        timers.advance(const Duration(seconds: 2));
        expect(p.client.state, MidiNetworkConnectionState.failed);
        expect(p.host.state, MidiNetworkConnectionState.failed);
        expect(p.client.isReconnecting, isFalse);
        expect(p.host.isReconnecting, isFalse);
      });

      test('forgets old pings while traffic flows', () async {
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            pingInterval: Duration(milliseconds: 300),
            missedPingLimit: 2,
          ),
          hostSettings: const MidiNetworkMidi2Settings(
            keepAliveStart: Duration(milliseconds: 100),
            keepAliveStep: Duration.zero,
            keepAliveMax: Duration(milliseconds: 100),
          ),
        );
        await p.client.invite();
        drop = (commands, up) =>
            !up && commands.whereType<MidiNetworkMidi2PingReply>().isNotEmpty;
        timers.advance(const Duration(seconds: 10));
        expect(p.client.state, MidiNetworkConnectionState.connected);
        drop = null;
        p.client.handle([
          MidiNetworkMidi2PingReply(
            pingId: sentOf<MidiNetworkMidi2Ping>(toHost).first.pingId,
          ),
        ]);
        expect(toHost.last.single, isA<MidiNetworkMidi2Nak>());
      });
    });

    group('close()', () {
      test('says bye and waits for the reply', () async {
        final p = pair();
        await p.client.invite();
        final closing = p.client.close();
        expect(identical(p.client.close(), closing), isTrue);
        await closing;
        expect(p.client.state, MidiNetworkConnectionState.disconnected);
        expect(p.client.endReason, 'closed');
        expect(p.host.state, MidiNetworkConnectionState.disconnected);
      });

      test('repeats the bye and closes without reply', () async {
        final p = pair();
        await p.client.invite();
        drop = (commands, up) => true;
        var closed = false;
        unawaited(p.client.close().then((_) => closed = true));
        expect(p.client.state, MidiNetworkConnectionState.connected);
        timers.advance(const Duration(milliseconds: 1500));
        await Future<void>.delayed(Duration.zero);
        expect(closed, isTrue);
        expect(sentOf<MidiNetworkMidi2Bye>(toHost).length, 3);
        expect(p.client.endReason, 'closed without bye reply');
      });

      test('cancels invitations of both roles', () async {
        final outbox = <List<MidiNetworkMidi2Command>>[];
        final client = single(outbox: outbox);
        unawaitedInvite(client);
        await client.close();
        expect(
          outbox.last,
          equals([
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonInvitationCanceled,
            ),
          ]),
        );
        final host =
            single(outbox: outbox, incoming: true, requiredSecret: secret)
              ..handle([
                const MidiNetworkMidi2Invitation(
                  endpointName: 'Client',
                  productInstanceId: 'C1',
                  capabilities:
                      MidiNetworkMidi2Invitation.capabilityAuthentication,
                ),
              ]);
        await host.close();
        expect(
          outbox.last,
          equals([
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonUserTerminated,
            ),
          ]),
        );
        expect(host.state, MidiNetworkConnectionState.disconnected);
      });

      test('ends idle, failed and reconnecting connections', () async {
        final idle = single(outbox: []);
        await idle.close();
        expect(idle.state, MidiNetworkConnectionState.disconnected);
        expect(idle.endReason, 'closed by this side');
        await idle.close();
        final p = pair(
          clientSettings: const MidiNetworkMidi2Settings(
            pingInterval: Duration(seconds: 1),
            missedPingLimit: 1,
          ),
        );
        await p.client.invite();
        drop = (commands, up) => true;
        timers.advance(const Duration(seconds: 2));
        expect(p.client.isReconnecting, isTrue);
        await p.client.close();
        expect(p.client.isReconnecting, isFalse);
        expect(p.client.state, MidiNetworkConnectionState.disconnected);
        expect(p.client.endReason, 'the peer stopped answering');
        timers.advance(const Duration(seconds: 10));
        expect(p.client.state, MidiNetworkConnectionState.disconnected);
      });

      test('stops handling the rest of a datagram', () async {
        final p = pair();
        await p.client.invite();
        p.host.handle([
          const MidiNetworkMidi2Bye(reason: 1),
          MidiNetworkMidi2UmpData(sequenceNumber: 0, words: [note(1)]),
        ]);
        expect(wordsAt(p.host), isEmpty);
      });
    });

    group('MidiNetworkMidi2Connection()', () {
      test('uses the system clock, timers and a secure random', () {
        final connection = MidiNetworkMidi2Connection(
          host: peer,
          isIncoming: true,
          localEndpointName: 'Host',
          localProductInstanceId: 'H1',
          transmit: (_) {},
          listener: events,
        );
        expect(connection.state, MidiNetworkConnectionState.inviting);
        expect(connection.requiredUsers, isEmpty);
      });
    });

    group('fields', () {
      test('keep the configuration', () {
        final host = single(
          outbox: [],
          incoming: true,
          requiredSecret: secret,
          requiredUsers: [rosa],
        );
        expect(host.host, peer);
        expect(host.localEndpointName, 'Host');
        expect(host.localProductInstanceId, 'H1');
        expect(host.credentials, isNull);
        expect(host.requiredSecret, secret);
        expect(host.requiredUsers, equals([rosa]));
        expect(host.settings.invitationAttempts, 5);
        expect(host.remoteName, 'Peer');
        expect(host.remoteProductInstanceId, '');
        expect(host.roundTrip, isNull);
        expect(host.lossStats, const MidiNetworkLossStats());
      });
    });
  });
}

// Starts an invitation whose end the test does not await.
void unawaitedInvite(MidiNetworkMidi2Connection connection) {
  connection.invite().ignore();
}
