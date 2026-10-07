// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:typed_data';

// #############################################################################
/// A command of the AppleMIDI session protocol, the session layer Apple's
/// network MIDI driver puts on top of RTP-MIDI (RFC 6295).
///
/// Every command starts with the signature 0xFFFF and two ASCII letters.
/// IN, OK, NO and BY carry the protocol version, the initiator token, the
/// SSRC and the name of the sender; CK carries three 64-bit timestamps in
/// units of 100 microseconds, RS the last received RTP sequence number and
/// RL a bit rate limit. All fields are big-endian.
sealed class MidiAppleMidiCommand {
  /// Creates a command sent by the participant with [ssrc].
  const MidiAppleMidiCommand({required this.ssrc});

  // ...........................................................................
  /// Decodes the command in [data].
  ///
  /// Throws a [FormatException] when [data] does not start with the
  /// signature, names an unknown command or is too short for it.
  factory MidiAppleMidiCommand.decode(List<int> data) {
    if (!isCommand(data)) {
      throw const FormatException('Not an AppleMIDI command');
    }
    final bytes = ByteData.sublistView(Uint8List.fromList(data));
    final code = bytes.getUint16(2);
    if (code == MidiAppleMidiSync.code) {
      return MidiAppleMidiSync._decode(bytes);
    }
    if (code == MidiAppleMidiReceiverFeedback.code ||
        code == MidiAppleMidiBitrateLimit.code) {
      return _decodeFeedback(bytes, code);
    }
    return MidiAppleMidiSessionCommand._decode(bytes, code);
  }

  // ...........................................................................
  /// Returns the command as a datagram.
  Uint8List encode();

  // ...........................................................................
  /// The SSRC of the sender, the identifier of its RTP stream.
  final int ssrc;

  // ...........................................................................
  /// Returns whether [data] starts with the AppleMIDI signature and a
  /// command code; RTP packets never do.
  static bool isCommand(List<int> data) =>
      data.length >= 4 && data[0] == 0xFF && data[1] == 0xFF;

  /// The signature that starts every command.
  static const int signature = 0xFFFF;

  /// The protocol version Apple's driver sends and expects.
  static const int protocolVersion = 2;

  // ...........................................................................
  static MidiAppleMidiCommand _decodeFeedback(ByteData bytes, int code) {
    _require(bytes, 12, code);
    final ssrc = bytes.getUint32(4);
    final value = bytes.getUint32(8);
    return code == MidiAppleMidiReceiverFeedback.code
        ? MidiAppleMidiReceiverFeedback(ssrc: ssrc, sequenceNumber: value >> 16)
        : MidiAppleMidiBitrateLimit(ssrc: ssrc, limit: value);
  }

  static void _require(ByteData bytes, int length, int code) {
    if (bytes.lengthInBytes < length) {
      throw FormatException(
        'AppleMIDI command ${_name(code)} needs $length bytes, '
        'got ${bytes.lengthInBytes}',
      );
    }
  }

  static String _name(int code) =>
      String.fromCharCodes([code >> 8, code & 0xFF]);

  static Uint8List _header(int length, int code) {
    final result = Uint8List(length);
    ByteData.sublistView(result)
      ..setUint16(0, signature)
      ..setUint16(2, code);
    return result;
  }
}

// #############################################################################
/// The base of IN, OK, NO and BY: the commands that open and close a
/// session.
sealed class MidiAppleMidiSessionCommand extends MidiAppleMidiCommand {
  /// Creates a session command.
  ///
  /// - [token] the random number the initiator chose for the invitation;
  ///   answers repeat it.
  /// - [version] the protocol version, 2 for Apple's driver.
  const MidiAppleMidiSessionCommand({
    required this.token,
    required super.ssrc,
    this.name = '',
    this.version = MidiAppleMidiCommand.protocolVersion,
  });

  // ...........................................................................
  @override
  Uint8List encode() {
    final nameBytes = utf8.encode(name);
    final hasName = nameBytes.isNotEmpty;
    final result = MidiAppleMidiCommand._header(
      16 + (hasName ? nameBytes.length + 1 : 0),
      _code,
    );
    ByteData.sublistView(result)
      ..setUint32(4, version)
      ..setUint32(8, token)
      ..setUint32(12, ssrc);
    result.setRange(16, 16 + nameBytes.length, nameBytes);
    return result;
  }

  // ...........................................................................
  /// The random number the initiator chose for the invitation.
  final int token;

  /// The name of the sender; may be empty.
  final String name;

