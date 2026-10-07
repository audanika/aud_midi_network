// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// #############################################################################
/// The credentials a Network MIDI 2.0 client proves to a host that asks for
/// authentication (M2-124-UM 6.9 and 6.10).
///
/// The host sends a random nonce; the client answers with the SHA-256
/// digest of the nonce followed by the UTF-8 bytes of the secret, without
/// separators. A single unsalted hash allows offline attacks on a captured
/// exchange, so secrets should be long.
sealed class MidiNetworkMidi2Credentials {
  /// Creates credentials.
  const MidiNetworkMidi2Credentials();

  // ...........................................................................
  /// Returns the digest that answers [nonce].
  Uint8List digest(List<int> nonce);

  // ...........................................................................
  /// Returns whether the digests [a] and [b] are equal, in a time that does
  /// not depend on where they differ.
  static bool digestsMatch(List<int> a, List<int> b) {
    if (a.length != b.length) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a[i] ^ b[i];
    }
    return difference == 0;
  }

  /// Returns a nonce of [nonceLength] printable ASCII characters drawn from
  /// [random], a cryptographically secure generator by default.
  static Uint8List createNonce([Random? random]) {
    final source = random ?? Random.secure();
    return Uint8List.fromList([
      for (var i = 0; i < nonceLength; i++) 0x21 + source.nextInt(0x7E - 0x20),
    ]);
  }

  /// The length of a nonce in bytes.
  static const int nonceLength = 16;

  /// The length of a digest in bytes.
  static const int digestLength = 32;

  // ...........................................................................
  static Uint8List _sha256(List<List<int>> parts) => Uint8List.fromList(
    sha256.convert([for (final part in parts) ...part]).bytes,
  );
}

// #############################################################################
/// A secret shared by the host and its clients (Invitation with
/// Authentication).
final class MidiNetworkMidi2SharedSecret extends MidiNetworkMidi2Credentials {
  /// Creates the credentials for [secret].
  const MidiNetworkMidi2SharedSecret(this.secret);

  // ...........................................................................
  @override
  Uint8List digest(List<int> nonce) =>
      MidiNetworkMidi2Credentials._sha256([nonce, utf8.encode(secret)]);

  // ...........................................................................
  /// The shared secret.
  final String secret;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is MidiNetworkMidi2SharedSecret && other.secret == secret;

  @override
  int get hashCode => secret.hashCode;

  @override
  String toString() => 'MidiNetworkMidi2SharedSecret(***)';
}

// #############################################################################
/// A user name and password (Invitation with User Authentication).
final class MidiNetworkMidi2UserCredentials
    extends MidiNetworkMidi2Credentials {
  /// Creates the credentials of the user [userName].
  const MidiNetworkMidi2UserCredentials({
    required this.userName,
    required this.password,
  });

  // ...........................................................................
  @override
  Uint8List digest(List<int> nonce) => MidiNetworkMidi2Credentials._sha256([
    nonce,
    utf8.encode(userName),
    utf8.encode(password),
  ]);

  // ...........................................................................
  /// The user name; it travels in clear text.
  final String userName;

  /// The password.
  final String password;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is MidiNetworkMidi2UserCredentials &&
      other.userName == userName &&
      other.password == password;

  @override
  int get hashCode => Object.hash(userName, password);

  @override
  String toString() => "MidiNetworkMidi2UserCredentials(userName: '$userName')";
}
