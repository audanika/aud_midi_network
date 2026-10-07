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

import '../session/midi_network_access.dart';
import '../session/midi_network_connection.dart';
import '../session/midi_network_session.dart';
import '../session/midi_network_session_events.dart';
import 'midi_network_midi2_command.dart';
import 'midi_network_midi2_connection.dart';
import 'midi_network_midi2_credentials.dart';
import 'midi_network_midi2_settings.dart';

// #############################################################################
/// A Network MIDI 2.0 (UDP) endpoint (M2-124-UM): one UDP port that hosts
/// sessions for clients and opens sessions to other hosts as a client.
///
/// Peers are told apart by IP address and UDP port. Invitations pass the
/// [access] rules and, when [requiredSecret] or [requiredUsers] are set,
/// the authentication. The session advertises nothing itself; announce
/// [port] as [serviceType] with [txtRecord] through an OS registrar.
final class MidiNetworkMidi2Session implements MidiNetworkSession {
  /// Creates a closed session.
  ///
  /// - [localName] the UMP Endpoint Name of this side.
  /// - [productInstanceId] the Product Instance Id of this side; a random
  ///   one by default.
  /// - [requestedPort] the UDP port to bind; 0 lets the system choose.
  /// - [address] the local address to bind, all IPv4 interfaces by default.
  /// - [credentialsFor] returns what to prove to a host that asks.
  /// - [requiredSecret], [requiredUsers] what clients must prove.
  /// - [random] creates nonces, ping ids and the default product instance
  ///   id; secure by default.
  MidiNetworkMidi2Session({
    required this.localName,
    String? productInstanceId,
    this.requestedPort = 0,
    InternetAddress? address,
    MidiNetworkAccess? access,
    this.credentialsFor,
    this.requiredSecret,
    List<MidiNetworkMidi2UserCredentials> requiredUsers = const [],
    this.settings = const MidiNetworkMidi2Settings(),
    this._clock = const MidiSystemClock(),
    this._timerFactory = Timer.new,
    Random? random,
  }) : requiredUsers = List.unmodifiable(requiredUsers),
       address = address ?? InternetAddress.anyIPv4,
       access = access ?? MidiNetworkAccess(),
       _random = random ?? Random.secure(),
       productInstanceId =
           productInstanceId ?? _randomId(random ?? Random.secure()) {
    _events.connectionChanges.listen(_onConnectionChanged);
  }

  // ...........................................................................
  @override
  Future<void> open() async {
    if (_socket != null) {
      return;
    }
    final socket = await RawDatagramSocket.bind(address, requestedPort);
    _socket = socket;
    _subscription = socket.listen((event) {
      if (event == RawSocketEvent.read) {
        _receive(socket);
      }
    });
  }

  @override
  Future<void> close() async {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    await Future.wait([
      for (final connection in _connections.values.toList()) connection.close(),
    ]);
    _connections.clear();
    await _subscription?.cancel();
    socket.close();
    _socket = null;
  }

  // ...........................................................................
  /// Invites [host] with [credentials], or those [credentialsFor] returns,
  /// and completes when the invitation ended.
  ///
  /// Returns the connection that already exists to [host] unless it
  /// failed. Throws a [StateError] while the session is closed and a
  /// [SocketException] when the host name cannot be resolved.
  @override
  Future<MidiNetworkMidi2Connection> connect(
    MidiNetworkHostInfo host, {
    MidiNetworkMidi2Credentials? credentials,
  }) async {
    if (_socket == null) {
      throw StateError('The session $localName is closed');
    }
    final remote = await _resolve(host.address);
    final key = _key(remote, host.port);
    final existing = _connections[key];
    if (existing != null &&
        existing.state != MidiNetworkConnectionState.failed) {
      return existing;
    }
    await existing?.close();
    final connection = _create(
      host: host,
      remote: remote,
      isIncoming: false,
      credentials: credentials ?? credentialsFor?.call(host),
    );
    _connections[key] = connection;
    await connection.invite();
    return connection;
  }

