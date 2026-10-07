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

  group('MidiNetworkMidi2Ping', () {
    test('carries the ping id', () {
      const ping = MidiNetworkMidi2Ping(pingId: 0xDEADBEEF);
      expect(hex(ping.encode()), '20 01 00 00 de ad be ef');
      expect(ping.code, MidiNetworkMidi2Ping.commandCode);
      expect(roundTrip(ping), equals([ping]));
      expect(MidiNetworkMidi2Ping.commandCode, 0x20);
    });

    test('rejects a missing ping id', () {
      expect(
        decodeRaw([0x20, 0x00, 0x00, 0x00]),
        const MidiNetworkMidi2InvalidCommand(
          header: 0x20000000,
          reason: 'The payload lacks word 1',
        ),
      );
    });
  });

  group('MidiNetworkMidi2PingReply', () {
    test('repeats the ping id', () {
      const reply = MidiNetworkMidi2PingReply(pingId: 5);
      expect(hex(reply.encode()), '21 01 00 00 00 00 00 05');
      expect(reply.code, MidiNetworkMidi2PingReply.commandCode);
      expect(roundTrip(reply), equals([reply]));
      expect(MidiNetworkMidi2PingReply.commandCode, 0x21);
    });
  });

  group('MidiNetworkMidi2SessionReset', () {
    test('has no payload', () {
      const reset = MidiNetworkMidi2SessionReset();
      expect(hex(reset.encode()), '82 00 00 00');
      expect(reset.code, MidiNetworkMidi2SessionReset.commandCode);
      expect(roundTrip(reset), equals([reset]));
      expect(MidiNetworkMidi2SessionReset.commandCode, 0x82);
    });
  });

  group('MidiNetworkMidi2SessionResetReply', () {
    test('has no payload', () {
      const reply = MidiNetworkMidi2SessionResetReply();
      expect(hex(reply.encode()), '83 00 00 00');
      expect(reply.code, MidiNetworkMidi2SessionResetReply.commandCode);
      expect(roundTrip(reply), equals([reply]));
      expect(MidiNetworkMidi2SessionResetReply.commandCode, 0x83);
    });
  });

  group('MidiNetworkMidi2Nak', () {
    test('carries the reason, the refused header and a message', () {
      const nak = MidiNetworkMidi2Nak(
        reason: MidiNetworkMidi2Nak.reasonCommandNotSupported,
        originalHeader: 0x55000000,
        message: 'No',
      );
      expect(hex(nak.encode()), '8f 02 01 00 55 00 00 00 4e 6f 00 00');
      expect(nak.code, MidiNetworkMidi2Nak.commandCode);
      expect(nak.commandSpecificData, 0x0100);
      expect(roundTrip(nak), equals([nak]));
    });

    test('truncates a long message', () {
      final nak = MidiNetworkMidi2Nak(
        reason: MidiNetworkMidi2Nak.reasonOther,
        originalHeader: 0,
        message: 'x' * 2000,
      );
      final decoded = roundTrip(nak).single as MidiNetworkMidi2Nak;
      expect(decoded.message, 'x' * 1016);
      expect(nak.encode()[1], 255);
    });

    test('rejects a missing header word', () {
      expect(
        decodeRaw([0x8F, 0x00, 0x03, 0x00]),
        const MidiNetworkMidi2InvalidCommand(
          header: 0x8F000300,
          reason: 'The payload lacks word 1',
        ),
      );
    });

    test('has the constants of the specification', () {
      expect(MidiNetworkMidi2Nak.commandCode, 0x8F);
      expect(MidiNetworkMidi2Nak.reasonOther, 0x00);
      expect(MidiNetworkMidi2Nak.reasonCommandNotSupported, 0x01);
      expect(MidiNetworkMidi2Nak.reasonCommandNotExpected, 0x02);
      expect(MidiNetworkMidi2Nak.reasonCommandMalformed, 0x03);
      expect(MidiNetworkMidi2Nak.reasonBadPingReply, 0x20);
    });
  });

  group('MidiNetworkMidi2Bye', () {
    test('carries the reason and a message', () {
      const bye = MidiNetworkMidi2Bye(
        reason: MidiNetworkMidi2Bye.reasonTimeout,
        message: 'Gone',
      );
      expect(hex(bye.encode()), 'f0 01 04 00 47 6f 6e 65');
      expect(bye.code, MidiNetworkMidi2Bye.commandCode);
      expect(bye.commandSpecificData, 0x0400);
      expect(roundTrip(bye), equals([bye]));
      expect(
        hex(const MidiNetworkMidi2Bye(reason: 0x40).encode()),
        'f0 00 40 00',
      );
    });

    test('truncates a long message', () {
      final bye = MidiNetworkMidi2Bye(reason: 0, message: 'y' * 2000);
      final decoded = roundTrip(bye).single as MidiNetworkMidi2Bye;
      expect(decoded.message, 'y' * 1020);
    });

    test('has the constants of the specification', () {
      expect(MidiNetworkMidi2Bye.commandCode, 0xF0);
      expect(
        [
          MidiNetworkMidi2Bye.reasonUndefined,
          MidiNetworkMidi2Bye.reasonUserTerminated,
          MidiNetworkMidi2Bye.reasonPowerDown,
          MidiNetworkMidi2Bye.reasonTooManyMissingUmps,
          MidiNetworkMidi2Bye.reasonTimeout,
          MidiNetworkMidi2Bye.reasonSessionNotEstablished,
          MidiNetworkMidi2Bye.reasonNoPendingSession,
          MidiNetworkMidi2Bye.reasonProtocolError,
          MidiNetworkMidi2Bye.reasonTooManyOpenSessions,
          MidiNetworkMidi2Bye.reasonMissingPriorInvitation,
          MidiNetworkMidi2Bye.reasonUserDidNotAccept,
          MidiNetworkMidi2Bye.reasonAuthenticationFailed,
          MidiNetworkMidi2Bye.reasonUserNameNotFound,
          MidiNetworkMidi2Bye.reasonNoMatchingAuthenticationMethod,
          MidiNetworkMidi2Bye.reasonInvitationCanceled,
        ],
        equals([
          0x00,
          0x01,
          0x02,
          0x03,
          0x04,
          0x05,
          0x06,
          0x07,
          0x40,
          0x41,
          0x42,
          0x43,
          0x44,
          0x45,
          0x80,
        ]),
      );
    });
  });

  group('MidiNetworkMidi2ByeReply', () {
    test('has no payload', () {
      const reply = MidiNetworkMidi2ByeReply();
      expect(hex(reply.encode()), 'f1 00 00 00');
      expect(reply.code, MidiNetworkMidi2ByeReply.commandCode);
      expect(roundTrip(reply), equals([reply]));
      expect(MidiNetworkMidi2ByeReply.commandCode, 0xF1);
    });
  });

  group('MidiNetworkMidi2UnknownCommand', () {
    test('keeps code, specific data and payload', () {
      final unknown = MidiNetworkMidi2UnknownCommand(
        code: 0x55,
        commandSpecificData: 0x0102,
        payload: const [1, 2, 3, 4],
      );
      expect(hex(unknown.encode()), '55 01 01 02 01 02 03 04');
      expect(unknown.header, 0x55010102);
      expect(roundTrip(unknown), equals([unknown]));
      expect(() => unknown.payload[0] = 9, throwsUnsupportedError);
      expect(MidiNetworkMidi2UnknownCommand(code: 0x56).payload, isEmpty);
    });
  });

  group('MidiNetworkMidi2InvalidCommand', () {
    test('keeps the header it was decoded from', () {
      const invalid = MidiNetworkMidi2InvalidCommand(
        header: 0x20030005,
        reason: 'Broken',
      );
      expect(invalid.code, 0x20);
      expect(invalid.commandSpecificData, 0x0005);
      expect(invalid.header, 0x20030005);
      expect(hex(invalid.encode()), '20 00 00 05');
      expect(
        invalid.toString(),
        'MidiNetworkMidi2InvalidCommand(537067525, Broken)',
      );
    });
  });
}
