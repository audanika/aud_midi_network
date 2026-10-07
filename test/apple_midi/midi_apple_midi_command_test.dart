// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  const Object other = 'other';

  Uint8List bytes(String hex) => Uint8List.fromList([
    for (final pair in hex.split(' ')) int.parse(pair, radix: 16),
  ]);

  // An invitation of Apple's driver: version 2, token 0x11223344, SSRC
  // 0xA1B2C3D4, name "Mac" with its terminating zero.
  const invitationHex =
      'ff ff 49 4e 00 00 00 02 11 22 33 44 a1 b2 c3 d4 4d 61 63 00';

  group('MidiAppleMidiCommand', () {
    group('decode(data)', () {
      test('decodes the four session commands', () {
        final commands = [
          for (final code in ['49 4e', '4f 4b', '4e 4f', '42 59'])
            MidiAppleMidiCommand.decode(
              bytes(
                'ff ff $code 00 00 00 02 11 22 33 44 a1 b2 c3 d4 4d 61 63 00',
              ),
            ),
        ];
        expect(
          commands,
          equals([
            const MidiAppleMidiInvitation(
              token: 0x11223344,
              ssrc: 0xA1B2C3D4,
              name: 'Mac',
            ),
            const MidiAppleMidiInvitationAccepted(
              token: 0x11223344,
              ssrc: 0xA1B2C3D4,
              name: 'Mac',
            ),
            const MidiAppleMidiInvitationRejected(
              token: 0x11223344,
              ssrc: 0xA1B2C3D4,
              name: 'Mac',
            ),
            const MidiAppleMidiEndSession(
              token: 0x11223344,
              ssrc: 0xA1B2C3D4,
              name: 'Mac',
            ),
          ]),
        );
      });

      test('reads a name without terminator up to the end', () {
        final command = MidiAppleMidiCommand.decode(
          bytes('ff ff 49 4e 00 00 00 03 00 00 00 01 00 00 00 02 c3 a4'),
        );
        expect(
          command,
          const MidiAppleMidiInvitation(
            token: 1,
            ssrc: 2,
            name: 'ä',
            version: 3,
          ),
        );
      });

      test('reads a missing name as empty', () {
        final command = MidiAppleMidiCommand.decode(
          bytes('ff ff 42 59 00 00 00 02 00 00 00 01 00 00 00 02'),
        );
        expect(command, const MidiAppleMidiEndSession(token: 1, ssrc: 2));
      });

      test('decodes CK with three 64-bit timestamps', () {
        final command = MidiAppleMidiCommand.decode(
          bytes(
            'ff ff 43 4b 00 00 00 07 02 00 00 00 '
            '00 00 00 01 00 00 00 02 '
            '00 00 00 00 00 00 00 03 '
            '7f ff ff ff ff ff ff ff',
          ),
        );
        expect(
          command,
          MidiAppleMidiSync(
            ssrc: 7,
            count: 2,
            timestamps: const [0x100000002, 3, 0x7FFFFFFFFFFFFFFF],
          ),
        );
      });

      test('decodes RS with the sequence number in the upper half', () {
        final command = MidiAppleMidiCommand.decode(
          bytes('ff ff 52 53 00 00 00 07 ab cd 00 00'),
        );
        expect(
          command,
          const MidiAppleMidiReceiverFeedback(ssrc: 7, sequenceNumber: 0xABCD),
        );
      });

      test('decodes RL', () {
        final command = MidiAppleMidiCommand.decode(
          bytes('ff ff 52 4c 00 00 00 07 00 00 7a 12'),
        );
        expect(command, const MidiAppleMidiBitrateLimit(ssrc: 7, limit: 31250));
      });

      test('throws for data without signature', () {
        for (final hex in ['80 61 00 01', 'ff ff 49']) {
          expect(
            () => MidiAppleMidiCommand.decode(bytes(hex)),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                'Not an AppleMIDI command',
              ),
            ),
          );
        }
      });

      test('throws for an unknown command', () {
        expect(
          () => MidiAppleMidiCommand.decode(bytes('ff ff 58 58 00 00')),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'Unknown AppleMIDI command XX',
            ),
          ),
        );
      });

      test('throws for commands that are too short', () {
        final cases = {
          'ff ff 49 4e 00 00 00 02': 'IN needs 16 bytes, got 8',
          'ff ff 43 4b 00 00 00 02': 'CK needs 36 bytes, got 8',
          'ff ff 52 53 00 00 00 02': 'RS needs 12 bytes, got 8',
          'ff ff 52 4c 00 00': 'RL needs 12 bytes, got 6',
        };
        for (final MapEntry(key: hex, value: message) in cases.entries) {
          expect(
            () => MidiAppleMidiCommand.decode(bytes(hex)),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                'AppleMIDI command $message',
              ),
            ),
          );
        }
      });

      test('throws for a CK count above 2', () {
        final data = MidiAppleMidiSync(
          ssrc: 1,
          count: 0,
          timestamps: const [0, 0, 0],
        ).encode()..[8] = 3;
        expect(
          () => MidiAppleMidiCommand.decode(data),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'AppleMIDI CK count 3 is out of range',
            ),
          ),
        );
      });
    });

    group('encode()', () {
      test('writes Apple\'s byte layout', () {
        expect(
          const MidiAppleMidiInvitation(
            token: 0x11223344,
            ssrc: 0xA1B2C3D4,
            name: 'Mac',
          ).encode(),
          bytes(invitationHex),
        );
      });

      test('omits the name of commands without one', () {
        expect(
          const MidiAppleMidiEndSession(token: 1, ssrc: 2).encode(),
          bytes('ff ff 42 59 00 00 00 02 00 00 00 01 00 00 00 02'),
        );
      });

      test('round-trips every command', () {
        final commands = <MidiAppleMidiCommand>[
          const MidiAppleMidiInvitation(token: 1, ssrc: 2, name: 'Initiator'),
          const MidiAppleMidiInvitationAccepted(
            token: 1,
            ssrc: 3,
            name: 'Responder',
          ),
          const MidiAppleMidiInvitationRejected(token: 1, ssrc: 3),
          const MidiAppleMidiEndSession(token: 1, ssrc: 2),
          MidiAppleMidiSync(ssrc: 2, count: 1, timestamps: const [10, 20, 0]),
          const MidiAppleMidiReceiverFeedback(ssrc: 3, sequenceNumber: 65535),
          const MidiAppleMidiBitrateLimit(ssrc: 3, limit: 1000000),
        ];
        expect([
          for (final c in commands) MidiAppleMidiCommand.decode(c.encode()),
        ], equals(commands));
      });

      test('keeps the low 16 bits of the RS sequence number', () {
        expect(
          const MidiAppleMidiReceiverFeedback(
            ssrc: 1,
            sequenceNumber: 0x12345,
          ).encode().sublist(8),
          bytes('23 45 00 00'),
        );
      });
    });

    group('isCommand(data)', () {
      test('accepts the signature and rejects RTP', () {
        expect(MidiAppleMidiCommand.isCommand(bytes(invitationHex)), isTrue);
        expect(MidiAppleMidiCommand.isCommand(bytes('80 61 00 01')), isFalse);
        expect(MidiAppleMidiCommand.isCommand(bytes('ff 00 49 4e')), isFalse);
        expect(MidiAppleMidiCommand.isCommand(bytes('ff ff')), isFalse);
      });
    });

    group('constants', () {
      test('match the protocol', () {
        expect(MidiAppleMidiCommand.signature, 0xFFFF);
        expect(MidiAppleMidiCommand.protocolVersion, 2);
      });
    });
  });

  group('MidiAppleMidiSessionCommand', () {
    group('==, hashCode, toString', () {
      test('compare all fields and the type', () {
        const a = MidiAppleMidiInvitation(token: 1, ssrc: 2, name: 'A');
        final variants = <Object>[
          const MidiAppleMidiInvitation(token: 9, ssrc: 2, name: 'A'),
          const MidiAppleMidiInvitation(token: 1, ssrc: 9, name: 'A'),
          const MidiAppleMidiInvitation(token: 1, ssrc: 2, name: 'B'),
          const MidiAppleMidiInvitation(
            token: 1,
            ssrc: 2,
            name: 'A',
            version: 9,
          ),
          const MidiAppleMidiInvitationAccepted(token: 1, ssrc: 2, name: 'A'),
          'IN',
        ];
        for (final variant in variants) {
          expect(a == variant, isFalse, reason: '$variant');
        }
        final same = MidiAppleMidiInvitation(
          token: int.parse('1'),
          ssrc: 2,
          name: 'A',
        );
        expect(a == same, isTrue);
        expect(a == a, isTrue);
        expect(a.hashCode, same.hashCode);
        expect(
          a.toString(),
          "MidiAppleMidiInvitation(token: 1, ssrc: 2, name: 'A', "
          'version: 2)',
        );
      });
    });
  });

  group('MidiAppleMidiSync', () {
    group('==, hashCode, toString', () {
      test('compare all fields', () {
        final a = MidiAppleMidiSync(
          ssrc: 1,
          count: 1,
          timestamps: const [1, 2, 0],
        );
        final variants = <Object>[
          MidiAppleMidiSync(ssrc: 9, count: 1, timestamps: const [1, 2, 0]),
          MidiAppleMidiSync(ssrc: 1, count: 2, timestamps: const [1, 2, 0]),
          MidiAppleMidiSync(ssrc: 1, count: 1, timestamps: const [9, 2, 0]),
          MidiAppleMidiSync(ssrc: 1, count: 1, timestamps: const [1, 9, 0]),
          MidiAppleMidiSync(ssrc: 1, count: 1, timestamps: const [1, 2, 9]),
          'CK',
        ];
        for (final variant in variants) {
          expect(a == variant, isFalse, reason: '$variant');
        }
        final same = MidiAppleMidiSync(
          ssrc: 1,
          count: 1,
          timestamps: const [1, 2, 0],
        );
        expect(a == same, isTrue);
        expect(a == a, isTrue);
        expect(a.hashCode, same.hashCode);
        expect(
          a.toString(),
          'MidiAppleMidiSync(ssrc: 1, count: 1, timestamps: [1, 2, 0])',
        );
      });

      test('keeps an unmodifiable copy of the timestamps', () {
        final source = [1, 2, 3];
        final sync = MidiAppleMidiSync(ssrc: 1, count: 2, timestamps: source);
        source[0] = 9;
        expect(sync.timestamps, equals([1, 2, 3]));
        expect(() => sync.timestamps[0] = 5, throwsUnsupportedError);
      });
    });
  });

  group('MidiAppleMidiReceiverFeedback', () {
    group('==, hashCode, toString', () {
      test('compare all fields', () {
        const a = MidiAppleMidiReceiverFeedback(ssrc: 1, sequenceNumber: 2);
        expect(
          a == const MidiAppleMidiReceiverFeedback(ssrc: 9, sequenceNumber: 2),
          isFalse,
        );
        expect(
          a == const MidiAppleMidiReceiverFeedback(ssrc: 1, sequenceNumber: 9),
          isFalse,
        );
        expect(a == other, isFalse);
        final same = MidiAppleMidiReceiverFeedback(
          ssrc: int.parse('1'),
          sequenceNumber: 2,
        );
        expect(a == same, isTrue);
        expect(a == a, isTrue);
        expect(a.hashCode, same.hashCode);
        expect(
          a.toString(),
          'MidiAppleMidiReceiverFeedback(ssrc: 1, sequenceNumber: 2)',
        );
      });
    });
  });

  group('MidiAppleMidiBitrateLimit', () {
    group('==, hashCode, toString', () {
      test('compare all fields', () {
        const a = MidiAppleMidiBitrateLimit(ssrc: 1, limit: 2);
        expect(
          a == const MidiAppleMidiBitrateLimit(ssrc: 9, limit: 2),
          isFalse,
        );
        expect(
          a == const MidiAppleMidiBitrateLimit(ssrc: 1, limit: 9),
          isFalse,
        );
        expect(a == other, isFalse);
        final same = MidiAppleMidiBitrateLimit(ssrc: int.parse('1'), limit: 2);
        expect(a == same, isTrue);
        expect(a == a, isTrue);
        expect(a.hashCode, same.hashCode);
        expect(a.toString(), 'MidiAppleMidiBitrateLimit(ssrc: 1, limit: 2)');
      });
    });
  });
}