  @override
  Future<void> disconnect(MidiNetworkHostInfo host) async {
    final remote = InternetAddress.tryParse(host.address);
    final matches = _connections.entries.where(
      (entry) =>
          entry.key == (remote == null ? null : _key(remote, host.port)) ||
          entry.value.host == host,
    );
    await Future.wait([
      for (final entry in matches.toList()) entry.value.close(),
    ]);
  }

  // ...........................................................................
  @override
  MidiNetworkProtocol get protocol => MidiNetworkProtocol.networkMidi2;

  @override
  final String localName;

  /// The Product Instance Id of this side.
  final String productInstanceId;

  /// The UDP port asked for at construction; 0 lets the system choose.
  final int requestedPort;

  /// The local address the socket binds to.
  final InternetAddress address;

  @override
  final MidiNetworkAccess access;

  /// Returns what to prove to a host that asks for authentication.
  final MidiNetworkMidi2Credentials? Function(MidiNetworkHostInfo host)?
  credentialsFor;

  /// The shared secret clients must prove, or null.
  final MidiNetworkMidi2SharedSecret? requiredSecret;

  /// The users clients must log in as; cannot be modified.
  final List<MidiNetworkMidi2UserCredentials> requiredUsers;

  /// The timing and buffering of the sessions.
  final MidiNetworkMidi2Settings settings;

  @override
  int get port => _socket?.port ?? 0;

  @override
  bool get isOpen => _socket != null;

  @override
  List<MidiNetworkMidi2Connection> get connections =>
      List.unmodifiable(_connections.values);

  @override
  Stream<MidiNetworkConnection> get connectionChanges =>
      _events.connectionChanges;

  @override
  Stream<MidiNetworkReceived> get received => _events.received;

  @override
  Stream<MidiNetworkLoss> get losses => _events.losses;

  /// The TXT record to advertise with [serviceType] (M2-124-UM 5.1).
  Map<String, String> get txtRecord => {
    'UMPEndpointName': localName,
    'ProductInstanceId': productInstanceId,
  };

  // ...........................................................................
  /// The DNS-SD service type of Network MIDI 2.0.
  static const String serviceType = MidiNetworkHostInfo.networkMidi2ServiceType;

  // ...........................................................................
  final MidiClock _clock;
  final MidiTimerFactory _timerFactory;
  final Random _random;
  final _events = MidiNetworkSessionEvents();
  final _connections = <String, MidiNetworkMidi2Connection>{};
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;

  static String _key(InternetAddress address, int port) =>
      '${address.address}:$port';

  static String _randomId(Random random) => [
    for (var i = 0; i < 4; i++)
      random.nextInt(0x10000).toRadixString(16).padLeft(4, '0'),
  ].join().toUpperCase();

  static Future<InternetAddress> _resolve(String host) async =>
      InternetAddress.tryParse(host) ??
      (await InternetAddress.lookup(
        host,
        type: InternetAddressType.IPv4,
      )).first;

  MidiNetworkMidi2Connection _create({
    required MidiNetworkHostInfo host,
    required InternetAddress remote,
    required bool isIncoming,
    MidiNetworkMidi2Credentials? credentials,
  }) => MidiNetworkMidi2Connection(
    host: host,
    isIncoming: isIncoming,
    localEndpointName: localName,
    localProductInstanceId: productInstanceId,
    transmit: (datagram) => _send(datagram, remote, host.port),
    listener: _events,
    credentials: credentials,
    requiredSecret: requiredSecret,
    requiredUsers: requiredUsers,
    settings: settings,
    clock: _clock,
    timerFactory: _timerFactory,
    random: _random,
  );

  // A send to an unreachable peer returns 0 instead of throwing; the timers
  // of the connection notice the silence.
  void _send(Uint8List datagram, InternetAddress remote, int port) =>
      _socket?.send(datagram, remote, port);

