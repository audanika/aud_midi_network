// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:typed_data';

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

  final digest = List.generate(32, (i) => i);
  final nonce = List.generate(16, (i) => 0xA0 + i);

  group('MidiNetworkMidi2Invitation', () {
    test('encodes name length and capabilities into the header', () {
      const invitation = MidiNetworkMidi2Invitation(
        endpointName: 'Dart',
        productInstanceId: 'P1',
        capabilities:
            MidiNetworkMidi2Invitation.capabilityAuthentication |
            MidiNetworkMidi2Invitation.capabilityUserAuthentication,
      );
      expect(hex(invitation.encode()), '01 02 01 03 44 61 72 74 50 31 00 00');
      expect(invitation.code, MidiNetworkMidi2Invitation.commandCode);
      expect(invitation.commandSpecificData, 0x0103);
      expect(roundTrip(invitation), equals([invitation]));
      expect(invitation.toString(), 'MidiNetworkMidi2Invitation(Dart, P1, 3)');
    });

    test('rejects a name longer than the payload', () {
      expect(
        decodeRaw([0x01, 0x01, 0x02, 0x00, 0x41, 0x42, 0x43, 0x44]),
        const MidiNetworkMidi2InvalidCommand(
          header: 0x01010200,
          reason: 'The name exceeds the payload',
        ),
      );
    });

    test('has the constants of the specification', () {
      expect(MidiNetworkMidi2Invitation.commandCode, 0x01);
      expect(MidiNetworkMidi2Invitation.capabilityAuthentication, 0x01);
      expect(MidiNetworkMidi2Invitation.capabilityUserAuthentication, 0x02);
    });
  });

  group('MidiNetworkMidi2InvitationWithAuthentication', () {
    test('carries the digest', () {
      final command = MidiNetworkMidi2InvitationWithAuthentication(
        digest: digest,
      );
      expect(command.encode().sublist(0, 4), [0x02, 0x08, 0x00, 0x00]);
      expect(command.code, 0x02);
      expect(command.digest, equals(digest));
      expect(roundTrip(command), equals([command]));
      expect(() => command.digest[0] = 1, throwsUnsupportedError);
    });

    test('rejects a short digest', () {
      expect(
        decodeRaw([0x02, 0x01, 0x00, 0x00, 1, 2, 3, 4]),
        const MidiNetworkMidi2InvalidCommand(
          header: 0x02010000,
          reason: 'The digest needs 32 bytes',
        ),
      );
    });
  });

  group('MidiNetworkMidi2InvitationWithUserAuthentication', () {
    test('carries the digest and the user name', () {
      final command = MidiNetworkMidi2InvitationWithUserAuthentication(
        digest: digest,
        userName: 'Rosa',
      );
      expect(command.encode().sublist(0, 4), [0x03, 0x09, 0x00, 0x00]);
      expect(
        command.code,
        MidiNetworkMidi2InvitationWithUserAuthentication.commandCode,
      );
      expect(command.userName, 'Rosa');
      expect(roundTrip(command), equals([command]));
    });

    test('rejects a short digest', () {
      expect(
        decodeRaw([0x03, 0x00, 0x00, 0x00]),
        const MidiNetworkMidi2InvalidCommand(
          header: 0x03000000,
          reason: 'The digest needs 32 bytes',
        ),
      );
    });
  });

  group('MidiNetworkMidi2InvitationAccepted', () {
    test('carries the host identity', () {
      const reply = MidiNetworkMidi2InvitationAccepted(
        endpointName: 'Host Name',
        productInstanceId: 'ID',
      );
      expect(
        hex(reply.encode()),
        '10 04 03 00 48 6f 73 74 20 4e 61 6d 65 00 00 00 49 44 00 00',
      );
      expect(reply.code, 0x10);
      expect(roundTrip(reply), equals([reply]));
      expect(
        reply.toString(),
        'MidiNetworkMidi2InvitationAccepted(Host Name, ID)',
      );
    });
  });

  group('MidiNetworkMidi2InvitationPending', () {
    test('carries the host identity', () {
      const reply = MidiNetworkMidi2InvitationPending(
        endpointName: 'Host',
        productInstanceId: 'ID',
      );
      expect(reply.code, MidiNetworkMidi2InvitationPending.commandCode);
      expect(reply.commandSpecificData, 0x0100);
      expect(roundTrip(reply), equals([reply]));
      expect(
        reply ==
            const MidiNetworkMidi2InvitationAccepted(
              endpointName: 'Host',
              productInstanceId: 'ID',
            ),
        isFalse,
      );
    });
  });

  group('MidiNetworkMidi2AuthenticationRequired', () {
    test('puts the nonce before the identity', () {
      final reply = MidiNetworkMidi2AuthenticationRequired(
        endpointName: 'Host',
        productInstanceId: 'ID',
        nonce: nonce,
        authenticationState:
            MidiNetworkMidi2AuthenticationRequired.incorrectDigest,
      );
      final encoded = reply.encode();
      expect(hex(encoded.sublist(0, 4)), '12 06 01 01');
      expect(encoded.sublist(4, 20), equals(nonce));
      expect(reply.code, MidiNetworkMidi2AuthenticationRequired.commandCode);
      expect(roundTrip(reply), equals([reply]));
      expect(() => reply.nonce[0] = 0, throwsUnsupportedError);
    });

    test('rejects a payload too short for the nonce', () {
      expect(
        decodeRaw([0x12, 0x01, 0x00, 0x00, 1, 2, 3, 4]),
        const MidiNetworkMidi2InvalidCommand(
          header: 0x12010000,
          reason: 'The name exceeds the payload',
        ),
      );
    });

    test('has the constants of the specification', () {
      expect(MidiNetworkMidi2AuthenticationRequired.commandCode, 0x12);
      expect(MidiNetworkMidi2AuthenticationRequired.firstRequest, 0);
      expect(MidiNetworkMidi2AuthenticationRequired.incorrectDigest, 1);
    });
  });

  group('MidiNetworkMidi2UserAuthenticationRequired', () {
    test('differs from the shared secret challenge by its code only', () {
      final reply = MidiNetworkMidi2UserAuthenticationRequired(
        endpointName: 'Host',
        productInstanceId: 'ID',
        nonce: nonce,
      );
      expect(reply.code, 0x13);
      expect(reply.commandSpecificData, 0x0100);
      expect(roundTrip(reply), equals([reply]));
      expect(
        reply ==
            MidiNetworkMidi2AuthenticationRequired(
              endpointName: 'Host',
              productInstanceId: 'ID',
              nonce: nonce,
            ),
        isFalse,
      );
      expect(MidiNetworkMidi2UserAuthenticationRequired.commandCode, 0x13);
    });
  });

  group('MidiNetworkMidi2InvitationReply', () {
    test('accepts an empty identity', () {
      const reply = MidiNetworkMidi2InvitationAccepted(
        endpointName: '',
        productInstanceId: '',
      );
      expect(reply.encode(), Uint8List.fromList([0x10, 0, 0, 0]));
      expect(roundTrip(reply), equals([reply]));
    });
  });
}
