// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

part of 'midi_network_midi2_command.dart';

// #############################################################################
/// Session Ping (0x20): checks that the remote is alive and measures the
/// round trip.
final class MidiNetworkMidi2Ping extends MidiNetworkMidi2Command {
  /// Creates a ping with the 32-bit [pingId].
  const MidiNetworkMidi2Ping({required this.pingId});

  // ...........................................................................
  /// The identifier the reply repeats.
  final int pingId;

  @override
  int get code => commandCode;

  // ...........................................................................
  /// The command code, 0x20.
  static const int commandCode = 0x20;

  // ...........................................................................
  @override
  Uint8List _encodePayload() => MidiNetworkMidi2Command._wordBytes(pingId);

  @override
  List<Object?> get _fields => [pingId];
}

// #############################################################################
/// Session Ping Reply (0x21): answers a ping.
final class MidiNetworkMidi2PingReply extends MidiNetworkMidi2Command {
  /// Creates the reply to the ping [pingId].
  const MidiNetworkMidi2PingReply({required this.pingId});

  // ...........................................................................
  /// The identifier of the ping.
  final int pingId;

  @override
  int get code => commandCode;

  // ...........................................................................
  /// The command code, 0x21.
  static const int commandCode = 0x21;

  // ...........................................................................
  @override
  Uint8List _encodePayload() => MidiNetworkMidi2Command._wordBytes(pingId);

  @override
  List<Object?> get _fields => [pingId];
}

// #############################################################################
/// Session Reset (0x82): both sides start their sequence numbers at 0
/// again.
final class MidiNetworkMidi2SessionReset extends MidiNetworkMidi2Command {
  /// Creates the reset.
  const MidiNetworkMidi2SessionReset();

  // ...........................................................................
  @override
  int get code => commandCode;

  // ...........................................................................
  /// The command code, 0x82.
  static const int commandCode = 0x82;
}

// #############################################################################
/// Session Reset Reply (0x83): confirms a reset.
final class MidiNetworkMidi2SessionResetReply extends MidiNetworkMidi2Command {
  /// Creates the reply.
  const MidiNetworkMidi2SessionResetReply();

  // ...........................................................................
  @override
  int get code => commandCode;

  // ...........................................................................
  /// The command code, 0x83.
  static const int commandCode = 0x83;
}

// #############################################################################
/// NAK (0x8F): refuses a command.
final class MidiNetworkMidi2Nak extends MidiNetworkMidi2Command {
  /// Creates the refusal of the command with [originalHeader].
  ///
  /// - [reason] one of the `reason…` constants.
  /// - [message] an optional text for humans.
  const MidiNetworkMidi2Nak({
    required this.reason,
    required this.originalHeader,
    this.message = '',
  });

  // ...........................................................................
  /// Why the command was refused.
  final int reason;

  /// The header word of the refused command.
  final int originalHeader;

  /// A text for humans; may be empty.
  final String message;

  @override
  int get code => commandCode;

  @override
  int get commandSpecificData => (reason & 0xFF) << 8;

  // ...........................................................................
  /// The command code, 0x8F.
  static const int commandCode = 0x8F;

  /// The reason when no other one fits.
  static const int reasonOther = 0x00;

  /// The reason for a command the receiver does not implement.
  static const int reasonCommandNotSupported = 0x01;

  /// The reason for a command that makes no sense in the current state.
  static const int reasonCommandNotExpected = 0x02;

  /// The reason for a command that cannot be decoded.
  static const int reasonCommandMalformed = 0x03;

  /// The reason for a ping reply without a matching ping.
  static const int reasonBadPingReply = 0x20;

  // ...........................................................................
  @override
  Uint8List _encodePayload() => Uint8List.fromList([
    ...MidiNetworkMidi2Command._wordBytes(originalHeader),
    ...MidiNetworkMidi2Command._padded(message, _maxMessageBytes),
  ]);

  @override
  List<Object?> get _fields => [reason, originalHeader, message];

  // The payload holds at most 255 words, one of them the header.
  static const int _maxMessageBytes = 1016;
}

// #############################################################################
/// Bye (0xF0): ends a session or refuses an invitation.
final class MidiNetworkMidi2Bye extends MidiNetworkMidi2Command {
  /// Creates the end of a session.
  ///
  /// - [reason] one of the `reason…` constants.
  /// - [message] an optional text for humans.
  const MidiNetworkMidi2Bye({required this.reason, this.message = ''});

  // ...........................................................................
  /// Why the session ends.
  final int reason;

  /// A text for humans; may be empty.
  final String message;

  @override
  int get code => commandCode;

  @override
  int get commandSpecificData => (reason & 0xFF) << 8;

  // ...........................................................................
  /// The command code, 0xF0.
  static const int commandCode = 0xF0;

  /// No reason given.
  static const int reasonUndefined = 0x00;

  /// The user ended the session.
  static const int reasonUserTerminated = 0x01;

