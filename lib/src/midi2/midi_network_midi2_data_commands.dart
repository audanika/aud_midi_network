// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

part of 'midi_network_midi2_command.dart';

// #############################################################################
/// UMP Data (0xFF): complete Universal MIDI Packets with a 16-bit sequence
/// number; without words it is a keep-alive that still advances the
/// sequence.
final class MidiNetworkMidi2UmpData extends MidiNetworkMidi2Command {
  /// Creates the command from a copy of [words], which must form complete
  /// packets of at most [maxWords] words in total.
  MidiNetworkMidi2UmpData({
    required this.sequenceNumber,
    Iterable<int> words = const [],
  }) : words = Uint32List.fromList(words.toList()).asUnmodifiableView() {
    assert(this.words.length <= maxWords);
  }

  // ...........................................................................
  /// The sequence number of the command.
  final int sequenceNumber;

  /// The words of the packets; cannot be modified.
  final Uint32List words;

  @override
  int get code => commandCode;

  @override
  int get commandSpecificData => sequenceNumber & 0xFFFF;

  // ...........................................................................
  /// The command code, 0xFF.
  static const int commandCode = 0xFF;

  /// The most words one command carries.
  static const int maxWords = 64;

  // ...........................................................................
  @override
  Uint8List _encodePayload() {
    final result = Uint8List(words.length * 4);
    final view = ByteData.sublistView(result);
    for (var i = 0; i < words.length; i++) {
      view.setUint32(4 * i, words[i]);
    }
    return result;
  }

  @override
  List<Object?> get _fields => [sequenceNumber, words];
}

// #############################################################################
/// Retransmit Request (0x80): asks for UMP Data commands again.
final class MidiNetworkMidi2RetransmitRequest extends MidiNetworkMidi2Command {
  /// Creates a request for [count] commands from [sequenceNumber] on; a
  /// count of 0 asks for all commands up to the latest.
  const MidiNetworkMidi2RetransmitRequest({
    required this.sequenceNumber,
    required this.count,
  });

  // ...........................................................................
  /// The sequence number of the first command requested.
  final int sequenceNumber;

  /// The number of commands requested; 0 for all up to the latest.
  final int count;

  @override
  int get code => commandCode;

  @override
  int get commandSpecificData => sequenceNumber & 0xFFFF;

  // ...........................................................................
  /// The command code, 0x80.
  static const int commandCode = 0x80;

  // ...........................................................................
  @override
  Uint8List _encodePayload() =>
      MidiNetworkMidi2Command._wordBytes((count & 0xFFFF) << 16);

  @override
  List<Object?> get _fields => [sequenceNumber, count];
}

// #############################################################################
/// Retransmit Error (0x81): the requested commands cannot be sent again.
final class MidiNetworkMidi2RetransmitError extends MidiNetworkMidi2Command {
  /// Creates the error.
  ///
  /// - [reason] [reasonUnknown] or [reasonDataNotAvailable].
  /// - [sequenceNumber] the first sequence number the sender still holds.
  const MidiNetworkMidi2RetransmitError({
    required this.reason,
    required this.sequenceNumber,
  });

  // ...........................................................................
  /// Why the commands cannot be sent.
  final int reason;

  /// The first sequence number the sender still holds.
  final int sequenceNumber;

  @override
  int get code => commandCode;

  @override
  int get commandSpecificData => (reason & 0xFF) << 8;

  // ...........................................................................
  /// The command code, 0x81.
  static const int commandCode = 0x81;

  /// The reason when no other one fits.
  static const int reasonUnknown = 0x00;

  /// The reason when the commands left the retransmit buffer.
  static const int reasonDataNotAvailable = 0x01;

  // ...........................................................................
  @override
  Uint8List _encodePayload() =>
      MidiNetworkMidi2Command._wordBytes((sequenceNumber & 0xFFFF) << 16);

  @override
  List<Object?> get _fields => [reason, sequenceNumber];
}

// #############################################################################
MidiNetworkMidi2Command _decodeDataCommand(
  int code,
  int csd,
  Uint8List payload,
) {
  if (code == MidiNetworkMidi2RetransmitRequest.commandCode) {
    return MidiNetworkMidi2RetransmitRequest(
      sequenceNumber: csd,
      count: MidiNetworkMidi2Command._word(payload, 0) >> 16,
    );
  }
  if (code == MidiNetworkMidi2RetransmitError.commandCode) {
    return MidiNetworkMidi2RetransmitError(
      reason: csd >> 8,
      sequenceNumber: MidiNetworkMidi2Command._word(payload, 0) >> 16,
    );
  }
  final view = ByteData.sublistView(payload);
  final words = [
    for (var i = 0; i < payload.length ~/ 4; i++) view.getUint32(4 * i),
  ];
  var size = 0;
  while (size < words.length) {
    size += Ump.sizeOf(words[size]);
  }
  if (size != words.length || size > MidiNetworkMidi2UmpData.maxWords) {
    throw const FormatException('The words are no complete packets');
  }
  return MidiNetworkMidi2UmpData(sequenceNumber: csd, words: words);
}
