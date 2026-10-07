// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:test/test.dart';

void main() {
  group('MidiNetworkAccess', () {
    group('allows(name, address, productInstanceId)', () {
      test('admits everybody by default', () {
        expect(MidiNetworkAccess().allows(name: '', address: ''), isTrue);
      });

      test('admits listed names, addresses and ids only', () {
        for (final policy in [
          MidiNetworkConnectionPolicy.contacts,
          MidiNetworkConnectionPolicy.specificPeers,
        ]) {
          final access = MidiNetworkAccess(
            policy: policy,
            allowedPeers: {'Studio', '10.0.0.7', 'PIID'},
          );
          expect(access.allows(name: 'Studio', address: '10.0.0.1'), isTrue);
          expect(access.allows(name: 'Other', address: '10.0.0.7'), isTrue);
          expect(
            access.allows(
              name: 'Other',
              address: '10.0.0.1',
              productInstanceId: 'PIID',
            ),
            isTrue,
          );
          expect(access.allows(name: 'Other', address: '10.0.0.1'), isFalse);
        }
      });

      test('never matches empty identifiers', () {
        final access = MidiNetworkAccess(
          policy: MidiNetworkConnectionPolicy.specificPeers,
          allowedPeers: {''},
        );
        expect(access.allows(name: '', address: ''), isFalse);
      });
    });

    group('allowedPeers', () {
      test('is an unmodifiable copy', () {
        final peers = {'A'};
        final access = MidiNetworkAccess(allowedPeers: peers);
        peers.add('B');
        expect(access.allowedPeers, equals({'A'}));
        expect(() => access.allowedPeers.add('C'), throwsUnsupportedError);
      });
    });

    group('==, hashCode, toString', () {
      test('compare the policy and the peers in any order', () {
        final a = MidiNetworkAccess(
          policy: MidiNetworkConnectionPolicy.specificPeers,
          allowedPeers: {'A', 'B'},
        );
        final b = MidiNetworkAccess(
          policy: MidiNetworkConnectionPolicy.specificPeers,
          allowedPeers: {'B', 'A'},
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
        expect(a == MidiNetworkAccess(allowedPeers: {'A', 'B'}), isFalse);
        expect(
          a ==
              MidiNetworkAccess(
                policy: MidiNetworkConnectionPolicy.specificPeers,
                allowedPeers: {'A'},
              ),
          isFalse,
        );
        expect(
          a ==
              MidiNetworkAccess(
                policy: MidiNetworkConnectionPolicy.specificPeers,
                allowedPeers: {'A', 'C'},
              ),
          isFalse,
        );
        expect(
          a.toString(),
          'MidiNetworkAccess(policy: specificPeers, allowedPeers: {A, B})',
        );
      });
    });
  });
}
