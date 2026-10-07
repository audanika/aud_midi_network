// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../session/midi_bind_adjacent.dart';
import '../session/midi_network_access.dart';
import '../session/midi_network_connection.dart';
import '../session/midi_network_session.dart';
import '../session/midi_network_session_events.dart';
import 'midi_apple_midi_command.dart';
import 'midi_apple_midi_connection.dart';
import 'midi_apple_midi_settings.dart';

// #############################################################################
/// An AppleMIDI session: the network MIDI session of Apple's driver in pure
/// Dart, on a control port and the data port right above it.
///
/// The session accepts invitations from peers that pass [access] and
/// invites hosts with [connect]. Peers are told apart by IP address and
/// control port. It advertises nothing itself; announce [port] as
/// [serviceType] through an OS registrar.
final class MidiAppleMidiSession implements MidiNetworkSession {
  /// Creates a closed session.
  ///
  /// - [localName] the name this side presents.
  /// - [requestedPort] the control port to bind, [defaultPort] by default;
  ///   0 lets the system choose two adjacent ports.
  /// - [address] the local address to bind, all IPv4 interfaces by default.
  /// - [random] creates the SSRC, tokens and sequence numbers; secure by
  ///   default.
  MidiAppleMidiSession({
    required this.localName,
    this.requestedPort = defaultPort,
    InternetAddress? address,
    MidiNetworkAccess? access,
    this.settings = const MidiAppleMidiSettings(),
    this._clock = const MidiSystemClock(),
    this._timerFactory = Timer.new,
    Random? random,
  }) : address = address ?? InternetAddress.anyIPv4,
       access = access ?? MidiNetworkAccess(),
       _random = random ?? Random.secure() {
    ssrc = _random.nextInt(1 << 32);
    _events.connectionChanges.listen(_onConnectionChanged);
  }

  // ...........................................................................
  @override
  Future<void> open() async {
    if (_control != null) {
      return;
    }
    final sockets = await midiBindAdjacent(
      address: address,
      count: 2,
      firstPort: requestedPort,
    );
    final control = _control = sockets[0];
    final data = _data = sockets[1];
    _subscriptions = [
      control.listen((event) => _read(control, event, _onControl)),
      data.listen((event) => _read(data, event, _onData)),
    ];
  }

  @override
  Future<void> close() async {
    final control = _control;
    if (control == null) {
      return;
    }
    await Future.wait([
      for (final peer in _byControl.values.toList()) peer.connection.close(),
    ]);
    _byControl.clear();
    _byData.clear();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    control.close();
    _data!.close();
    _control = null;
    _data = null;
  }

  // ...........................................................................
  /// Invites [host], whose port is the control port, and completes when the
  /// invitation ended.
  ///
  /// Returns the connection that already exists to [host] unless it
  /// failed. Throws a [StateError] while the session is closed and a
  /// [SocketException] when the host name cannot be resolved.
  @override
  Future<MidiAppleMidiConnection> connect(MidiNetworkHostInfo host) async {
    if (_control == null) {
      throw StateError('The session $localName is closed');
    }
    final remote = await _resolve(host.address);
    final existing = _byControl[_key(remote, host.port)];
    if (existing != null &&
        existing.connection.state != MidiNetworkConnectionState.failed) {
      return existing.connection;
    }
    await existing?.connection.close();
    final peer = _Peer(remote, controlPort: host.port);
    _register(peer, _create(host, peer, isIncoming: false));
    await peer.connection.invite();
    return peer.connection;
  }

  @override
  Future<void> disconnect(MidiNetworkHostInfo host) async {
    final remote = InternetAddress.tryParse(host.address);
    final key = remote == null ? null : _key(remote, host.port);
    await Future.wait([
      for (final MapEntry(key: peerKey, value: peer)
          in _byControl.entries.toList())
        if (peerKey == key || peer.connection.host == host)
          peer.connection.close(),
    ]);
  }

  // ...........................................................................
  @override
  MidiNetworkProtocol get protocol => MidiNetworkProtocol.appleMidi;

  @override
  final String localName;

  /// The control port asked for at construction.
  final int requestedPort;

  /// The local address the sockets bind to.
  final InternetAddress address;

  @override
  final MidiNetworkAccess access;

  /// The timing of the connections.
  final MidiAppleMidiSettings settings;

  /// The SSRC of this side, the same for all peers.
  late final int ssrc;

  @override
  int get port => _control?.port ?? 0;

  /// The data port, one above [port]; 0 while closed.
  int get dataPort => _data?.port ?? 0;

  @override
  bool get isOpen => _control != null;

  @override
  List<MidiAppleMidiConnection> get connections => List.unmodifiable([
    for (final peer in _byControl.values) peer.connection,
  ]);

  @override
  Stream<MidiNetworkConnection> get connectionChanges =>
      _events.connectionChanges;

  @override
  Stream<MidiNetworkReceived> get received => _events.received;

  @override
  Stream<MidiNetworkLoss> get losses => _events.losses;

  // ...........................................................................
  /// The control port of Apple's driver; the data port is the next one.
  static const int defaultPort = 5004;

  /// The DNS-SD service type of AppleMIDI.
  static const String serviceType = MidiNetworkHostInfo.appleMidiServiceType;

