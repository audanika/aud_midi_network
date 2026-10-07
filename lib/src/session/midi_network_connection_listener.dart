// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'midi_network_connection.dart';

// #############################################################################
/// Receives what happens on the connections of a session; sessions
/// implement it and pass it to their connections.
abstract interface class MidiNetworkConnectionListener {
  // ...........................................................................
  /// Reports that the state or the description of [connection] changed.
  void connectionChanged(MidiNetworkConnection connection);

  // ...........................................................................
  /// Reports [packet] received on [connection].
  void packetReceived(MidiNetworkConnection connection, MidiPacket packet);

  // ...........................................................................
  /// Reports that [count] packets of [connection] were lost, with a
  /// human-readable [cause].
  ///
  /// AppleMIDI reports every loss and whether the recovery journal repaired
  /// the MIDI state; Network MIDI 2.0 reports the gaps that neither the
  /// error correction nor a retransmission closed.
  void packetsLost(MidiNetworkConnection connection, int count, String cause);
}
