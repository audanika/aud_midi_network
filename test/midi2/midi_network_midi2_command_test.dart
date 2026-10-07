// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  Uint8List bytes(String hex) => Uint8List.fromList([
    for (final pair in hex.trim().split(RegExp(r'\s+')))
      int.parse(pair, radix: 16),
  ]);

  String hex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  group('MidiNetworkMidi2Command', () {
    group('encode()', () {
      test('writes the header word and the payload', () {
        expect(
          hex(const MidiNetworkMidi2Ping(pingId: 0x01020304).encode()),
          '20 01 00 00 01 02 03 04',
        );
        expect(
          hex(const MidiNetworkMidi2SessionReset().encode()),
          '82 00 00 00',
        );
      });
    });

    group('header', () {
      test('is the first word of the command packet', () {
        expect(
          const MidiNetworkMidi2RetransmitRequest(
            sequenceNumber: 0x1234,
            count: 2,
          ).header,
          0x80011234,
        );
      });
    });

    group('commandSpecificData', () {
      test('is zero for commands without specific data', () {
        expect(const MidiNetworkMidi2ByeReply().commandSpecificData, 0);
      });
    });

    group('==, hashCode, toString', () {
      test('compare the type and all fields', () {
        const ping = MidiNetworkMidi2Ping(pingId: 1);
        final variants = <Object>[
          const MidiNetworkMidi2Ping(pingId: 2),
          const MidiNetworkMidi2PingReply(pingId: 1),
          MidiNetworkMidi2UnknownCommand(code: 1, payload: const [1, 2]),
          'ping',
        ];
        for (final variant in variants) {
          expect(ping == variant, isFalse, reason: '$variant');
        }
        expect(ping == MidiNetworkMidi2Ping(pingId: int.parse('1')), isTrue);
        expect(ping == ping, isTrue);
        expect(
          ping.hashCode,
          MidiNetworkMidi2Ping(pingId: int.parse('1')).hashCode,
        );
        expect(ping.toString(), 'MidiNetworkMidi2Ping(1)');
        expect(
          const MidiNetworkMidi2SessionReset(),
          const MidiNetworkMidi2SessionReset(),
        );
        expect(
          const MidiNetworkMidi2SessionReset().toString(),
          'MidiNetworkMidi2SessionReset()',
        );
      });

      test('compare list fields by content', () {
        MidiNetworkMidi2UnknownCommand unknown(List<int> payload) =>
            MidiNetworkMidi2UnknownCommand(code: 0x55, payload: payload);
        expect(unknown([1, 2, 3, 4]), unknown([1, 2, 3, 4]));
        expect(unknown([1, 2, 3, 4]).hashCode, unknown([1, 2, 3, 4]).hashCode);
        expect(unknown([1, 2, 3, 4]) == unknown([1, 2, 3, 5]), isFalse);
        expect(unknown([1, 2, 3, 4]) == unknown([1, 2, 3, 4, 5]), isFalse);
      });
    });

    group('isPacket(data)', () {
      test('accepts the signature MIDI only', () {
        expect(MidiNetworkMidi2Command.isPacket(bytes('4d 49 44 49')), isTrue);
        for (final data in ['4d 49 44', '00 49 44 49', '4d 00 44 49']) {
          expect(MidiNetworkMidi2Command.isPacket(bytes(data)), isFalse);
        }
        expect(MidiNetworkMidi2Command.isPacket(bytes('4d 49 00 49')), isFalse);
        expect(MidiNetworkMidi2Command.isPacket(bytes('4d 49 44 00')), isFalse);
      });
    });

    group('decodePacket(data)', () {
      test('decodes every command of the packet', () {
        final packet = MidiNetworkMidi2Command.encodePacket([
          const MidiNetworkMidi2Ping(pingId: 7),
          MidiNetworkMidi2UmpData(sequenceNumber: 3, words: const [0x10F80000]),
          const MidiNetworkMidi2Invitation(
            endpointName: 'Dart',
            productInstanceId: 'P1',
          ),
        ]);
        expect(
          MidiNetworkMidi2Command.decodePacket(packet),
          equals([
            const MidiNetworkMidi2Ping(pingId: 7),
            MidiNetworkMidi2UmpData(
              sequenceNumber: 3,
              words: const [0x10F80000],
            ),
            const MidiNetworkMidi2Invitation(
              endpointName: 'Dart',
              productInstanceId: 'P1',
            ),
          ]),
        );
      });

      test('ignores trailing bytes shorter than a header', () {
        expect(
          MidiNetworkMidi2Command.decodePacket(
            bytes('4d 49 44 49 82 00 00 00 ff ff'),
          ),
          equals([const MidiNetworkMidi2SessionReset()]),
        );
      });

      test('stops at a payload that exceeds the packet', () {
        expect(
          MidiNetworkMidi2Command.decodePacket(
            bytes('4d 49 44 49 82 00 00 00 20 02 00 00 00 00 00 01'),
          ),
          equals([
            const MidiNetworkMidi2SessionReset(),
            const MidiNetworkMidi2InvalidCommand(
              header: 0x20020000,
              reason: 'The payload exceeds the packet',
            ),
          ]),
        );
      });

      test('turns undecodable commands into invalid ones', () {
        expect(
          MidiNetworkMidi2Command.decodePacket(
            bytes('4d 49 44 49 20 00 00 00 21 01 00 00 00 00 00 09'),
          ),
          equals([
            const MidiNetworkMidi2InvalidCommand(
              header: 0x20000000,
              reason: 'The payload lacks word 1',
            ),
            const MidiNetworkMidi2PingReply(pingId: 9),
          ]),
        );
      });

      test('dispatches every command group', () {
        final commands = [
          MidiNetworkMidi2AuthenticationRequired(
            endpointName: 'Host',
            productInstanceId: 'H1',
            nonce: List.filled(16, 7),
          ),
          const MidiNetworkMidi2RetransmitError(reason: 1, sequenceNumber: 9),
          const MidiNetworkMidi2Bye(reason: 1, message: 'Bye'),
        ];
        expect(
          MidiNetworkMidi2Command.decodePacket(
            MidiNetworkMidi2Command.encodePacket(commands),
          ),
          equals(commands),
        );
      });

      test('throws without signature', () {
        expect(
          () => MidiNetworkMidi2Command.decodePacket(bytes('ff ff 49 4e')),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'Not a Network MIDI 2.0 packet',
            ),
          ),
        );
      });
    });

    group('encodePacket(commands)', () {
      test('writes the signature and the commands', () {
        expect(
          hex(
            MidiNetworkMidi2Command.encodePacket([
              const MidiNetworkMidi2ByeReply(),
              const MidiNetworkMidi2SessionResetReply(),
            ]),
          ),
          '4d 49 44 49 f1 00 00 00 83 00 00 00',
        );
      });
    });

    group('strings', () {
      test('are padded, truncated whole and read up to the first zero', () {
        final name = '${'a' * 97}ä';
        final invitation = MidiNetworkMidi2Invitation(
          endpointName: name,
          productInstanceId: 'X',
        );
        final encoded = invitation.encode();
        expect(encoded.length, 4 + 100 + 4);
        final decoded =
            MidiNetworkMidi2Command.decodePacket([
                  ...MidiNetworkMidi2Command.signature,
                  ...encoded,
                ]).single
                as MidiNetworkMidi2Invitation;
        expect(decoded.endpointName, 'a' * 97);
        expect(decoded.productInstanceId, 'X');
      });

      test('keep a name that fills whole words', () {
        final decoded = MidiNetworkMidi2Command.decodePacket(
          bytes('4d 49 44 49 f0 01 01 00 61 62 63 64'),
        );
        expect(
          decoded,
          equals([const MidiNetworkMidi2Bye(reason: 1, message: 'abcd')]),
        );
      });
    });

    group('constants', () {
      test('match the specification', () {
        expect(MidiNetworkMidi2Command.signature, [0x4D, 0x49, 0x44, 0x49]);
        expect(MidiNetworkMidi2Command.maxPacketBytes, 1400);
        expect(MidiNetworkMidi2Command.maxEndpointNameBytes, 98);
        expect(MidiNetworkMidi2Command.maxProductInstanceIdBytes, 42);
      });
    });
  });
}
