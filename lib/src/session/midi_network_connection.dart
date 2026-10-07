// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

// #############################################################################
/// A connection of a network MIDI session to one remote peer.
///
/// AppleMIDI connections carry MIDI 1.0 bytes ([MidiBytesPacket]), Network
/// MIDI 2.0 connections Universal MIDI Packets ([MidiUmpPacket]).
abstract interface class MidiNetworkConnection {
  // ...........................................................................
  /// Sends [packet] to the peer right away.
  ///
  /// Throws a [StateError] while the connection is not established and an
  /// [ArgumentError] for a packet of the other form.
  Future<void> send(MidiPacket packet);

  /// Ends the connection; completes once the peer was told or gave no
  /// answer in time.
  Future<void> close();

  // ...........................................................................
  /// The remote peer.
  MidiNetworkHostInfo get host;

  /// The name the peer gave itself; the host name until it answered.
  String get remoteName;

  /// The state of the connection.
  MidiNetworkConnectionState get state;

  /// Whether the peer invited this side.
  bool get isIncoming;

  /// The description of the connection, without port ids.
  MidiNetworkConnectionInfo get info;
}
