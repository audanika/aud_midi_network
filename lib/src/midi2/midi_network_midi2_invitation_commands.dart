// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

part of 'midi_network_midi2_command.dart';

// #############################################################################
/// Invitation (0x01): a client asks a host for a session.
final class MidiNetworkMidi2Invitation extends MidiNetworkMidi2Command {
  /// Creates an invitation.
  ///
  /// - [endpointName] the UMP Endpoint Name of the client.
  /// - [productInstanceId] the Product Instance Id of the client.
  /// - [capabilities] the authentication methods the client supports, a
  ///   combination of [capabilityAuthentication] and
  ///   [capabilityUserAuthentication].
  const MidiNetworkMidi2Invitation({
    required this.endpointName,
    required this.productInstanceId,
    this.capabilities = 0,
  });

  // ...........................................................................
  /// The UMP Endpoint Name of the client.
  final String endpointName;

  /// The Product Instance Id of the client.
  final String productInstanceId;

  /// The authentication methods the client supports.
  final int capabilities;

  @override
  int get code => commandCode;

  @override
  int get commandSpecificData =>
      (_identity.nameWords << 8) | (capabilities & 0xFF);

  // ...........................................................................
  /// The command code, 0x01.
  static const int commandCode = 0x01;

  /// The capability bit for Invitation with Authentication.
  static const int capabilityAuthentication = 0x01;

  /// The capability bit for Invitation with User Authentication.
  static const int capabilityUserAuthentication = 0x02;

  // ...........................................................................
  _Identity get _identity => _Identity(endpointName, productInstanceId);

  @override
  Uint8List _encodePayload() => _identity.encode();

  @override
  List<Object?> get _fields => [endpointName, productInstanceId, capabilities];
}

// #############################################################################
/// Invitation with Authentication (0x02): a client answers a challenge
/// with the digest of the nonce and the shared secret.
final class MidiNetworkMidi2InvitationWithAuthentication
    extends MidiNetworkMidi2Command {
  /// Creates the invitation from a copy of the 32-byte SHA-256 [digest].
  MidiNetworkMidi2InvitationWithAuthentication({required List<int> digest})
    : digest = Uint8List.fromList(digest).asUnmodifiableView();

  // ...........................................................................
  /// The SHA-256 digest of the nonce followed by the shared secret.
  final Uint8List digest;

  @override
  int get code => commandCode;

  // ...........................................................................
  /// The command code, 0x02.
  static const int commandCode = 0x02;

  // ...........................................................................
  @override
  Uint8List _encodePayload() => MidiNetworkMidi2Command._pad(digest);

  @override
  List<Object?> get _fields => [digest];
}

// #############################################################################
/// Invitation with User Authentication (0x03): a client answers a
/// challenge with the digest of the nonce, user name and password, and the
/// user name.
final class MidiNetworkMidi2InvitationWithUserAuthentication
    extends MidiNetworkMidi2Command {
  /// Creates the invitation from a copy of the 32-byte SHA-256 [digest].
  MidiNetworkMidi2InvitationWithUserAuthentication({
    required List<int> digest,
    required this.userName,
  }) : digest = Uint8List.fromList(digest).asUnmodifiableView();

  // ...........................................................................
  /// The SHA-256 digest of the nonce, the user name and the password.
  final Uint8List digest;

  /// The user name.
  final String userName;

  @override
  int get code => commandCode;

  // ...........................................................................
  /// The command code, 0x03.
  static const int commandCode = 0x03;

  // ...........................................................................
  @override
  Uint8List _encodePayload() => Uint8List.fromList([
    ...MidiNetworkMidi2Command._pad(digest),
    ...MidiNetworkMidi2Command._padded(userName, _maxUserNameBytes),
  ]);

  @override
  List<Object?> get _fields => [digest, userName];

  // The payload holds at most 255 words, eight of them the digest.
  static const int _maxUserNameBytes = 988;
}

// #############################################################################
/// The base of the four replies a host sends to an invitation; all carry
/// the host's UMP Endpoint Name and Product Instance Id.
sealed class MidiNetworkMidi2InvitationReply extends MidiNetworkMidi2Command {
  /// Creates a reply.
  const MidiNetworkMidi2InvitationReply({
    required this.endpointName,
    required this.productInstanceId,
  });

  // ...........................................................................
  /// The UMP Endpoint Name of the host.
  final String endpointName;

  /// The Product Instance Id of the host.
  final String productInstanceId;

  @override
  int get commandSpecificData => _identity.nameWords << 8;

  // ...........................................................................
  _Identity get _identity => _Identity(endpointName, productInstanceId);

  @override
  Uint8List _encodePayload() => _identity.encode();

  @override
  List<Object?> get _fields => [endpointName, productInstanceId];
}

// #############################################################################
/// Invitation Reply: Accepted (0x10): the session is established.
final class MidiNetworkMidi2InvitationAccepted
    extends MidiNetworkMidi2InvitationReply {
  /// Creates the reply.
  const MidiNetworkMidi2InvitationAccepted({
    required super.endpointName,
    required super.productInstanceId,
  });

  // ...........................................................................
  @override
  int get code => commandCode;

  // ...........................................................................
  /// The command code, 0x10.
  static const int commandCode = 0x10;
}

// #############################################################################
/// Invitation Reply: Pending (0x11): the host needs time, e.g. for a user
/// to approve the client; the client waits instead of inviting again.
final class MidiNetworkMidi2InvitationPending
    extends MidiNetworkMidi2InvitationReply {
  /// Creates the reply.
  const MidiNetworkMidi2InvitationPending({
    required super.endpointName,
    required super.productInstanceId,
  });

  // ...........................................................................
  @override
  int get code => commandCode;

  // ...........................................................................
  /// The command code, 0x11.
  static const int commandCode = 0x11;
}