  void _receive(RawDatagramSocket socket) {
    for (
      var datagram = socket.receive();
      datagram != null;
      datagram = socket.receive()
    ) {
      if (MidiNetworkMidi2Command.isPacket(datagram.data)) {
        _route(datagram, MidiNetworkMidi2Command.decodePacket(datagram.data));
      }
    }
  }

  void _route(Datagram datagram, List<MidiNetworkMidi2Command> commands) {
    final key = _key(datagram.address, datagram.port);
    final connection = _connections[key] ?? _admit(datagram, commands);
    if (connection != null) {
      _connections[key] = connection;
      connection.handle(commands);
    }
  }

  /// Creates the host side of a session for an unknown peer, or answers
  /// its commands without a session and returns null.
  MidiNetworkMidi2Connection? _admit(
    Datagram datagram,
    List<MidiNetworkMidi2Command> commands,
  ) {
    final invitation = commands.whereType<MidiNetworkMidi2Invitation>();
    if (invitation.isEmpty) {
      _answerWithoutSession(datagram, commands);
      return null;
    }
    final peer = invitation.first;
    final refusal =
        !access.allows(
          name: peer.endpointName,
          address: datagram.address.address,
          productInstanceId: peer.productInstanceId,
        )
        ? MidiNetworkMidi2Bye.reasonUserDidNotAccept
        : _connections.length >= settings.maxSessions
        ? MidiNetworkMidi2Bye.reasonTooManyOpenSessions
        : null;
    if (refusal != null) {
      _reply(datagram, [MidiNetworkMidi2Bye(reason: refusal)]);
      return null;
    }
    return _create(
      host: MidiNetworkHostInfo(
        name: peer.endpointName,
        address: datagram.address.address,
        port: datagram.port,
        serviceType: serviceType,
      ),
      remote: datagram.address,
      isIncoming: true,
    );
  }

  void _answerWithoutSession(
    Datagram datagram,
    List<MidiNetworkMidi2Command> commands,
  ) {
    var refused = false;
    final replies = <MidiNetworkMidi2Command>[];
    for (final command in commands) {
      switch (command) {
        case MidiNetworkMidi2Ping():
          replies.add(MidiNetworkMidi2PingReply(pingId: command.pingId));
        case MidiNetworkMidi2Bye():
          replies.add(const MidiNetworkMidi2ByeReply());
        case MidiNetworkMidi2InvitationWithAuthentication() ||
            MidiNetworkMidi2InvitationWithUserAuthentication():
          replies.add(
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonMissingPriorInvitation,
            ),
          );
        case MidiNetworkMidi2UmpData() ||
                MidiNetworkMidi2RetransmitRequest() ||
                MidiNetworkMidi2RetransmitError() ||
                MidiNetworkMidi2SessionReset() ||
                MidiNetworkMidi2SessionResetReply()
            when !refused:
          refused = true;
          replies.add(
            const MidiNetworkMidi2Bye(
              reason: MidiNetworkMidi2Bye.reasonSessionNotEstablished,
            ),
          );
        default:
          break;
      }
    }
    if (replies.isNotEmpty) {
      _reply(datagram, replies);
    }
  }

  void _reply(Datagram datagram, List<MidiNetworkMidi2Command> commands) =>
      _send(
        MidiNetworkMidi2Command.encodePacket(commands),
        datagram.address,
        datagram.port,
      );

  void _onConnectionChanged(MidiNetworkConnection connection) {
    final ended =
        connection.state == MidiNetworkConnectionState.disconnected ||
        connection.state == MidiNetworkConnectionState.failed;
    if (ended &&
        connection is MidiNetworkMidi2Connection &&
        !connection.isReconnecting) {
      _connections.removeWhere((_, c) => identical(c, connection));
    }
  }
}
