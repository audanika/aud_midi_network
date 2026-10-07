// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  group('MidiAppleMidiSettings', () {
    test('defaults to the timing of Apple\'s driver', () {
      const settings = MidiAppleMidiSettings();
      expect(settings.invitationInterval, const Duration(seconds: 1));
      expect(settings.invitationBackoff, 1.5);
      expect(settings.maxInvitationInterval, const Duration(seconds: 4));
      expect(settings.invitationAttempts, 12);
      expect(settings.initialSyncInterval, const Duration(milliseconds: 1500));
      expect(settings.initialSyncCount, 6);
      expect(settings.syncInterval, const Duration(seconds: 10));
      expect(settings.missedSyncLimit, 3);
      expect(settings.sessionTimeout, const Duration(seconds: 75));
      expect(settings.feedbackInterval, const Duration(seconds: 1));
      expect(
        settings.guardIntervals,
        equals(const [
          Duration(milliseconds: 20),
          Duration(milliseconds: 100),
          Duration(milliseconds: 400),
        ]),
      );
      expect(settings.reconnectInterval, const Duration(seconds: 5));
      expect(settings.initialTimestamp, isNull);
      expect(settings.maxSysExLength, 1 << 20);
    });
  });
}
