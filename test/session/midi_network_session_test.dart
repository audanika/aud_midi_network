// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  group('MidiNetworkSession', () {
    test('is implemented by the sessions of both protocols', () {
      expect(
        MidiNetworkMidi2Session(localName: 'S'),
        isA<MidiNetworkSession>(),
      );
    });
  });
}
