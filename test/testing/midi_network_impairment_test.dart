// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:math';

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  group('MidiNetworkImpairment', () {
    group('decide(random, inBurst)', () {
      test('delivers every datagram at once without impairment', () {
        final decision = MidiNetworkImpairment.none.decide(
          Random(1),
          inBurst: false,
        );
        expect(decision.inBurst, isFalse);
        expect(decision.deliveries, equals([Duration.zero]));
        expect(decision.reordered, isFalse);
      });

      test('loses the share of datagrams given by loss', () {
        const impairment = MidiNetworkImpairment(loss: 0.25);
        final random = Random(2);
        var lost = 0;
        for (var i = 0; i < 10000; i++) {
          if (impairment.decide(random, inBurst: false).deliveries.isEmpty) {
            lost++;
          }
        }
        expect(lost, closeTo(2500, 150));
      });

      test('enters, keeps and leaves a burst', () {
        const entering = MidiNetworkImpairment(burstStart: 1, burstEnd: 0);
        final first = entering.decide(Random(3), inBurst: false);
        expect(first.inBurst, isTrue);
        expect(first.deliveries, isEmpty);
        expect(entering.decide(Random(3), inBurst: true).inBurst, isTrue);
        const leaving = MidiNetworkImpairment(burstStart: 1, burstLoss: 0.5);
        final last = leaving.decide(Random(3), inBurst: true);
        expect(last.inBurst, isFalse);
        expect(last.deliveries, equals([Duration.zero]));
      });

      test('loses with burstLoss inside a burst', () {
        const impairment = MidiNetworkImpairment(
          burstStart: 1,
          burstEnd: 0,
          burstLoss: 0.5,
        );
        final random = Random(4);
        var lost = 0;
        for (var i = 0; i < 1000; i++) {
          if (impairment.decide(random, inBurst: true).deliveries.isEmpty) {
            lost++;
          }
        }
        expect(lost, closeTo(500, 60));
      });

      test('duplicates a datagram', () {
        const impairment = MidiNetworkImpairment(duplicate: 1);
        expect(
          impairment.decide(Random(5), inBurst: false).deliveries,
          equals([Duration.zero, const Duration(microseconds: 100)]),
        );
      });

      test('holds a reordered datagram back', () {
        const impairment = MidiNetworkImpairment(
          reorder: 1,
          delay: Duration(milliseconds: 1),
          reorderDelay: Duration(milliseconds: 3),
        );
        final decision = impairment.decide(Random(6), inBurst: false);
        expect(decision.deliveries, equals([const Duration(milliseconds: 4)]));
        expect(decision.reordered, isTrue);
      });

      test('adds a random share of the jitter to the delay', () {
        const impairment = MidiNetworkImpairment(
          delay: Duration(milliseconds: 2),
          jitter: Duration(milliseconds: 1),
        );
        final random = Random(7);
        for (var i = 0; i < 100; i++) {
          final wait = impairment.decide(random, inBurst: false).deliveries;
          expect(wait.single.inMicroseconds, inInclusiveRange(2000, 3000));
        }
      });
    });

    group('isNone', () {
      test('is false as soon as anything impairs the link', () {
        expect(MidiNetworkImpairment.none.isNone, isTrue);
        const impairments = [
          MidiNetworkImpairment(loss: 0.1),
          MidiNetworkImpairment(burstStart: 0.1),
          MidiNetworkImpairment(duplicate: 0.1),
          MidiNetworkImpairment(reorder: 0.1),
          MidiNetworkImpairment(delay: Duration(milliseconds: 1)),
          MidiNetworkImpairment(jitter: Duration(milliseconds: 1)),
        ];
        for (final impairment in impairments) {
          expect(impairment.isNone, isFalse, reason: '$impairment');
        }
      });
    });

    group('toString()', () {
      test('lists all fields', () {
        expect(
          MidiNetworkImpairment.none.toString(),
          'MidiNetworkImpairment(loss: 0.0, burstStart: 0.0, '
          'burstEnd: 1.0, burstLoss: 1.0, duplicate: 0.0, reorder: 0.0, '
          'delay: 0:00:00.000000, jitter: 0:00:00.000000, '
          'reorderDelay: 0:00:00.005000)',
        );
      });
    });
  });
}