  /// The protocol version.
  final int version;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MidiAppleMidiSessionCommand &&
          other.runtimeType == runtimeType &&
          other.token == token &&
          other.ssrc == ssrc &&
          other.name == name &&
          other.version == version;

  @override
  int get hashCode => Object.hash(runtimeType, token, ssrc, name, version);

  @override
  String toString() =>
      '$runtimeType(token: $token, ssrc: $ssrc, name: \'$name\', '
      'version: $version)';

  // ...........................................................................
  int get _code;

  static MidiAppleMidiSessionCommand _decode(ByteData bytes, int code) {
    if (!_codes.contains(code)) {
      throw FormatException(
        'Unknown AppleMIDI command ${MidiAppleMidiCommand._name(code)}',
      );
    }
    MidiAppleMidiCommand._require(bytes, 16, code);
    final version = bytes.getUint32(4);
    final token = bytes.getUint32(8);
    final ssrc = bytes.getUint32(12);
    final name = _decodeName(bytes);
    return switch (code) {
      MidiAppleMidiInvitation.code => MidiAppleMidiInvitation(
        token: token,
        ssrc: ssrc,
        name: name,
        version: version,
      ),
      MidiAppleMidiInvitationAccepted.code => MidiAppleMidiInvitationAccepted(
        token: token,
        ssrc: ssrc,
        name: name,
        version: version,
      ),
      MidiAppleMidiInvitationRejected.code => MidiAppleMidiInvitationRejected(
        token: token,
        ssrc: ssrc,
        name: name,
        version: version,
      ),
      _ => MidiAppleMidiEndSession(
        token: token,
        ssrc: ssrc,
        name: name,
        version: version,
      ),
    };
  }

  static String _decodeName(ByteData bytes) {
    final raw = Uint8List.sublistView(bytes, 16);
    final end = raw.indexOf(0);
    return utf8.decode(
      end < 0 ? raw : raw.sublist(0, end),
      allowMalformed: true,
    );
  }

  static const _codes = {
    MidiAppleMidiInvitation.code,
    MidiAppleMidiInvitationAccepted.code,
    MidiAppleMidiInvitationRejected.code,
    MidiAppleMidiEndSession.code,
  };
}

// #############################################################################
/// IN: invites the receiver into a session; sent by the initiator first to
/// the control port, then to the data port.
final class MidiAppleMidiInvitation extends MidiAppleMidiSessionCommand {
  /// Creates an invitation.
  const MidiAppleMidiInvitation({
    required super.token,
    required super.ssrc,
    super.name,
    super.version,
  });

  // ...........................................................................
  /// The command code, ASCII `IN`.
  static const int code = 0x494E;

  @override
  int get _code => code;
}

// #############################################################################
/// OK: accepts an invitation; repeats the initiator token.
final class MidiAppleMidiInvitationAccepted
    extends MidiAppleMidiSessionCommand {
  /// Creates an acceptance.
  const MidiAppleMidiInvitationAccepted({
    required super.token,
    required super.ssrc,
    super.name,
    super.version,
  });

  // ...........................................................................
  /// The command code, ASCII `OK`.
  static const int code = 0x4F4B;

  @override
  int get _code => code;
}

// #############################################################################
/// NO: rejects an invitation; repeats the initiator token.
final class MidiAppleMidiInvitationRejected
    extends MidiAppleMidiSessionCommand {
  /// Creates a rejection.
  const MidiAppleMidiInvitationRejected({
    required super.token,
    required super.ssrc,
    super.name,
    super.version,
  });

  // ...........................................................................
  /// The command code, ASCII `NO`.
  static const int code = 0x4E4F;

  @override
  int get _code => code;
}

// #############################################################################
/// BY: ends the session; either participant may send it.
final class MidiAppleMidiEndSession extends MidiAppleMidiSessionCommand {
  /// Creates an end of session.
  const MidiAppleMidiEndSession({
    required super.token,
    required super.ssrc,
    super.name,
    super.version,
  });

  // ...........................................................................
  /// The command code, ASCII `BY`.
  static const int code = 0x4259;

  @override
  int get _code => code;
}

// #############################################################################
/// CK: one step of the three-way clock synchronisation.
///
/// The initiator sends count 0 with its time in [timestamps] 1, the
/// responder answers count 1 adding its time as timestamp 2, the initiator
/// finishes with count 2 adding timestamp 3. Times are 64-bit values of
/// the sender's session clock in units of 100 microseconds.
final class MidiAppleMidiSync extends MidiAppleMidiCommand {
  /// Creates a synchronisation step from a copy of [timestamps], which
  /// needs three entries.
  MidiAppleMidiSync({
    required super.ssrc,
    required this.count,
    required List<int> timestamps,
  }) : assert(count >= 0 && count <= 2),
       assert(timestamps.length == 3),
       timestamps = List.unmodifiable(timestamps);

