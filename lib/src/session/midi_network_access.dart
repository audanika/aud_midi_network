// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// Decides which peers may connect to a session.
///
/// With [MidiNetworkConnectionPolicy.anyone] every peer may connect. With
/// [MidiNetworkConnectionPolicy.contacts] or
/// [MidiNetworkConnectionPolicy.specificPeers] only peers whose name, IP
/// address or product instance id is in [allowedPeers]. Peers the session
/// invites itself are always admitted.
final class MidiNetworkAccess {
  /// Creates the access rules from a copy of [allowedPeers].
  MidiNetworkAccess({
    this.policy = MidiNetworkConnectionPolicy.anyone,
    Set<String> allowedPeers = const {},
  }) : allowedPeers = Set.unmodifiable(allowedPeers);

  // ...........................................................................
  /// Returns whether a peer with the given identifiers may connect; empty
  /// identifiers never match.
  bool allows({
    required String name,
    required String address,
    String productInstanceId = '',
  }) =>
      policy == MidiNetworkConnectionPolicy.anyone ||
      [
        name,
        address,
        productInstanceId,
      ].any((id) => id.isNotEmpty && allowedPeers.contains(id));

  // ...........................................................................
  /// Who may connect.
  final MidiNetworkConnectionPolicy policy;

  /// The names, addresses or product instance ids of the admitted peers;
  /// cannot be modified.
  final Set<String> allowedPeers;

  // ...........................................................................
  @override
  bool operator ==(Object other) =>
      other is MidiNetworkAccess &&
      other.policy == policy &&
      other.allowedPeers.length == allowedPeers.length &&
      other.allowedPeers.containsAll(allowedPeers);

  @override
  int get hashCode =>
      Object.hash(policy, Object.hashAllUnordered(allowedPeers));

  @override
  String toString() =>
      'MidiNetworkAccess(policy: ${policy.name}, '
      'allowedPeers: $allowedPeers)';
}
