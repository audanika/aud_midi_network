// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'midi_network_access.dart';
import 'midi_network_connection.dart';

// #############################################################################
/// A packet received on a connection of a [MidiNetworkSession].
typedef MidiNetworkReceived = ({
  MidiNetworkConnection connection,
  MidiPacket packet,
});

/// Packets of a connection of a [MidiNetworkSession] that were lost, with a
/// human-readable cause; see `MidiNetworkConnectionListener.packetsLost`.
typedef MidiNetworkLoss = ({
  MidiNetworkConnection connection,
  int count,
  String cause,
});

// #############################################################################
/// A network MIDI session run by this package: a local endpoint on UDP that
/// accepts connections from peers and opens connections to hosts.
abstract interface class MidiNetworkSession {
  // ...........................................................................
  /// Binds the sockets; the session accepts invitations afterwards.
  ///
  /// Throws a `SocketException` when the port is taken.
  Future<void> open();

  /// Ends all connections and releases the sockets.
  Future<void> close();

  // ...........................................................................
  /// Invites [host] and completes when the invitation ended: the
  /// connection's state tells whether it was accepted.
  ///
  /// Throws a [StateError] while the session is closed.
  Future<MidiNetworkConnection> connect(MidiNetworkHostInfo host);

  /// Ends the connection to [host]; does nothing without one.
  Future<void> disconnect(MidiNetworkHostInfo host);

  // ...........................................................................
  /// The protocol of the session.
  MidiNetworkProtocol get protocol;

  /// The name under which the session presents itself.
  String get localName;

  /// The UDP port the session listens on, the control port for AppleMIDI;
  /// 0 while closed.
  int get port;

  /// Whether the session is open.
  bool get isOpen;

  /// Who may connect to the session.
  MidiNetworkAccess get access;

  /// The current connections, including those still inviting.
  List<MidiNetworkConnection> get connections;

  /// Reports every connection that was added or changed.
  Stream<MidiNetworkConnection> get connectionChanges;

  /// Reports every packet received.
  Stream<MidiNetworkReceived> get received;

  /// Reports lost packets.
  Stream<MidiNetworkLoss> get losses;
}
