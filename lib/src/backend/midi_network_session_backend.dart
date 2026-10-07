// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../apple_midi/midi_apple_midi_session.dart';
import '../apple_midi/midi_apple_midi_settings.dart';
import '../discovery/midi_network_browser.dart';
import '../midi2/midi_network_midi2_connection.dart';
import '../midi2/midi_network_midi2_credentials.dart';
import '../midi2/midi_network_midi2_session.dart';
import '../midi2/midi_network_midi2_settings.dart';
import '../session/midi_network_access.dart';
import '../session/midi_network_connection.dart';
import '../session/midi_network_session.dart';

// #############################################################################
/// A backend that runs a network MIDI session of this package and turns
/// each of its connections into an input and an output port.
///
/// AppleMIDI connections get byte ports (MIDI 1.0 on the wire), Network
/// MIDI 2.0 connections UMP ports ([MidiPortCapabilities.ump]). Inputs
/// carry the sender's time mapped to the package clock where the protocol
/// has one (AppleMIDI), the arrival time otherwise; outputs send at once,
/// the engine schedules in software. Losses become
/// [MidiDiagnosticKind.networkLoss] diagnostics of the input port.
///
/// The backend browses with multicast DNS and announces the session
/// through [advertiser], an OS registrar, when one is given.
final class MidiNetworkSessionBackend
    implements MidiBackend, MidiNetworkBackend {
  /// Creates a backend for sessions of [protocol].
  ///
  /// - [name] the backend name, the prefix of its port ids; give backends
  ///   of both protocols different names when they run side by side.
  /// - [advertiser] announces the session; none by default.
  /// - [browser] finds hosts; a multicast DNS browser by default.
  /// - [allowedPeers] the peers admitted by the policies `contacts` and
  ///   `specificPeers`: names, addresses or product instance ids.
  /// - [address] the local address the session binds to.
  /// - [productInstanceId] the Product Instance Id of a Network MIDI 2.0
  ///   session; random when null.
  /// - [credentialsFor], [requiredSecret], [requiredUsers] the
  ///   authentication of Network MIDI 2.0 sessions.
  /// - `timerFactory` creates the timers of the sessions.
  MidiNetworkSessionBackend({
    this.protocol = MidiNetworkProtocol.appleMidi,
    this.name = 'netmidi',
    this.advertiser,
    MidiNetworkBrowser? browser,
    Set<String> allowedPeers = const {},
    InternetAddress? address,
    this.appleMidiSettings = const MidiAppleMidiSettings(),
    this.midi2Settings = const MidiNetworkMidi2Settings(),
    this.productInstanceId,
    this.credentialsFor,
    this.requiredSecret,
    List<MidiNetworkMidi2UserCredentials> requiredUsers = const [],
    this._timerFactory = Timer.new,
  }) : browser = browser ?? MidiNetworkBrowser(),
       allowedPeers = Set.unmodifiable(allowedPeers),
       address = address ?? InternetAddress.anyIPv4,
       requiredUsers = List.unmodifiable(requiredUsers);

  // ...........................................................................
  /// Starts the backend; throws a [StateError] when it runs already.
  @override
  Future<void> start(MidiBackendHost host) async {
    if (_host != null) {
      throw StateError('The backend $name runs already');
    }
    _host = host;
  }

  /// Disables the session and stops the backend.
  @override
  Future<void> stop() async {
    await disable();
    _host = null;
  }

  // ...........................................................................
  /// Opens [port]; throws a [MidiPortGone] for an unknown port.
  @override
  Future<void> openPort(MidiPortId port) async {
    _require(port);
    _openPorts.add(port);
  }

  /// Closes [port]; does nothing for a port that is unknown or not open.
  @override
  Future<void> closePort(MidiPortId port) async {
    _openPorts.remove(port);
  }

  /// Sends [packet] to the peer of the output [port] at once.
  ///
  /// Throws a [MidiPortGone] for an unknown port, an [ArgumentError] for an
  /// input, a [MidiUnsupported] for a packet of the other raw form and a
  /// [StateError] for a port that is not open.
  @override
  Future<void> send(MidiPortId port, MidiPacket packet) async {
    final entry = _requireOutput(port);
    if ((packet is MidiUmpPacket) != entry.info.capabilities.ump) {
      throw MidiUnsupported('${packet.runtimeType} on $port');
    }
    if (!_openPorts.contains(port)) {
      throw StateError('$port is not open');
    }
    await entry.connection.send(packet);
  }

  /// Does nothing: the ports send at once and keep nothing pending; throws
  /// like [send] for unknown ports and inputs.
  @override
  Future<void> cancelPending(MidiPortId port) async {
    _requireOutput(port);
  }

  // ...........................................................................
  /// Enables a session named [name] on [port] — the AppleMIDI control port,
  /// 5004 by default, or the Network MIDI 2.0 port, chosen by the system by
  /// default — and announces it; a running session is disabled first.
  ///
  /// Throws a [StateError] before [start] and a [SocketException] when the
  /// port is taken.
  @override
  Future<MidiNetworkSessionInfo> enable({
    required String name,
    int? port,
    MidiNetworkConnectionPolicy policy = MidiNetworkConnectionPolicy.anyone,
  }) async {
    final host = _host;
    if (host == null) {
      throw StateError('The backend ${this.name} does not run');
    }
    await disable();
    final access = MidiNetworkAccess(
      policy: policy,
      allowedPeers: allowedPeers,
    );
    final MidiNetworkSession session = protocol == MidiNetworkProtocol.appleMidi
        ? MidiAppleMidiSession(
            localName: name,
            requestedPort: port ?? MidiAppleMidiSession.defaultPort,
            address: address,
            access: access,
            settings: appleMidiSettings,
            clock: host.clock,
            timerFactory: _timerFactory,
          )
        : MidiNetworkMidi2Session(
            localName: name,
            productInstanceId: productInstanceId,
            requestedPort: port ?? 0,
            address: address,
            access: access,
            credentialsFor: credentialsFor,
            requiredSecret: requiredSecret,
            requiredUsers: requiredUsers,
            settings: midi2Settings,
            clock: host.clock,
            timerFactory: _timerFactory,
          );
    await session.open();
    _session = session;
    _localName = name;
    _policy = policy;
    _subscriptions = [
      session.connectionChanges.listen(_onConnectionChanged),
      session.received.listen(_onReceived),
      session.losses.listen(_onLoss),
    ];
    await _advertise(session);
    _publish();
    return this.session;
  }

  /// Withdraws the announcement and ends the session and its connections;
  /// their ports disappear.
  @override
  Future<void> disable() async {
    final session = _session;
    if (session == null) {
      return;
    }
    final registration = _registration;
    _registration = null;
    await registration?.unregister();
    await session.close();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions = [];
    _session = null;
    _publish();
  }

  // ...........................................................................
  /// Invites [host] and returns the connection once the invitation ended;
  /// its state tells whether the host accepted.
  ///
  /// Throws a [StateError] while the session is disabled and a
  /// [MidiUnsupported] for a host of the other protocol.
  @override
  Future<MidiNetworkConnectionInfo> connect(MidiNetworkHostInfo host) async {
    final session = _session;
    if (session == null) {
      throw StateError('The network session of $name is not enabled');
    }
    if (host.serviceType != serviceType) {
      throw MidiUnsupported(
        'A ${host.serviceType} host in a $serviceType session',
      );
    }
    return _infoOf(await session.connect(host));
  }

  @override
  Future<void> disconnect(MidiNetworkHostInfo host) async =>
      _session?.disconnect(host);

  /// Browses for sessions of [protocol] with [browser].
  @override
  Stream<List<MidiNetworkHostInfo>> browse() => browser.browse(serviceType);

  // ...........................................................................
  /// The protocol of the sessions.
  final MidiNetworkProtocol protocol;

  @override
  final String name;

  /// Announces the session, or null.
  final MidiServiceAdvertiser? advertiser;

  /// Finds hosts on the local network.
  final MidiNetworkBrowser browser;

  /// The peers the policies `contacts` and `specificPeers` admit; cannot be
  /// modified.
  final Set<String> allowedPeers;

  /// The local address the session binds to.
  final InternetAddress address;

  /// The timing of AppleMIDI sessions.
  final MidiAppleMidiSettings appleMidiSettings;

  /// The timing of Network MIDI 2.0 sessions.
  final MidiNetworkMidi2Settings midi2Settings;

  /// The Product Instance Id of a Network MIDI 2.0 session, or null for a
  /// random one.
  final String? productInstanceId;

  /// Returns the credentials for a Network MIDI 2.0 host that asks.
  final MidiNetworkMidi2Credentials? Function(MidiNetworkHostInfo host)?
  credentialsFor;

  /// The shared secret Network MIDI 2.0 clients must prove, or null.
  final MidiNetworkMidi2SharedSecret? requiredSecret;

  /// The users Network MIDI 2.0 clients log in as; cannot be modified.
  final List<MidiNetworkMidi2UserCredentials> requiredUsers;

  /// The DNS-SD service type of [protocol].
  String get serviceType => protocol == MidiNetworkProtocol.appleMidi
      ? MidiNetworkHostInfo.appleMidiServiceType
      : MidiNetworkHostInfo.networkMidi2ServiceType;

  @override
  MidiCapabilities get capabilities => MidiCapabilities(
    network: {
      protocol == MidiNetworkProtocol.appleMidi
          ? MidiNetworkSupport.appleMidi
          : MidiNetworkSupport.networkMidi2,
    },
    ump: protocol == MidiNetworkProtocol.networkMidi2,
  );

  @override
  List<MidiPortInfo> get ports => [
    for (final pair in _ports.values) ...[pair.input, pair.output],
  ];

  @override
  MidiVirtualPortsBackend? get virtualPorts => null;

  @override
  MidiBluetoothBackend? get bluetooth => null;

  @override
  MidiNetworkBackend get network => this;

  @override
  MidiNetworkSessionInfo get session {
    final session = _session;
    return MidiNetworkSessionInfo(
      localName: _localName,
      enabled: session != null,
      port: session?.port ?? 0,
      protocol: protocol,
      connectionPolicy: _policy,
      connections: [
        for (final connection
            in session?.connections ?? const <MidiNetworkConnection>[])
          _infoOf(connection),
      ],
    );
  }

  @override
  Stream<MidiNetworkSessionInfo> get sessionChanges => _changes.stream;

  // ...........................................................................
  final MidiTimerFactory _timerFactory;
  MidiBackendHost? _host;
  MidiNetworkSession? _session;
  MidiServiceRegistration? _registration;
  var _subscriptions = <StreamSubscription<Object?>>[];
  var _localName = '';
  var _policy = MidiNetworkConnectionPolicy.anyone;
  final _ports =
      <MidiNetworkConnection, ({MidiPortInfo input, MidiPortInfo output})>{};
  final _byPort =
      <MidiPortId, ({MidiNetworkConnection connection, MidiPortInfo info})>{};
  final _openPorts = <MidiPortId>{};
  final _changes = StreamController<MidiNetworkSessionInfo>.broadcast();

  ({MidiNetworkConnection connection, MidiPortInfo info}) _require(
    MidiPortId port,
  ) => _byPort[port] ?? (throw MidiPortGone(port));

  ({MidiNetworkConnection connection, MidiPortInfo info}) _requireOutput(
    MidiPortId port,
  ) {
    final entry = _require(port);
    if (entry.info.isInput) {
      throw ArgumentError.value(port, 'port', 'Is an input');
    }
    return entry;
  }

  MidiNetworkConnectionInfo _infoOf(MidiNetworkConnection connection) {
    final pair = _ports[connection];
    return connection.info.copyWith(
      portIds: pair == null ? const [] : [pair.input.id, pair.output.id],
    );
  }

  Future<void> _advertise(MidiNetworkSession session) async {
    final advertiser = this.advertiser;
    if (advertiser == null) {
      return;
    }
    try {
      _registration = await advertiser.register(
        name: session.localName,
        type: serviceType,
        port: session.port,
        txt: session is MidiNetworkMidi2Session ? session.txtRecord : const {},
      );
    } on Object catch (error) {
      _host!.diagnostic(
        MidiDiagnostic(
          kind: MidiDiagnosticKind.nativeError,
          cause: 'Announcing ${session.localName} failed: $error',
          time: _host!.clock.now(),
        ),
      );
    }
  }

  void _publish() => _changes.add(session);

  void _onConnectionChanged(MidiNetworkConnection connection) {
    final connected = connection.state == MidiNetworkConnectionState.connected;
    final known = _ports.containsKey(connection);
    if (connected && !known) {
      _addPorts(connection);
    } else if (!connected && known) {
      _removePorts(connection);
    }
    _publish();
  }

  void _addPorts(MidiNetworkConnection connection) {
    final host = connection.host;
    final key = '${host.address}:${host.port}';
    final midi2 = protocol == MidiNetworkProtocol.networkMidi2;
    final instanceId = connection is MidiNetworkMidi2Connection
        ? connection.remoteProductInstanceId
        : '';
    MidiPortInfo port(MidiDirection direction) => MidiPortInfo(
      id: MidiPortId.of(
        backend: name,
        nativeId: '$key/${direction == MidiDirection.input ? 'in' : 'out'}',
      ),
      deviceId: MidiDeviceId.of(backend: name, nativeId: key),
      name: connection.remoteName,
      direction: direction,
      transport: MidiTransport.network,
      protocol: midi2 ? MidiProtocol.midi2 : MidiProtocol.midi1,
      capabilities: MidiPortCapabilities(timestampsIn: true, ump: midi2),
      serialNumber: instanceId,
      native: {
        'address': host.address,
        'port': host.port,
        'incoming': connection.isIncoming,
        'serviceType': serviceType,
      },
    );
    final pair = (
      input: port(MidiDirection.input),
      output: port(MidiDirection.output),
    );
    _ports[connection] = pair;
    _byPort[pair.input.id] = (connection: connection, info: pair.input);
    _byPort[pair.output.id] = (connection: connection, info: pair.output);
    _host?.portsChanged([
      MidiPortAdded(port: pair.input),
      MidiPortAdded(port: pair.output),
    ]);
  }

  void _removePorts(MidiNetworkConnection connection) {
    final pair = _ports.remove(connection)!;
    for (final info in [pair.input, pair.output]) {
      _byPort.remove(info.id);
      _openPorts.remove(info.id);
    }
    _host?.portsChanged([
      MidiPortRemoved(port: pair.input),
      MidiPortRemoved(port: pair.output),
    ]);
  }

  void _onReceived(MidiNetworkReceived received) {
    final input = _ports[received.connection]?.input.id;
    if (input != null && _openPorts.contains(input)) {
      _host?.received(input, received.packet);
    }
  }

  void _onLoss(MidiNetworkLoss loss) {
    final host = _host;
    host?.diagnostic(
      MidiDiagnostic(
        kind: MidiDiagnosticKind.networkLoss,
        port: _ports[loss.connection]?.input.id,
        count: loss.count,
        cause: loss.cause,
        time: host.clock.now(),
      ),
    );
  }
}
