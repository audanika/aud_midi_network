// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  group('MidiNetworkMidi2Settings', () {
    test('defaults to the recommendations of the specification', () {
      const settings = MidiNetworkMidi2Settings();
      expect(settings.invitationInterval, const Duration(seconds: 1));
      expect(settings.invitationAttempts, 5);
      expect(settings.pendingTimeout, const Duration(seconds: 120));
      expect(settings.pingInterval, const Duration(seconds: 2));
      expect(settings.missedPingLimit, 5);
      expect(settings.forwardErrorCorrection, 2);
      expect(settings.retransmitBufferSize, 250);
      expect(settings.retransmitDelay, const Duration(milliseconds: 10));
      expect(settings.retransmitAttempts, 3);
      expect(settings.receiveBufferSize, 256);
      expect(settings.keepAliveStart, const Duration(milliseconds: 200));
      expect(settings.keepAliveStep, const Duration(milliseconds: 200));
      expect(settings.keepAliveMax, const Duration(seconds: 2));
      expect(settings.byeTimeout, const Duration(milliseconds: 500));
      expect(settings.byeAttempts, 3);
      expect(settings.reconnectInterval, const Duration(seconds: 5));
      expect(settings.authenticationAttempts, 3);
      expect(settings.maxSessions, 64);
    });
  });
}
