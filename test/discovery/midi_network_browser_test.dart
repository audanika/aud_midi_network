// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:test/test.dart';

void main() {
  const apple = MidiNetworkHostInfo.appleMidiServiceType;

  late _FakeMdnsClient client;

  setUp(() => client = _FakeMdnsClient());

  MidiNetworkBrowser browser() => MidiNetworkBrowser(
    createClient: () => client,
    queryInterval: const Duration(milliseconds: 1),
    missedRounds: 2,
  );

  void announce(String instance, {String? target, int port = 5004}) {
    client.add(PtrResourceRecord('$apple.local', 0, domainName: instance));
    if (target != null) {
      client.add(
        SrvResourceRecord(
          instance,
          0,
          target: target,
          port: port,
          priority: 0,
          weight: 0,
        ),
      );
    }
  }

  MidiNetworkHostInfo host(String name, String address, int port) =>
      MidiNetworkHostInfo(
        name: name,
        address: address,
        port: port,
        source: MidiNetworkHostSource.bonjour,
      );

  group('MidiNetworkBrowser', () {
    group('browse(serviceType)', () {
      test('resolves instances to addresses and ports', () async {
        announce('Studio._apple-midi._udp.local', target: 'studio.local');
        announce('Studio._apple-midi._udp.local');
        announce(
          'Laptop._apple-midi._udp.local.',
          target: 'laptop.local',
          port: 5006,
        );
        announce('Odd', target: 'studio.local', port: 5008);
        announce('Unresolved._apple-midi._udp.local');
        announce('Silent._apple-midi._udp.local', target: 'none.local');
        client
          ..add(
            IPAddressResourceRecord(
              'studio.local',
              0,
              address: InternetAddress('192.168.1.10'),
            ),
          )
          ..add(
            IPAddressResourceRecord(
              'laptop.local',
              0,
              address: InternetAddress('fe80::1'),
            ),
          );
        final hosts = await browser().browse(apple).first;
        expect(
          hosts,
          equals([
            host('Laptop', 'fe80::1', 5006),
            host('Odd', '192.168.1.10', 5008),
            host('Studio', '192.168.1.10', 5004),
          ]),
        );
        expect(client.queries.first, '12 $apple.local');
      });

      test('reports changes only and drops silent hosts', () async {
        announce('A._apple-midi._udp.local', target: 'a.local');
        client.add(
          IPAddressResourceRecord(
            'a.local',
            0,
            address: InternetAddress('10.0.0.1'),
          ),
        );
        final reports = <List<MidiNetworkHostInfo>>[];
        final subscription = browser().browse(apple).listen(reports.add);
        await _until(() => reports.isNotEmpty);
        expect(reports.single, equals([host('A', '10.0.0.1', 5004)]));
        await _until(() => client.rounds >= 3);
        expect(reports.length, 1);
        client.clear();
        await _until(() => reports.length == 2);
        expect(reports.last, isEmpty);
        expect(
          () => reports.last.add(host('X', '', 1)),
          throwsUnsupportedError,
        );
        await subscription.cancel();
        expect(client.stops, 1);
      });

      test('reports a client that cannot start', () async {
        client.failStart = true;
        await expectLater(
          browser().browse(apple),
          emitsInOrder([emitsError(isA<SocketException>()), emitsDone]),
        );
      });

      test('stops a client whose listener left during the start', () async {
        final subscription = browser().browse(apple).listen(null);
        await subscription.cancel();
        await pumpEventQueue();
        expect(client.stops, 2);
        expect(client.queries, isEmpty);
      });

      test('ends a round whose listener left', () async {
        announce('A._apple-midi._udp.local', target: 'a.local');
        client.holdQueries = true;
        final subscription = browser().browse(apple).listen(null);
        await _until(() => client.queries.isNotEmpty);
        await subscription.cancel();
        await pumpEventQueue();
        expect(client.queries, equals(['12 $apple.local']));
      });

      test('browses the real network', () async {
        final real = MidiNetworkBrowser(
          lookupTimeout: const Duration(milliseconds: 300),
        );
        expect(real.queryInterval, const Duration(seconds: 5));
        expect(real.missedRounds, 3);
        expect(real.lookupTimeout, const Duration(milliseconds: 300));
        Object? outcome;
        try {
          outcome = await real
              .browse(MidiNetworkHostInfo.networkMidi2ServiceType)
              .first
              .timeout(const Duration(seconds: 10));
        } on SocketException catch (e) {
          outcome = e;
        }
        expect(
          outcome,
          anyOf(isA<List<MidiNetworkHostInfo>>(), isA<SocketException>()),
        );
      });
    });
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('The condition did not become true');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

// #############################################################################
/// An mDNS client that answers from a list of records, like a network on
/// which these records are announced.
class _FakeMdnsClient implements MDnsClient {
  final _records = <ResourceRecord>[];
  final _open = <StreamController<ResourceRecord>>[];
  final queries = <String>[];
  var failStart = false;
  var holdQueries = false;
  var started = false;
  var stops = 0;
  var rounds = 0;

  void add(ResourceRecord record) => _records.add(record);

  void clear() => _records.clear();

  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {
    if (failStart) {
      throw const SocketException('No permission');
    }
    started = true;
  }

  @override
  void stop() {
    stops++;
    started = false;
    for (final controller in _open) {
      unawaited(controller.close());
    }
    _open.clear();
  }

  @override
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    if (!started) {
      throw StateError('mDNS client must be started before calling lookup.');
    }
    final type = query.resourceRecordType;
    final name = query.fullyQualifiedName;
    queries.add('$type $name');
    if (type == ResourceRecordType.serverPointer) {
      rounds++;
    }
    final controller = StreamController<T>();
    for (final record in _records) {
      if (record.resourceRecordType == type &&
          record.name == name &&
          (type != ResourceRecordType.addressIPv6 || record is T)) {
        controller.add(record as T);
      }
    }
    if (holdQueries) {
      _open.add(controller as StreamController<ResourceRecord>);
    } else {
      unawaited(controller.close());
    }
    return controller.stream;
  }

  @override
  Future<Iterable<NetworkInterface>> allInterfacesFactory(
    InternetAddressType type,
  ) => NetworkInterface.list(type: type);
}
