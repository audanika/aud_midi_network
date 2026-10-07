// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:math';

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  late MidiAppleMidiClockSync sync;

  setUp(() => sync = MidiAppleMidiClockSync());

  // Adds a sample of a remote clock that is [offset] ahead and runs [drift]
  // faster, measured at [localTime] with [roundTrip] and an error of [error].
  void addSample(
    int localTime, {
    int offset = 1000000,
    double drift = 0,
    int roundTrip = 200,
    int error = 0,
  }) {
    final remote = localTime + offset + (drift * localTime).round() + error;
    sync.add(localTime: localTime, remoteTime: remote, roundTrip: roundTrip);
  }

  group('MidiAppleMidiClockSync', () {
    group('MidiAppleMidiClockSync()', () {
      test('starts without samples', () {
        expect(sync.isSynchronized, isFalse);
        expect(sync.sampleCount, 0);
        expect(sync.offset, isNull);
        expect(sync.roundTrip, isNull);
        expect(sync.bestRoundTrip, isNull);
        expect(sync.drift, 0);
        expect(sync.offsetAt(0), isNull);
        expect(sync.toRemote(0), isNull);
        expect(sync.toLocal(0), isNull);
        expect(sync.window, 8);
        expect(sync.jitterTolerance, const Duration(milliseconds: 1));
        expect(sync.maxDrift, 0.0005);
        expect(sync.minDriftSpan, const Duration(seconds: 5));
      });
    });

    group('add(localTime, remoteTime, roundTrip)', () {
      test('takes the first sample as the estimate', () {
        expect(
          sync.add(localTime: 5000, remoteTime: 105000, roundTrip: 300),
          isTrue,
        );
        expect(sync.isSynchronized, isTrue);
        expect(sync.sampleCount, 1);
        expect(sync.offset, const Duration(microseconds: 100000));
        expect(sync.roundTrip, const Duration(microseconds: 300));
        expect(sync.bestRoundTrip, const Duration(microseconds: 300));
        expect(sync.toRemote(6000), 106000);
        expect(sync.toLocal(106000), 6000);
      });

      test('rejects a negative round trip', () {
        expect(
          sync.add(localTime: 5000, remoteTime: 5000, roundTrip: -1),
          isFalse,
        );
        expect(sync.isSynchronized, isFalse);
      });

      test('averages the samples with good round trips', () {
        addSample(0, error: 100);
        addSample(1000, error: -100);
        addSample(2000, roundTrip: 5000, error: 2400);
        expect(sync.sampleCount, 3);
        expect(sync.offset, const Duration(microseconds: 1000000));
        expect(sync.roundTrip, const Duration(microseconds: 5000));
        expect(sync.bestRoundTrip, const Duration(microseconds: 200));
      });

      test('keeps only the last window samples', () {
        sync = MidiAppleMidiClockSync(window: 2);
        addSample(0, roundTrip: 10);
        addSample(1000, roundTrip: 20);
        addSample(2000, roundTrip: 30);
        expect(sync.sampleCount, 2);
        expect(sync.bestRoundTrip, const Duration(microseconds: 20));
      });

      test('estimates the drift once the samples span long enough', () {
        for (var i = 0; i < 8; i++) {
          addSample(i * 1000000, drift: 0.0001);
        }
        expect(sync.drift, closeTo(0.0001, 0.000001));
        const local = 20000000;
        final expected = local + 1000000 + (0.0001 * local).round();
        expect(sync.toRemote(local), closeTo(expected, 2));
        expect(sync.toLocal(expected), closeTo(local, 2));
      });

      test('ignores the drift below three samples or a short span', () {
        addSample(0, drift: 0.0001);
        addSample(10000000, drift: 0.0001);
        expect(sync.drift, 0);
        sync = MidiAppleMidiClockSync();
        for (var i = 0; i < 4; i++) {
          addSample(i * 1000, drift: 0.0001);
        }
        expect(sync.drift, 0);
        sync = MidiAppleMidiClockSync(minDriftSpan: Duration.zero);
        for (var i = 0; i < 3; i++) {
          sync.add(localTime: 7, remoteTime: 9 + i, roundTrip: 100);
        }
        expect(sync.drift, 0);
        expect(sync.offset, const Duration(microseconds: 3));
      });

      test('bounds the drift', () {
        for (final drift in [0.01, -0.01]) {
          sync = MidiAppleMidiClockSync(
            minDriftSpan: const Duration(milliseconds: 100),
          );
          for (var i = 0; i < 4; i++) {
            addSample(i * 100000, drift: drift);
          }
          expect(sync.sampleCount, 4);
          expect(sync.drift, drift.sign * 0.0005);
        }
      });

      test('starts anew when a good sample contradicts the estimate', () {
        addSample(0);
        addSample(1000);
        addSample(2000, offset: 9000000);
        expect(sync.sampleCount, 1);
        expect(sync.offset, const Duration(microseconds: 9000000));
      });

      test('keeps the estimate for a contradicting slow sample', () {
        addSample(0);
        addSample(1000);
        addSample(2000, offset: 9000000, roundTrip: 50000);
        expect(sync.sampleCount, 3);
        expect(sync.offset, const Duration(microseconds: 1000000));
      });

      test('converges under jitter and drift', () {
        final random = Random(7);
        const offset = 123456789;
        const drift = 0.00002;
        for (var i = 0; i < 40; i++) {
          final local = i * 1000000;
          final up = 100 + random.nextInt(400);
          final down = 100 + random.nextInt(400);
          // The remote reads its clock when the request arrived.
          final remote = local + up + offset + (drift * (local + up)).round();
          sync.add(
            localTime: local + (up + down) ~/ 2,
            remoteTime: remote,
            roundTrip: up + down,
          );
        }
        const now = 40000000;
        final truth = now + offset + (drift * now).round();
        expect((sync.toRemote(now)! - truth).abs(), lessThan(300));
      });
    });

    group('reset()', () {
      test('forgets all samples', () {
        addSample(0);
        sync.reset();
        expect(sync.isSynchronized, isFalse);
        expect(sync.drift, 0);
        expect(sync.offset, isNull);
      });
    });
  });
}
