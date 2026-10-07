// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:aud_midi_standard/aud_midi_standard.dart';

part 'midi_network_midi2_data_commands.dart';
part 'midi_network_midi2_invitation_commands.dart';
part 'midi_network_midi2_session_commands.dart';

// #############################################################################
/// A command packet of Network MIDI 2.0 (UDP), MIDI Association document
/// M2-124-UM.
///
/// A UDP packet starts with the signature `MIDI` and carries one or more
/// command packets. Each starts with a header word: the command code, the
/// payload length in 32-bit words and 16 bits of command specific data,
/// often used as two bytes. Strings are UTF-8, padded with zero bytes to
/// whole words. All fields are big-endian.
sealed class MidiNetworkMidi2Command {
  /// Creates a command.
  const MidiNetworkMidi2Command();

  // ...........................................................................
  /// Returns the command packet: the header word and the payload.
  Uint8List encode() {
    final payload = _encodePayload();
    final result = Uint8List(4 + payload.length);
    ByteData.sublistView(result)
      ..setUint8(0, code)
      ..setUint8(1, payload.length ~/ 4)
      ..setUint16(2, commandSpecificData);
    result.setRange(4, result.length, payload);
    return result;
  }

  // ...........................................................................
  /// The command code.
  int get code;

  /// The 16 bits of command specific data in the header.
  int get commandSpecificData => 0;

  /// The header word of the command packet.
  int get header => ByteData.sublistView(encode()).getUint32(0);

  // ...........................................................................
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MidiNetworkMidi2Command || other.runtimeType != runtimeType) {
      return false;
    }
    final a = _fields;
    final b = other._fields;
    for (var i = 0; i < a.length; i++) {
      if (!_equal(a[i], b[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    runtimeType,
    Object.hashAll([
      for (final field in _fields)
        field is List ? Object.hashAll(field) : field,
    ]),
  );

  @override
  String toString() => '$runtimeType(${_fields.join(', ')})';

  // ...........................................................................
  /// Returns whether [data] starts with the signature `MIDI`.
  static bool isPacket(List<int> data) =>
      data.length >= 4 &&
      data[0] == signature[0] &&
      data[1] == signature[1] &&
      data[2] == signature[2] &&
      data[3] == signature[3];

  /// Decodes the command packets of the UDP payload [data].
  ///
  /// A command packet that cannot be decoded becomes a
  /// [MidiNetworkMidi2InvalidCommand]; when its length does not fit the
  /// packet, decoding stops there. Throws a [FormatException] when [data]
  /// lacks the signature.
  static List<MidiNetworkMidi2Command> decodePacket(List<int> data) {
    if (!isPacket(data)) {
      throw const FormatException('Not a Network MIDI 2.0 packet');
    }
    final bytes = Uint8List.fromList(data);
    final view = ByteData.sublistView(bytes);
    final commands = <MidiNetworkMidi2Command>[];
    var offset = 4;
    while (offset + 4 <= bytes.length) {
      final header = view.getUint32(offset);
      final end = offset + 4 + ((header >> 16) & 0xFF) * 4;
      if (end > bytes.length) {
        commands.add(
          MidiNetworkMidi2InvalidCommand(
            header: header,
            reason: 'The payload exceeds the packet',
          ),
        );
        break;
      }
      final payload = Uint8List.sublistView(bytes, offset + 4, end);
      commands.add(_decode(header, payload));
      offset = end;
    }
    return commands;
  }

  /// Returns a UDP payload with the signature and the [commands].
  static Uint8List encodePacket(Iterable<MidiNetworkMidi2Command> commands) {
    final builder = BytesBuilder(copy: false)..add(signature);
    for (final command in commands) {
      builder.add(command.encode());
    }
    return builder.takeBytes();
  }

  /// The signature that starts every UDP packet, ASCII `MIDI`.
  static const List<int> signature = [0x4D, 0x49, 0x44, 0x49];

  /// The largest UDP payload a sender should produce, in bytes.
  static const int maxPacketBytes = 1400;

  /// The largest UMP Endpoint Name, in bytes.
  static const int maxEndpointNameBytes = 98;

  /// The largest Product Instance Id, in bytes.
  static const int maxProductInstanceIdBytes = 42;

  // ...........................................................................
  Uint8List _encodePayload() => Uint8List(0);

  List<Object?> get _fields => const [];

  static bool _equal(Object? a, Object? b) {
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return a == b;
  }

  static MidiNetworkMidi2Command _decode(int header, Uint8List payload) {
    final code = header >> 24;
    final csd = header & 0xFFFF;
    try {
      return switch (code) {
        MidiNetworkMidi2Invitation.commandCode ||
        MidiNetworkMidi2InvitationWithAuthentication.commandCode ||
        MidiNetworkMidi2InvitationWithUserAuthentication.commandCode ||
        MidiNetworkMidi2InvitationAccepted.commandCode ||
        MidiNetworkMidi2InvitationPending.commandCode ||
        MidiNetworkMidi2AuthenticationRequired.commandCode ||
        MidiNetworkMidi2UserAuthenticationRequired.commandCode =>
          _decodeInvitationCommand(code, csd, payload),
        MidiNetworkMidi2UmpData.commandCode ||
        MidiNetworkMidi2RetransmitRequest.commandCode ||
        MidiNetworkMidi2RetransmitError.commandCode => _decodeDataCommand(
          code,
          csd,
          payload,
        ),
        _ => _decodeSessionCommand(code, csd, payload),
      };
    } on FormatException catch (e) {
      return MidiNetworkMidi2InvalidCommand(header: header, reason: e.message);
    }
  }

  static int _word(Uint8List payload, int index) {
    if (payload.length < 4 * (index + 1)) {
      throw FormatException('The payload lacks word ${index + 1}');
    }
    return ByteData.sublistView(payload).getUint32(4 * index);
  }

  static String _string(Uint8List bytes) {
    final end = bytes.indexOf(0);
    return utf8.decode(
      end < 0 ? bytes : Uint8List.sublistView(bytes, 0, end),
      allowMalformed: true,
    );
  }

  static Uint8List _padded(String text, int maxBytes) {
    final bytes = utf8.encode(text);
    var end = min(bytes.length, maxBytes);
    while (end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return _pad(Uint8List.sublistView(bytes, 0, end));
  }

  static Uint8List _pad(List<int> bytes) {
    final result = Uint8List((bytes.length + 3) & ~3);
    result.setRange(0, bytes.length, bytes);
    return result;
  }

  static Uint8List _wordBytes(int value) {
    final result = Uint8List(4);
    ByteData.sublistView(result).setUint32(0, value);
    return result;
  }
}
