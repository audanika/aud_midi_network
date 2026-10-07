// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

@TestOn('mac-os')
library;

import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

// Interop with Apple's own network MIDI driver (MIDINetworkSession).
//
// Enabling the macOS network session changes a global system setting, so
// this test only runs with AUD_MIDI_TEST_APPLE_INTEROP=1, after "Session 1"
// was enabled in Audio MIDI Setup (MIDI Studio > Network) or through
// aud_midi_apple. AUD_MIDI_TEST_APPLE_PORT overrides the control port 5004.
void main() {
  final environment = Platform.environment;
  final enabled = environment['AUD_MIDI_TEST_APPLE_INTEROP'] == '1';
  final port = int.tryParse(environment['AUD_MIDI_TEST_APPLE_PORT'] ?? '');

  test(
    'joins the network session of macOS',
    () async {
      final session = MidiAppleMidiSession(
        localName: 'aud_midi interop',
        requestedPort: 0,
      );
      await session.open();
      addTearDown(session.close);
      final host = MidiNetworkHostInfo(
        name: 'Session 1',
        address: '127.0.0.1',
        port: port ?? MidiAppleMidiSession.defaultPort,
      );
      final connection = await session.connect(host);
      expect(
        connection.state,
        MidiNetworkConnectionState.connected,
        reason: '${connection.endReason}',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (connection.clockSync.sampleCount < 3 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(connection.clockSync.sampleCount, greaterThanOrEqualTo(3));
      const clock = MidiSystemClock();
      for (final bytes in [
        [0x90, 60, 100],
        [0xB0, 7, 100],
        [0xF0, 0x7D, 0x01, 0x02, 0xF7],
        [0x80, 60, 64],
      ]) {
        await connection.send(
          MidiBytesPacket(bytes: MidiBytes(bytes), time: clock.now()),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(connection.state, MidiNetworkConnectionState.connected);
      await session.disconnect(host);
      expect(connection.state, MidiNetworkConnectionState.disconnected);
    },
    skip: enabled
        ? false
        : 'Set AUD_MIDI_TEST_APPLE_INTEROP=1 with the macOS network session '
              'enabled',
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
