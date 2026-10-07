// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi_standard/aud_midi_standard.dart';

import 'midi_network_connection.dart';
import 'midi_network_connection_listener.dart';
import 'midi_network_session.dart';

// #############################################################################
/// Turns the reports of a session's connections into the session's
/// streams; sessions hold one and hand it to their connections.
///
/// The streams are broadcast streams that deliver synchronously, so a
/// packet reaches its listeners before the next datagram is read.
final class MidiNetworkSessionEvents implements MidiNetworkConnectionListener {
  /// Creates the streams.
  MidiNetworkSessionEvents();

  // ...........................................................................
  @override
  void connectionChanged(MidiNetworkConnection connection) =>
      _changes.add(connection);

  @override
  void packetReceived(MidiNetworkConnection connection, MidiPacket packet) =>
      _received.add((connection: connection, packet: packet));

  @override
  void packetsLost(MidiNetworkConnection connection, int count, String cause) =>
      _losses.add((connection: connection, count: count, cause: cause));

  /// Closes the streams; later reports are dropped.
  Future<void> close() async {
    await _changes.close();
    await _received.close();
    await _losses.close();
  }

  // ...........................................................................
  /// Reports every connection that was added or changed.
  Stream<MidiNetworkConnection> get connectionChanges => _changes.stream;

  /// Reports every packet received.
  Stream<MidiNetworkReceived> get received => _received.stream;

  /// Reports lost packets.
  Stream<MidiNetworkLoss> get losses => _losses.stream;

  // ...........................................................................
  final _changes = _Controller<MidiNetworkConnection>();
  final _received = _Controller<MidiNetworkReceived>();
  final _losses = _Controller<MidiNetworkLoss>();
}

// #############################################################################
/// A synchronous broadcast controller that ignores events after closing.
class _Controller<T> {
  final _controller = StreamController<T>.broadcast(sync: true);

  Stream<T> get stream => _controller.stream;

  void add(T event) {
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  Future<void> close() => _controller.close();
}
