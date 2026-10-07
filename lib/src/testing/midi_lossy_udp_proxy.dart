// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../session/midi_bind_adjacent.dart';
import 'midi_network_impairment.dart';

// #############################################################################
/// A UDP proxy for tests that forwards datagrams between clients and a
/// target over an impaired link: loss, burst loss, reordering, duplication
/// and delay, all drawn from a seeded random generator.
///
/// Clients send to [port] (and the following ports when [portCount] is
/// greater than one); the proxy forwards to the target's ports in the same
/// order from sockets of its own, one adjacent group per client, and
/// returns the answers. AppleMIDI needs a [portCount] of two, for the
/// control and the data port; Network MIDI 2.0 needs one.
final class MidiLossyUdpProxy {
  MidiLossyUdpProxy._({
    required this.target,
    required this.targetPort,
    required List<RawDatagramSocket> sockets,
    required this.impairment,
    required int seed,
  }) : _sockets = sockets,
       _random = Random(seed) {
    for (var i = 0; i < sockets.length; i++) {
      _subscriptions.add(sockets[i].listen((event) => _onFrontEvent(i, event)));
    }
  }

  // ...........................................................................
  /// Starts a proxy in front of [target] at [targetPort].
  ///
  /// - [portCount] the number of adjacent ports to forward.
  /// - [address] the address the proxy listens on, loopback by default.
  /// - [impairment] how the link treats datagrams in both directions.
  /// - [seed] the seed of the random generator.
  static Future<MidiLossyUdpProxy> start({
    required InternetAddress target,
    required int targetPort,
    int portCount = 1,
    InternetAddress? address,
    MidiNetworkImpairment impairment = MidiNetworkImpairment.none,
    int seed = 0,
  }) async {
    final sockets = await midiBindAdjacent(
      address: address ?? InternetAddress.loopbackIPv4,
      count: portCount,
    );
    return MidiLossyUdpProxy._(
      target: target,
      targetPort: targetPort,
      sockets: sockets,
      impairment: impairment,
      seed: seed,
    );
  }

  // ...........................................................................
  /// Stops forwarding, drops the datagrams in flight and closes all
  /// sockets.
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    for (final socket in _sockets) {
      socket.close();
    }
    for (final client in _clients.values) {
      for (final socket in await client) {
        socket.close();
      }
    }
  }

  // ...........................................................................
  /// The address of the target.
  final InternetAddress target;

  /// The first port of the target.
  final int targetPort;

  /// The address clients send to.
  InternetAddress get address => _sockets.first.address;

  /// The first port clients send to.
  int get port => _sockets.first.port;

  /// The number of adjacent ports forwarded.
  int get portCount => _sockets.length;

  /// How the link treats datagrams; may change at any time.
  MidiNetworkImpairment impairment;

  /// Whether the link drops every datagram, like a pulled cable.
  bool blocked = false;

  /// Drops every datagram for which it returns true, in addition to the
  /// impairment; it receives the port index, the direction and the data.
  bool Function(int portIndex, bool toTarget, Uint8List data)? dropWhere;

  /// The number of datagrams delivered, duplicates included.
  int get delivered => _delivered;

  /// The number of datagrams dropped.
  int get dropped => _dropped;

  /// The number of datagrams delivered twice.
  int get duplicated => _duplicated;

  /// The number of datagrams held back so that later ones overtake them.
  int get reordered => _reordered;

  // ...........................................................................
  final List<RawDatagramSocket> _sockets;
  final Random _random;
  final _subscriptions = <StreamSubscription<RawSocketEvent>>[];
  final _clients = <String, Future<List<RawDatagramSocket>>>{};
  final _timers = <Timer>{};
  bool _upInBurst = false;
  bool _downInBurst = false;
  bool _closed = false;
  int _delivered = 0;
  int _dropped = 0;
  int _duplicated = 0;
  int _reordered = 0;

  void _onFrontEvent(int index, RawSocketEvent event) {
    final datagram = event == RawSocketEvent.read
        ? _sockets[index].receive()
        : null;
    if (datagram == null) {
      return;
    }
    final base = datagram.port - index;
    final key = '${datagram.address.address}:$base';
    final client = _clients[key] ??= _openClient(datagram.address, base);
    unawaited(
      client.then((backs) {
        _forward(index, true, datagram.data, () {
          backs[index].send(datagram.data, target, targetPort + index);
        });
      }),
    );
  }

  Future<List<RawDatagramSocket>> _openClient(
    InternetAddress address,
    int base,
  ) async {
    final backs = await midiBindAdjacent(
      address: target.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      count: portCount,
    );
    for (var i = 0; i < backs.length; i++) {
      final back = backs[i];
      _subscriptions.add(
        back.listen((event) {
          final datagram = event == RawSocketEvent.read ? back.receive() : null;
          if (datagram == null) {
            return;
          }
          _forward(i, false, datagram.data, () {
            _sockets[i].send(datagram.data, address, base + i);
          });
        }),
      );
    }
    return backs;
  }

  void _forward(
    int index,
    bool toTarget,
    Uint8List data,
    void Function() send,
  ) {
    if (blocked || (dropWhere?.call(index, toTarget, data) ?? false)) {
      _dropped++;
      return;
    }
    final decision = impairment.decide(
      _random,
      inBurst: toTarget ? _upInBurst : _downInBurst,
    );
    if (toTarget) {
      _upInBurst = decision.inBurst;
    } else {
      _downInBurst = decision.inBurst;
    }
    final deliveries = decision.deliveries;
    if (deliveries.isEmpty) {
      _dropped++;
      return;
    }
    if (deliveries.length > 1) {
      _duplicated++;
    }
    if (decision.reordered) {
      _reordered++;
    }
    for (final wait in deliveries) {
      _deliver(wait, send);
    }
  }

  void _deliver(Duration wait, void Function() send) {
    if (wait <= Duration.zero) {
      _delivered++;
      send();
      return;
    }
    late final Timer timer;
    timer = Timer(wait, () {
      _timers.remove(timer);
      _delivered++;
      send();
    });
    _timers.add(timer);
  }
}
