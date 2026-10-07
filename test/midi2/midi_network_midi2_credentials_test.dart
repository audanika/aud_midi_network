// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:math';

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  String hex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  group('MidiNetworkMidi2SharedSecret', () {
    group('digest(nonce)', () {
      test('matches the example of M2-124-UM 6.9', () {
        expect(
          hex(
            const MidiNetworkMidi2SharedSecret(
              '5483',
            ).digest(ascii.encode(r'nUWrn*@#$hjfwnkL')),
          ),
          '676EBE82587CECA8F82FC333D787951EEC2B00AD31613CC4DB18CF27373AFB82',
        );
      });
    });

    group('==, hashCode, toString', () {
      test('compare the secret and hide it', () {
        const a = MidiNetworkMidi2SharedSecret('a');
        expect(a, MidiNetworkMidi2SharedSecret(String.fromCharCode(97)));
        expect(a == const MidiNetworkMidi2SharedSecret('b'), isFalse);
        expect(a.hashCode, 'a'.hashCode);
        expect(a.toString(), 'MidiNetworkMidi2SharedSecret(***)');
        expect(a.secret, 'a');
      });
    });
  });

  group('MidiNetworkMidi2UserCredentials', () {
    group('digest(nonce)', () {
      test('matches the example of M2-124-UM 6.10', () {
        expect(
          hex(
            const MidiNetworkMidi2UserCredentials(
              userName: 'Rosa',
              password: 'RPBqBno',
            ).digest(ascii.encode('XI|~=NNRVaD;XCPL')),
          ),
          '3A2D5EBEEF92E8463535C27FB4B7B3E2D1ACF57A844C6D0808E041C102B7FF1A',
        );
      });

      test('hashes non-ASCII names as UTF-8', () {
        final nonce = ascii.encode('0123456789ABCDEF');
        expect(
          const MidiNetworkMidi2UserCredentials(
            userName: 'Café',
            password: 'pw',
          ).digest(nonce),
          const MidiNetworkMidi2SharedSecret('Cafépw').digest(nonce),
        );
      });
    });

    group('==, hashCode, toString', () {
      test('compare both fields and hide the password', () {
        const a = MidiNetworkMidi2UserCredentials(userName: 'u', password: 'p');
        expect(
          a,
          MidiNetworkMidi2UserCredentials(
            userName: String.fromCharCode(117),
            password: 'p',
          ),
        );
        expect(
          a ==
              const MidiNetworkMidi2UserCredentials(
                userName: 'x',
                password: 'p',
              ),
          isFalse,
        );
        expect(
          a ==
              const MidiNetworkMidi2UserCredentials(
                userName: 'u',
                password: 'x',
              ),
          isFalse,
        );
        expect(a.hashCode, Object.hash('u', 'p'));
        expect(a.toString(), "MidiNetworkMidi2UserCredentials(userName: 'u')");
      });
    });
  });

  group('MidiNetworkMidi2Credentials', () {
    group('digestsMatch(a, b)', () {
      test('compares length and content', () {
        expect(
          MidiNetworkMidi2Credentials.digestsMatch([1, 2], [1, 2]),
          isTrue,
        );
        expect(
          MidiNetworkMidi2Credentials.digestsMatch([1, 2], [1, 3]),
          isFalse,
        );
        expect(MidiNetworkMidi2Credentials.digestsMatch([1, 2], [1]), isFalse);
      });
    });

    group('createNonce(random)', () {
      test('creates printable ASCII characters', () {
        final nonce = MidiNetworkMidi2Credentials.createNonce(Random(1));
        expect(nonce.length, MidiNetworkMidi2Credentials.nonceLength);
        expect(nonce.every((c) => c >= 0x21 && c <= 0x7E), isTrue);
        expect(
          MidiNetworkMidi2Credentials.createNonce(Random(1)),
          equals(nonce),
        );
      });

      test('uses a secure generator by default', () {
        expect(
          MidiNetworkMidi2Credentials.createNonce(),
          isNot(equals(MidiNetworkMidi2Credentials.createNonce())),
        );
      });
    });

    group('constants', () {
      test('match the specification', () {
        expect(MidiNetworkMidi2Credentials.nonceLength, 16);
        expect(MidiNetworkMidi2Credentials.digestLength, 32);
      });
    });
  });
}