  /// The device powers down.
  static const int reasonPowerDown = 0x02;

  /// Too many UMP Data commands went missing.
  static const int reasonTooManyMissingUmps = 0x03;

  /// The remote stopped answering.
  static const int reasonTimeout = 0x04;

  /// A command arrived for a session that does not exist.
  static const int reasonSessionNotEstablished = 0x05;

  /// A reply arrived for an invitation that is not pending.
  static const int reasonNoPendingSession = 0x06;

  /// The remote violated the protocol.
  static const int reasonProtocolError = 0x07;

  /// The host cannot open another session.
  static const int reasonTooManyOpenSessions = 0x40;

  /// An authenticated invitation arrived without a challenge before it.
  static const int reasonMissingPriorInvitation = 0x41;

  /// The host did not accept the client.
  static const int reasonUserDidNotAccept = 0x42;

  /// The digest was wrong.
  static const int reasonAuthenticationFailed = 0x43;

  /// The user name is unknown.
  static const int reasonUserNameNotFound = 0x44;

  /// The client supports none of the host's authentication methods.
  static const int reasonNoMatchingAuthenticationMethod = 0x45;

  /// The client gave up its invitation.
  static const int reasonInvitationCanceled = 0x80;

  // ...........................................................................
  @override
  Uint8List _encodePayload() =>
      MidiNetworkMidi2Command._padded(message, _maxMessageBytes);

  @override
  List<Object?> get _fields => [reason, message];

  // The payload holds at most 255 words.
  static const int _maxMessageBytes = 1020;
}

// #############################################################################
/// Bye Reply (0xF1): confirms a bye.
final class MidiNetworkMidi2ByeReply extends MidiNetworkMidi2Command {
  /// Creates the reply.
  const MidiNetworkMidi2ByeReply();

  // ...........................................................................
  @override
  int get code => commandCode;

  // ...........................................................................
  /// The command code, 0xF1.
  static const int commandCode = 0xF1;
}

// #############################################################################
/// A command with a code this implementation does not know; receivers
/// answer it with a NAK.
final class MidiNetworkMidi2UnknownCommand extends MidiNetworkMidi2Command {
  /// Creates the command from a copy of [payload], whole words.
  MidiNetworkMidi2UnknownCommand({
    required this.code,
    this.commandSpecificData = 0,
    List<int> payload = const [],
  }) : payload = Uint8List.fromList(payload).asUnmodifiableView();

  // ...........................................................................
  @override
  final int code;

  @override
  final int commandSpecificData;

  /// The payload; cannot be modified.
  final Uint8List payload;

  // ...........................................................................
  @override
  Uint8List _encodePayload() => MidiNetworkMidi2Command._pad(payload);

  @override
  List<Object?> get _fields => [code, commandSpecificData, payload];
}

// #############################################################################
/// A command packet that could not be decoded; receivers answer it with a
/// NAK.
final class MidiNetworkMidi2InvalidCommand extends MidiNetworkMidi2Command {
  /// Creates the command from its [header] word.
  const MidiNetworkMidi2InvalidCommand({
    required this.header,
    required this.reason,
  });

  // ...........................................................................
  @override
  final int header;

  /// Why the command could not be decoded.
  final String reason;

  @override
  int get code => header >> 24;

  @override
  int get commandSpecificData => header & 0xFFFF;

  // ...........................................................................
  @override
  List<Object?> get _fields => [header, reason];
}

// #############################################################################
MidiNetworkMidi2Command _decodeSessionCommand(
  int code,
  int csd,
  Uint8List payload,
) => switch (code) {
  MidiNetworkMidi2Ping.commandCode => MidiNetworkMidi2Ping(
    pingId: MidiNetworkMidi2Command._word(payload, 0),
  ),
  MidiNetworkMidi2PingReply.commandCode => MidiNetworkMidi2PingReply(
    pingId: MidiNetworkMidi2Command._word(payload, 0),
  ),
  MidiNetworkMidi2SessionReset.commandCode =>
    const MidiNetworkMidi2SessionReset(),
  MidiNetworkMidi2SessionResetReply.commandCode =>
    const MidiNetworkMidi2SessionResetReply(),
  MidiNetworkMidi2Nak.commandCode => MidiNetworkMidi2Nak(
    reason: csd >> 8,
    originalHeader: MidiNetworkMidi2Command._word(payload, 0),
    message: MidiNetworkMidi2Command._string(Uint8List.sublistView(payload, 4)),
  ),
  MidiNetworkMidi2Bye.commandCode => MidiNetworkMidi2Bye(
    reason: csd >> 8,
    message: MidiNetworkMidi2Command._string(payload),
  ),
  MidiNetworkMidi2ByeReply.commandCode => const MidiNetworkMidi2ByeReply(),
  _ => MidiNetworkMidi2UnknownCommand(
    code: code,
    commandSpecificData: csd,
    payload: payload,
  ),
};
