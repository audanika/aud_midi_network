// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  String hex(List<int> data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  List<MidiNetworkMidi2Command> roundTrip(MidiNetworkMidi2Command command) =>
      MidiNetworkMidi2Command.decodePacket(
        MidiNetworkMidi2Command.encodePacket([command]),
      );

  MidiNetworkMidi2Command decodeRaw(List<int> commandPacket) =>
      MidiNetworkMidi2Command.decodePacket([
        ...MidiNetworkMidi2Command.signature,
        ...commandPacket,
      ]).single;

  group('MidiNetworkMidi2UmpData', () {
    test('carries complete packets with the sequence number', () {
      // A MIDI 2.0 Note On (two words) and a utility NOOP (one word).
      final data = MidiNetworkMidi2UmpData(
        sequenceNumber: 0x1234,
        words: const [0x40903C00, 0xC8000000, 0x00000000],
      );
      expect(
        hex(data.encode()),
        'ff 03 12 34 40 90 3c 00 c8 00 00 00 00 00 00 00',
      );
      expect(data.code, MidiNetworkMidi2UmpData.commandCode);
      expect(data.commandSpecificData, 0x1234);
      expect(roundTrip(data), equals([data]));
      expect(() => data.words[0] = 1, throwsUnsupportedError);
    });

    test('may carry no words as a keep-alive', () {
      final data = MidiNetworkMidi2UmpData(sequenceNumber: 0xFFFF);
      expect(hex(data.encode()), 'ff 00 ff ff');
      expect(roundTrip(data), equals([data]));
    });

    test('rejects incomplete packets', () {
      expect(
        decodeRaw([0xFF, 0x01, 0x00, 0x05, 0x40, 0x90, 0x3C, 0x00]),
        const MidiNetworkMidi2InvalidCommand(
          header: 0xFF010005,
          reason: 'The words are no complete packets',
        ),
      );
    });

    test('rejects more than 64 words', () {
      expect(
        decodeRaw([0xFF, 65, 0x00, 0x00, ...List.filled(65 * 4, 0)]),
        const MidiNetworkMidi2InvalidCommand(
          header: 0xFF410000,
          reason: 'The words are no complete packets',
        ),
      );
    });

    test('has the constants of the specification', () {
      expect(MidiNetworkMidi2UmpData.commandCode, 0xFF);
      expect(MidiNetworkMidi2UmpData.maxWords, 64);
    });
  });

  group('MidiNetworkMidi2RetransmitRequest', () {
    test('puts the sequence number into the header', () {
      const request = MidiNetworkMidi2RetransmitRequest(
        sequenceNumber: 0xABCD,
        count: 3,
      );
      expect(hex(request.encode()), '80 01 ab cd 00 03 00 00');
      expect(request.code, MidiNetworkMidi2RetransmitRequest.commandCode);
      expect(roundTrip(request), equals([request]));
      expect(request.toString(), 'MidiNetworkMidi2RetransmitRequest(43981, 3)');
    });

    test('rejects a missing payload', () {
      expect(
        decodeRaw([0x80, 0x00, 0x00, 0x01]),
        const MidiNetworkMidi2InvalidCommand(
          header: 0x80000001,
          reason: 'The payload lacks word 1',
        ),
      );
    });

    test('has the code of the specification', () {
      expect(MidiNetworkMidi2RetransmitRequest.commandCode, 0x80);
    });
  });

  group('MidiNetworkMidi2RetransmitError', () {
    test('puts the reason into the header', () {
      const error = MidiNetworkMidi2RetransmitError(
        reason: MidiNetworkMidi2RetransmitError.reasonDataNotAvailable,
        sequenceNumber: 0x0102,
      );
      expect(hex(error.encode()), '81 01 01 00 01 02 00 00');
      expect(error.code, MidiNetworkMidi2RetransmitError.commandCode);
      expect(error.commandSpecificData, 0x0100);
      expect(roundTrip(error), equals([error]));
    });

    test('has the constants of the specification', () {
      expect(MidiNetworkMidi2RetransmitError.commandCode, 0x81);
      expect(MidiNetworkMidi2RetransmitError.reasonUnknown, 0x00);
      expect(MidiNetworkMidi2RetransmitError.reasonDataNotAvailable, 0x01);
    });
  });
}
