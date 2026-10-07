// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:io';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:test/test.dart';

void main() {
  final backends = <MidiNetworkSessionBackend>[];
  final proxies = <MidiLossyUdpProxy>[];

  tearDown(() async {
    for (final backend in backends) {
      await backend.stop();
    }
    backends.clear();
    for (final proxy in proxies) {
      await proxy.close();
    }
    proxies.clear();
  });

  const appleSettings = MidiAppleMidiSettings(
    invitationInterval: Duration(milliseconds: 50),
    maxInvitationInterval: Duration(milliseconds: 100),
    invitationAttempts: 3,
    initialSyncInterval: Duration(milliseconds: 30),
    feedbackInterval: Duration(milliseconds: 20),
  );
  const midi2Settings = MidiNetworkMidi2Settings(
    invitationInterval: Duration(milliseconds: 50),
    invitationAttempts: 3,
  );

  Future<(MidiNetworkSessionBackend, _Host)> start(
    String name, {
    MidiNetworkProtocol protocol = MidiNetworkProtocol.appleMidi,
    MidiServiceAdvertiser? advertiser,
    MidiNetworkBrowser? browser,
  }) async {
    final backend = MidiNetworkSessionBackend(
      protocol: protocol,
      name: name,
      advertiser: advertiser,
      browser: browser,
      address: InternetAddress.loopbackIPv4,
      appleMidiSettings: appleSettings,
      midi2Settings: midi2Settings,
      productInstanceId: '$name-ID',
    );
    final host = _Host();
    backends.add(backend);
    await backend.start(host);
    return (backend, host);
  }

  MidiNetworkHostInfo hostOf(MidiNetworkSessionBackend backend, {int? port}) =>
      MidiNetworkHostInfo(
        name: backend.session.localName,
        address: '127.0.0.1',
        port: port ?? backend.session.port,
        serviceType: backend.serviceType,
      );

  Future<void> eventually(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('The condition did not become true');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  MidiBytesPacket bytes(List<int> data) => MidiBytesPacket(
    bytes: MidiBytes(data),
    time: const MidiSystemClock().now(),
  );

  group('MidiNetworkSessionBackend', () {
    group('AppleMIDI', () {
      test('turns connections into byte ports', () async {
        final advertiser = _Advertiser();
        final (studio, atStudio) = await start(
          'studio',
          advertiser: advertiser,
        );
        final (laptop, atLaptop) = await start('laptop');
        final changes = <MidiNetworkSessionInfo>[];
        studio.sessionChanges.listen(changes.add);
        final info = await studio.enable(name: 'Studio', port: 0);
        expect(info.enabled, isTrue);
        expect(info.localName, 'Studio');
        expect(info.port, greaterThan(0));
        expect(info.protocol, MidiNetworkProtocol.appleMidi);
        expect(info.connectionPolicy, MidiNetworkConnectionPolicy.anyone);
        expect(
          advertiser.registered,
          equals(['Studio _apple-midi._udp ${info.port} {}']),
        );
        await laptop.enable(name: 'Laptop', port: 0);
        final connection = await laptop.connect(hostOf(studio));
        expect(connection.state, MidiNetworkConnectionState.connected);
        expect(connection.portIds, hasLength(2));
        await eventually(() => atStudio.added.length == 2);
        final input = atStudio.added.firstWhere((p) => p.isInput);
        expect(input.name, 'Laptop');
        expect(input.transport, MidiTransport.network);
        expect(input.protocol, MidiProtocol.midi1);
        expect(
          input.capabilities,
          const MidiPortCapabilities(timestampsIn: true),
        );
        expect(input.id.backend, 'studio');
        expect(input.native['incoming'], isTrue);
        expect(studio.ports, hasLength(2));
        final output = atLaptop.added.firstWhere((p) => p.isOutput);
        expect(output.id, connection.portIds.last);
        await laptop.openPort(output.id);
        await laptop.send(output.id, bytes([0x90, 60, 100]));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(atStudio.packets, isEmpty);
        await studio.openPort(input.id);
        await laptop.send(output.id, bytes([0x80, 60, 64]));
        await eventually(() => atStudio.packets.isNotEmpty);
        expect(atStudio.packets.single.$1, input.id);
        expect(
          (atStudio.packets.single.$2 as MidiBytesPacket).bytes.toHex(),
          '80 3c 40',
        );
        expect(studio.session.connections.single.portIds, hasLength(2));
        expect(changes, isNotEmpty);
        await studio.closePort(input.id);
        await laptop.disconnect(hostOf(studio));
        await eventually(() => atStudio.removed.length == 2);
        expect(studio.ports, isEmpty);
        expect(atLaptop.removed.length, 2);
        await studio.disable();
        expect(studio.session.enabled, isFalse);
        expect(studio.session.localName, 'Studio');
        expect(studio.session.port, 0);
        expect(advertiser.registered, isEmpty);
      });

      test('reports losses as diagnostics of the input', () async {
        final (studio, atStudio) = await start('studio');
        final (laptop, atLaptop) = await start('laptop');
        await studio.enable(name: 'Studio', port: 0);
        await laptop.enable(name: 'Laptop', port: 0);
        final proxy = await MidiLossyUdpProxy.start(
          target: InternetAddress.loopbackIPv4,
          targetPort: studio.session.port,
          portCount: 2,
        );
        proxies.add(proxy);
        final connection = await laptop.connect(
          hostOf(studio, port: proxy.port),
        );
        final output = atLaptop.added.firstWhere((p) => p.isOutput);
        await laptop.openPort(output.id);
        await laptop.send(output.id, bytes([0x90, 60, 100]));
        // Drops the packet whose command list holds the Note Off: it
        // follows the RTP header and the command section header.
        var dropped = false;
        proxy.dropWhere = (index, toTarget, data) {
          final noteOff =
              toTarget &&
              index == 1 &&
              !dropped &&
              data.length > 15 &&
              data[13] == 0x80 &&
              data[14] == 60 &&
              data[15] == 64;
          dropped = dropped || noteOff;
          return noteOff;
        };
        await laptop.send(output.id, bytes([0x80, 60, 64]));
        await eventually(() => dropped);
        await laptop.send(output.id, bytes([0x90, 62, 100]));
        await eventually(() => atStudio.diagnostics.isNotEmpty);
        final diagnostic = atStudio.diagnostics.single;
        expect(diagnostic.kind, MidiDiagnosticKind.networkLoss);
        expect(diagnostic.count, 1);
        expect(diagnostic.port, atStudio.added.firstWhere((p) => p.isInput).id);
        expect(connection.state, MidiNetworkConnectionState.connected);
      });

      test('returns the failed connection of a silent host', () async {
        final (laptop, _) = await start('laptop');
        await laptop.enable(name: 'Laptop', port: 0);
        final silent = await midiBindAdjacent(
          address: InternetAddress.loopbackIPv4,
          count: 2,
        );
        addTearDown(() {
          for (final socket in silent) {
            socket.close();
          }
        });
        final info = await laptop.connect(
          MidiNetworkHostInfo(
            name: 'Nobody',
            address: '127.0.0.1',
            port: silent.first.port,
          ),
        );
        expect(info.state, MidiNetworkConnectionState.failed);
        expect(info.portIds, isEmpty);
      });
    });

    group('Network MIDI 2.0', () {
      test('turns connections into UMP ports', () async {
        final advertiser = _Advertiser();
        final (host, atHost) = await start(
          'host',
          protocol: MidiNetworkProtocol.networkMidi2,
          advertiser: advertiser,
        );
        final (client, atClient) = await start(
          'client',
          protocol: MidiNetworkProtocol.networkMidi2,
        );
        final info = await host.enable(name: 'Host');
        expect(info.protocol, MidiNetworkProtocol.networkMidi2);
        expect(
          advertiser.registered,
          equals([
            'Host _midi2._udp ${info.port} '
                '{UMPEndpointName: Host, ProductInstanceId: host-ID}',
          ]),
        );
        await client.enable(name: 'Client');
        await client.connect(hostOf(host));
        await eventually(() => atHost.added.length == 2);
        final input = atHost.added.firstWhere((p) => p.isInput);
        expect(input.protocol, MidiProtocol.midi2);
        expect(input.capabilities.ump, isTrue);
        expect(input.serialNumber, 'client-ID');
        final output = atClient.added.firstWhere((p) => p.isOutput);
        expect(output.name, 'Host');
        await host.openPort(input.id);
        await client.openPort(output.id);
        await expectLater(
          client.send(output.id, bytes([0x90, 60, 100])),
          throwsA(isA<MidiUnsupported>()),
        );
        await client.send(
          output.id,
          MidiUmpPacket(
            words: const [0x40903C00, 0xC8000000],
            time: const MidiSystemClock().now(),
          ),
        );
        await eventually(() => atHost.packets.isNotEmpty);
        expect(
          (atHost.packets.single.$2 as MidiUmpPacket).words,
          equals([0x40903C00, 0xC8000000]),
        );
        expect(host.capabilities.ump, isTrue);
        expect(
          host.capabilities.network,
          equals({MidiNetworkSupport.networkMidi2}),
        );
        expect(host.serviceType, '_midi2._udp');
      });
    });

    group('errors', () {
      test('refuse unknown ports, inputs and closed ports', () async {
        final (studio, atStudio) = await start('studio');
        final (laptop, _) = await start('laptop');
        await studio.enable(name: 'Studio', port: 0);
        await laptop.enable(name: 'Laptop', port: 0);
        await laptop.connect(hostOf(studio));
        await eventually(() => atStudio.added.length == 2);
        final input = atStudio.added.firstWhere((p) => p.isInput);
        final output = atStudio.added.firstWhere((p) => p.isOutput);
        const unknown = MidiPortId('studio:none');
        await expectLater(
          studio.openPort(unknown),
          throwsA(isA<MidiPortGone>().having((e) => e.port, 'port', unknown)),
        );
        await studio.closePort(unknown);
        await expectLater(
          studio.send(unknown, bytes([0xF8])),
          throwsA(isA<MidiPortGone>()),
        );
        await expectLater(
          studio.send(input.id, bytes([0xF8])),
          throwsA(isA<ArgumentError>()),
        );
        await expectLater(
          studio.send(output.id, bytes([0xF8])),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              '${output.id} is not open',
            ),
          ),
        );
        await expectLater(
          studio.cancelPending(input.id),
          throwsA(isA<ArgumentError>()),
        );
        await studio.cancelPending(output.id);
        await expectLater(
          studio.connect(
            const MidiNetworkHostInfo(
              name: 'X',
              address: '127.0.0.1',
              port: 1,
              serviceType: MidiNetworkHostInfo.networkMidi2ServiceType,
            ),
          ),
          throwsA(isA<MidiUnsupported>()),
        );
      });

      test('refuse to enable before start or connect while disabled', () async {
        final backend = MidiNetworkSessionBackend();
        await expectLater(
          backend.enable(name: 'S'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'The backend netmidi does not run',
            ),
          ),
        );
        await expectLater(
          backend.connect(
            const MidiNetworkHostInfo(name: 'X', address: '1.2.3.4', port: 1),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'The network session of netmidi is not enabled',
            ),
          ),
        );
        await backend.disconnect(
          const MidiNetworkHostInfo(name: 'X', address: '1.2.3.4', port: 1),
        );
        await backend.start(_Host());
        await expectLater(backend.start(_Host()), throwsA(isA<StateError>()));
        await backend.stop();
      });

      test('report an announcement that fails', () async {
        final (studio, atStudio) = await start(
          'studio',
          advertiser: _Advertiser()..fail = true,
        );
        final info = await studio.enable(name: 'Studio', port: 0);
        expect(info.enabled, isTrue);
        expect(
          atStudio.diagnostics.single.kind,
          MidiDiagnosticKind.nativeError,
        );
        expect(
          atStudio.diagnostics.single.cause,
          'Announcing Studio failed: Bad state: No registrar',
        );
        final again = await studio.enable(
          name: 'Studio 2',
          port: 0,
          policy: MidiNetworkConnectionPolicy.specificPeers,
        );
        expect(again.localName, 'Studio 2');
        expect(
          again.connectionPolicy,
          MidiNetworkConnectionPolicy.specificPeers,
        );
      });
    });

    group('browse()', () {
      test('browses the service type of the protocol', () async {
        final client = _FailingMdnsClient();
        final (backend, _) = await start(
          'b',
          browser: MidiNetworkBrowser(createClient: () => client),
        );
        await expectLater(
          backend.browse(),
          emitsInOrder([emitsError(isA<SocketException>()), emitsDone]),
        );
      });
    });

    group('fields', () {
      test('describe the backend', () {
        final backend = MidiNetworkSessionBackend(allowedPeers: {'A'});
        expect(backend.name, 'netmidi');
        expect(backend.protocol, MidiNetworkProtocol.appleMidi);
        expect(backend.serviceType, '_apple-midi._udp');
        expect(backend.network, same(backend));
        expect(backend.virtualPorts, isNull);
        expect(backend.bluetooth, isNull);
        expect(backend.ports, isEmpty);
        expect(backend.allowedPeers, equals({'A'}));
        expect(backend.address, InternetAddress.anyIPv4);
        expect(backend.advertiser, isNull);
        expect(backend.browser, isA<MidiNetworkBrowser>());
        expect(backend.appleMidiSettings.invitationAttempts, 12);
        expect(backend.midi2Settings.invitationAttempts, 5);
        expect(backend.productInstanceId, isNull);
        expect(backend.credentialsFor, isNull);
        expect(backend.requiredSecret, isNull);
        expect(backend.requiredUsers, isEmpty);
        expect(
          backend.capabilities.network,
          equals({MidiNetworkSupport.appleMidi}),
        );
        expect(backend.capabilities.ump, isFalse);
        expect(
          backend.session,
          MidiNetworkSessionInfo(
            localName: '',
            enabled: false,
            port: 0,
            protocol: MidiNetworkProtocol.appleMidi,
            connectionPolicy: MidiNetworkConnectionPolicy.anyone,
          ),
        );
      });
    });
  });
}