  // ...........................................................................
  final MidiClock _clock;
  final MidiTimerFactory _timerFactory;
  final Random _random;
  final _events = MidiNetworkSessionEvents();
  final _byControl = <String, _Peer>{};
  final _byData = <String, _Peer>{};
  RawDatagramSocket? _control;
  RawDatagramSocket? _data;
  var _subscriptions = <StreamSubscription<RawSocketEvent>>[];

  static String _key(InternetAddress address, int port) =>
      '${address.address}:$port';

  static Future<InternetAddress> _resolve(String host) async =>
      InternetAddress.tryParse(host) ??
      (await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv4,
      )).first;

  MidiAppleMidiConnection _create(
    MidiNetworkHostInfo host,
    _Peer peer, {
    required bool isIncoming,
  }) => MidiAppleMidiConnection(
    host: host,
    isIncoming: isIncoming,
    localName: localName,
    localSsrc: ssrc,
    transmit: (datagram, {required toDataPort}) =>
        (toDataPort ? _data : _control)?.send(
          datagram,
          peer.address,
          toDataPort ? peer.dataPort : peer.controlPort,
        ),
    listener: _events,
    settings: settings,
    clock: _clock,
    timerFactory: _timerFactory,
    random: _random,
  );

  void _register(_Peer peer, MidiAppleMidiConnection connection) {
    peer.connection = connection;
    _byControl[_key(peer.address, peer.controlPort)] = peer;
    _byData[_key(peer.address, peer.dataPort)] = peer;
  }

  void _read(
    RawDatagramSocket socket,
    RawSocketEvent event,
    void Function(Datagram datagram) handle,
  ) {
    if (event != RawSocketEvent.read) {
      return;
    }
    for (
      var datagram = socket.receive();
      datagram != null;
      datagram = socket.receive()
    ) {
      handle(datagram);
    }
  }

  void _onControl(Datagram datagram) {
    final command = _decode(datagram.data);
    if (command == null) {
      return;
    }
    final peer =
        _byControl[_key(datagram.address, datagram.port)] ??
        _admit(datagram, command);
    peer?.connection.handleCommand(command, onDataPort: false);
  }

  void _onData(Datagram datagram) {
    var peer = _byData[_key(datagram.address, datagram.port)];
    if (!MidiAppleMidiCommand.isCommand(datagram.data)) {
      peer?.connection.handleRtp(datagram.data);
      return;
    }
    final command = _decode(datagram.data);
    if (peer == null && command is MidiAppleMidiInvitation) {
      peer = _adoptDataPort(datagram, command);
    }
    if (command != null) {
      peer?.connection.handleCommand(command, onDataPort: true);
    }
  }

  static MidiAppleMidiCommand? _decode(Uint8List data) {
    if (!MidiAppleMidiCommand.isCommand(data)) {
      return null;
    }
    try {
      return MidiAppleMidiCommand.decode(data);
    } on FormatException {
      return null;
    }
  }

  /// Creates the responder side for an unknown peer that invites, or
  /// rejects the peer and returns null.
  _Peer? _admit(Datagram datagram, MidiAppleMidiCommand command) {
    if (command is! MidiAppleMidiInvitation) {
      return null;
    }
    if (!access.allows(name: command.name, address: datagram.address.address)) {
      _control!.send(
        MidiAppleMidiInvitationRejected(
          token: command.token,
          ssrc: ssrc,
          name: localName,
        ).encode(),
        datagram.address,
        datagram.port,
      );
      return null;
    }
    final peer = _Peer(datagram.address, controlPort: datagram.port);
    _register(
      peer,
      _create(
        MidiNetworkHostInfo(
          name: command.name,
          address: datagram.address.address,
          port: datagram.port,
          serviceType: serviceType,
        ),
        peer,
        isIncoming: true,
      ),
    );
    return peer;
  }

  /// Finds the responder side whose peer invites the data port from a
  /// port other than the one above its control port.
  _Peer? _adoptDataPort(Datagram datagram, MidiAppleMidiInvitation command) {
    for (final peer in _byControl.values) {
      if (peer.address.address == datagram.address.address &&
          peer.connection.isIncoming &&
          peer.connection.remoteSsrc == command.ssrc) {
        _byData.removeWhere((_, p) => identical(p, peer));
        peer.dataPort = datagram.port;
        _byData[_key(peer.address, peer.dataPort)] = peer;
        return peer;
      }
    }
    return null;
  }

  void _onConnectionChanged(MidiNetworkConnection connection) {
    final ended =
        connection.state == MidiNetworkConnectionState.disconnected ||
        connection.state == MidiNetworkConnectionState.failed;
    if (ended &&
        connection is MidiAppleMidiConnection &&
        !connection.isReconnecting) {
      _byControl.removeWhere((_, p) => identical(p.connection, connection));
      _byData.removeWhere((_, p) => identical(p.connection, connection));
    }
  }
}

// #############################################################################
/// The addresses of a peer and its connection.
class _Peer {
  _Peer(this.address, {required this.controlPort}) : dataPort = controlPort + 1;

  final InternetAddress address;
  final int controlPort;
  int dataPort;
  late MidiAppleMidiConnection connection;
}