  factory MidiAppleMidiSync._decode(ByteData bytes) {
    MidiAppleMidiCommand._require(bytes, 36, code);
    final count = bytes.getUint8(8);
    if (count > 2) {
      throw FormatException('AppleMIDI CK count $count is out of range');
    }
    return MidiAppleMidiSync(
      ssrc: bytes.getUint32(4),
      count: count,
      timestamps: [for (var i = 0; i < 3; i++) bytes.getUint64(12 + 8 * i)],
    );
  }

  // ...........................................................................
  @override
  Uint8List encode() {
    final result = MidiAppleMidiCommand._header(36, code);
    final bytes = ByteData.sublistView(result)
      ..setUint32(4, ssrc)
      ..setUint8(8, count);
    for (var i = 0; i < 3; i++) {
      bytes.setUint64(12 + 8 * i, timestamps[i]);
    }
    return result;
  }

  // ...........................................................................
  /// The step of the exchange: 0, 1 or 2.
  final int count;

  /// The three timestamps; entries beyond [count] are zero.
  final List<int> timestamps;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MidiAppleMidiSync &&
          other.ssrc == ssrc &&
          other.count == count &&
          other.timestamps[0] == timestamps[0] &&
          other.timestamps[1] == timestamps[1] &&
          other.timestamps[2] == timestamps[2];

  @override
  int get hashCode => Object.hash(ssrc, count, Object.hashAll(timestamps));

  @override
  String toString() =>
      'MidiAppleMidiSync(ssrc: $ssrc, count: $count, '
      'timestamps: $timestamps)';

  // ...........................................................................
  /// The command code, ASCII `CK`.
  static const int code = 0x434B;
}

// #############################################################################
/// RS: tells the sender of RTP data up to which sequence number the
/// receiver got the stream, so the sender can shorten its recovery journal.
final class MidiAppleMidiReceiverFeedback extends MidiAppleMidiCommand {
  /// Creates a receiver feedback for the 16-bit RTP [sequenceNumber].
  const MidiAppleMidiReceiverFeedback({
    required super.ssrc,
    required this.sequenceNumber,
  });

  // ...........................................................................
  @override
  Uint8List encode() {
    final result = MidiAppleMidiCommand._header(12, code);
    ByteData.sublistView(result)
      ..setUint32(4, ssrc)
      ..setUint32(8, (sequenceNumber & 0xFFFF) << 16);
    return result;
  }

  // ...........................................................................
  /// The last RTP sequence number received; it travels in the upper half
  /// of a 32-bit field.
  final int sequenceNumber;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MidiAppleMidiReceiverFeedback &&
          other.ssrc == ssrc &&
          other.sequenceNumber == sequenceNumber;

  @override
  int get hashCode => Object.hash(ssrc, sequenceNumber);

  @override
  String toString() =>
      'MidiAppleMidiReceiverFeedback(ssrc: $ssrc, '
      'sequenceNumber: $sequenceNumber)';

  // ...........................................................................
  /// The command code, ASCII `RS`.
  static const int code = 0x5253;
}

// #############################################################################
/// RL: asks the sender to stay below a bit rate, e.g. for a gateway to a
/// MIDI 1.0 DIN cable.
final class MidiAppleMidiBitrateLimit extends MidiAppleMidiCommand {
  /// Creates a bit rate limit of [limit] bits per second.
  const MidiAppleMidiBitrateLimit({required super.ssrc, required this.limit});

  // ...........................................................................
  @override
  Uint8List encode() {
    final result = MidiAppleMidiCommand._header(12, code);
    ByteData.sublistView(result)
      ..setUint32(4, ssrc)
      ..setUint32(8, limit);
    return result;
  }

  // ...........................................................................
  /// The limit in bits per second.
  final int limit;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MidiAppleMidiBitrateLimit &&
          other.ssrc == ssrc &&
          other.limit == limit;

  @override
  int get hashCode => Object.hash(ssrc, limit);

  @override
  String toString() => 'MidiAppleMidiBitrateLimit(ssrc: $ssrc, limit: $limit)';

  // ...........................................................................
  /// The command code, ASCII `RL`.
  static const int code = 0x524C;
}
