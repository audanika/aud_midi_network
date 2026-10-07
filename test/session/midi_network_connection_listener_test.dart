// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  group('MidiNetworkConnectionListener', () {
    test('is implemented by the session events', () {
      expect(MidiNetworkSessionEvents(), isA<MidiNetworkConnectionListener>());
    });
  });
}
