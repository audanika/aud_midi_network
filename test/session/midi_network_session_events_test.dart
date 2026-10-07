// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  group('MidiNetworkSessionEvents', () {
    late MidiNetworkSessionEvents events;
    late MidiNetworkConnection connection;

    setUp(() {
      events = MidiNetworkSessionEvents();
      connection = MidiNetworkMidi2Connection(
        host: const MidiNetworkHostInfo(
          name: 'Peer',
          address: '127.0.0.1',
          port: 1,
        ),
        isIncoming: true,
        localEndpointName: 'Local',
        localProductInstanceId: 'L1',
        transmit: (_) {},
        listener: events,
      );
    });

    group('connectionChanged, packetReceived, packetsLost', () {
      test('reach the listeners at once', () {
        final changes = <MidiNetworkConnection>[];
        final received = <MidiNetworkReceived>[];
        final losses = <MidiNetworkLoss>[];
        events.connectionChanges.listen(changes.add);
        events.received.listen(received.add);
        events.losses.listen(losses.add);
        final packet = MidiUmpPacket(words: const [0], time: MidiTime.zero);
        events
          ..connectionChanged(connection)
          ..packetReceived(connection, packet)
          ..packetsLost(connection, 3, 'gone');
        expect(changes, equals([connection]));
        expect(received.single.connection, same(connection));
        expect(received.single.packet, packet);
        expect(losses.single.count, 3);
        expect(losses.single.cause, 'gone');
      });
    });

    group('close()', () {
      test('ends the streams and drops later reports', () async {
        final done = <String>[];
        events.connectionChanges.listen(null, onDone: () => done.add('c'));
        events.received.listen(null, onDone: () => done.add('r'));
        events.losses.listen(null, onDone: () => done.add('l'));
        await events.close();
        expect(done, equals(['c', 'r', 'l']));
        events
          ..connectionChanged(connection)
          ..packetsLost(connection, 1, 'late');
      });
    });
  });
}