// #############################################################################
/// Invitation Reply: Authentication Required (0x12): the host challenges
/// the client to prove the shared secret.
final class MidiNetworkMidi2AuthenticationRequired
    extends MidiNetworkMidi2InvitationReply {
  /// Creates the challenge from a copy of the 16-byte [nonce].
  ///
  /// - [authenticationState] [firstRequest] or [incorrectDigest].
  MidiNetworkMidi2AuthenticationRequired({
    required super.endpointName,
    required super.productInstanceId,
    required List<int> nonce,
    this.authenticationState = firstRequest,
  }) : nonce = Uint8List.fromList(nonce).asUnmodifiableView();

  // ...........................................................................
  /// The random nonce the digest starts with.
  final Uint8List nonce;

  /// Whether this is the first challenge or the answer to a wrong digest.
  final int authenticationState;

  @override
  int get code => commandCode;

  @override
  int get commandSpecificData =>
      super.commandSpecificData | (authenticationState & 0xFF);

  // ...........................................................................
  /// The command code, 0x12.
  static const int commandCode = 0x12;

  /// The authentication state of a first challenge.
  static const int firstRequest = 0x00;

  /// The authentication state after a wrong digest.
  static const int incorrectDigest = 0x01;

  // ...........................................................................
  @override
  Uint8List _encodePayload() => Uint8List.fromList([
    ...MidiNetworkMidi2Command._pad(nonce),
    ...super._encodePayload(),
  ]);

  @override
  List<Object?> get _fields => [...super._fields, nonce, authenticationState];
}

// #############################################################################
/// Invitation Reply: User Authentication Required (0x13): the host
/// challenges the client to prove a user name and password.
final class MidiNetworkMidi2UserAuthenticationRequired
    extends MidiNetworkMidi2AuthenticationRequired {
  /// Creates the challenge from a copy of the 16-byte [nonce].
  MidiNetworkMidi2UserAuthenticationRequired({
    required super.endpointName,
    required super.productInstanceId,
    required super.nonce,
    super.authenticationState,
  });

  // ...........................................................................
  @override
  int get code => commandCode;

  // ...........................................................................
  /// The command code, 0x13.
  static const int commandCode = 0x13;
}

// #############################################################################
/// The UMP Endpoint Name and Product Instance Id as invitations and their
/// replies carry them.
class _Identity {
  _Identity(String name, String productInstanceId)
    : name = MidiNetworkMidi2Command._padded(
        name,
        MidiNetworkMidi2Command.maxEndpointNameBytes,
      ),
      productInstanceId = MidiNetworkMidi2Command._padded(
        productInstanceId,
        MidiNetworkMidi2Command.maxProductInstanceIdBytes,
      );

  Uint8List encode() => Uint8List.fromList([...name, ...productInstanceId]);

  final Uint8List name;
  final Uint8List productInstanceId;

  int get nameWords => name.length ~/ 4;
}

// #############################################################################
MidiNetworkMidi2Command _decodeInvitationCommand(
  int code,
  int csd,
  Uint8List payload,
) {
  if (code == MidiNetworkMidi2InvitationWithAuthentication.commandCode) {
    return MidiNetworkMidi2InvitationWithAuthentication(
      digest: _digest(payload),
    );
  }
  if (code == MidiNetworkMidi2InvitationWithUserAuthentication.commandCode) {
    return MidiNetworkMidi2InvitationWithUserAuthentication(
      digest: _digest(payload),
      userName: MidiNetworkMidi2Command._string(
        Uint8List.sublistView(payload, 32),
      ),
    );
  }
  final challenge =
      code == MidiNetworkMidi2AuthenticationRequired.commandCode ||
      code == MidiNetworkMidi2UserAuthenticationRequired.commandCode;
  final start = challenge ? 16 : 0;
  final nameEnd = start + (csd >> 8) * 4;
  if (nameEnd > payload.length) {
    throw const FormatException('The name exceeds the payload');
  }
  final name = MidiNetworkMidi2Command._string(
    Uint8List.sublistView(payload, start, nameEnd),
  );
  final id = MidiNetworkMidi2Command._string(
    Uint8List.sublistView(payload, nameEnd),
  );
  final nonce = Uint8List.sublistView(payload, 0, start);
  final state = csd & 0xFF;
  return switch (code) {
    MidiNetworkMidi2Invitation.commandCode => MidiNetworkMidi2Invitation(
      endpointName: name,
      productInstanceId: id,
      capabilities: state,
    ),
    MidiNetworkMidi2InvitationAccepted.commandCode =>
      MidiNetworkMidi2InvitationAccepted(
        endpointName: name,
        productInstanceId: id,
      ),
    MidiNetworkMidi2InvitationPending.commandCode =>
      MidiNetworkMidi2InvitationPending(
        endpointName: name,
        productInstanceId: id,
      ),
    MidiNetworkMidi2AuthenticationRequired.commandCode =>
      MidiNetworkMidi2AuthenticationRequired(
        endpointName: name,
        productInstanceId: id,
        nonce: nonce,
        authenticationState: state,
      ),
    _ => MidiNetworkMidi2UserAuthenticationRequired(
      endpointName: name,
      productInstanceId: id,
      nonce: nonce,
      authenticationState: state,
    ),
  };
}

// #############################################################################
Uint8List _digest(Uint8List payload) {
  if (payload.length < 32) {
    throw const FormatException('The digest needs 32 bytes');
  }
  return Uint8List.sublistView(payload, 0, 32);
}