// #############################################################################
/// Records what a backend reports.
class _Host implements MidiBackendHost {
  final added = <MidiPortInfo>[];
  final removed = <MidiPortInfo>[];
  final packets = <(MidiPortId, MidiPacket)>[];
  final diagnostics = <MidiDiagnostic>[];

  @override
  MidiClock get clock => const MidiSystemClock();

  @override
  void portsChanged(List<MidiPortEvent> events) {
    for (final event in events) {
      switch (event) {
        case MidiPortAdded(:final port):
          added.add(port);
        case MidiPortRemoved(:final port):
          removed.add(port);
        case MidiPortChanged():
          break;
      }
    }
  }

  @override
  void received(MidiPortId port, MidiPacket packet) =>
      packets.add((port, packet));

  @override
  void diagnostic(MidiDiagnostic diagnostic) => diagnostics.add(diagnostic);
}

// #############################################################################
/// An advertiser that keeps its registrations in a list.
class _Advertiser implements MidiServiceAdvertiser {
  final registered = <String>[];
  var fail = false;

  @override
  Future<MidiServiceRegistration> register({
    required String name,
    required String type,
    required int port,
    Map<String, String> txt = const {},
  }) async {
    if (fail) {
      throw StateError('No registrar');
    }
    final entry = '$name $type $port $txt';
    registered.add(entry);
    return _Registration(name, () => registered.remove(entry));
  }
}

class _Registration implements MidiServiceRegistration {
  _Registration(this.name, this._remove);

  @override
  final String name;

  final void Function() _remove;

  @override
  Future<void> unregister() async => _remove();
}

// #############################################################################
/// An mDNS client without network access.
class _FailingMdnsClient implements MDnsClient {
  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async => throw const SocketException('No network');

  @override
  void stop() {}

  @override
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) => const Stream.empty();

  @override
  Future<Iterable<NetworkInterface>> allInterfacesFactory(
    InternetAddressType type,
  ) async => const [];
}
