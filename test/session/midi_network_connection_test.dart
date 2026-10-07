// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  group('MidiNetworkConnection', () {
    test('is implemented by the connections of both protocols', () {
      final connection = MidiNetworkMidi2Connection(
        host: const MidiNetworkHostInfo(name: 'P', address: '::1', port: 1),
        isIncoming: false,
        localEndpointName: 'L',
        localProductInstanceId: 'L1',
        transmit: (_) {},
        listener: MidiNetworkSessionEvents(),
      );
      expect(connection, isA<MidiNetworkConnection>());
    });
  });
}
