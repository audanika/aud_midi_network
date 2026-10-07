// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';
import 'package:multicast_dns/multicast_dns.dart';

// #############################################################################
/// Finds network MIDI sessions on the local network with multicast DNS
/// queries (DNS-SD, RFC 6763): the PTR records of a service type name the
/// instances, their SRV records the host and port, and the A or AAAA
/// records of the host its address.
///
/// The browser only asks; it answers nobody and advertises nothing.
/// Sessions are announced through the operating system's registrar.
final class MidiNetworkBrowser {
  /// Creates a browser.
  ///
  /// - [createClient] creates the mDNS client of one browse; tests pass a
  ///   fake.
  /// - [queryInterval] the time between two query rounds.
  /// - [lookupTimeout] how long a round waits for answers to one query.
  /// - [missedRounds] the rounds without answer after which a host counts
  ///   as gone.
  /// - `timerFactory` waits between the rounds; tests pass fake timers.
  MidiNetworkBrowser({
    this.createClient = MDnsClient.new,
    this.queryInterval = const Duration(seconds: 5),
    this.lookupTimeout = const Duration(seconds: 2),
    this.missedRounds = 3,
    this._timerFactory = Timer.new,
  });

  // ...........................................................................
  /// Browses for sessions of [serviceType], e.g.
  /// [MidiNetworkHostInfo.appleMidiServiceType], and reports the hosts
  /// sorted by name after the first round and after every change.
  ///
  /// Browsing runs while the stream has a listener. When the mDNS client
  /// cannot start, e.g. without network permission, the stream reports
  /// that error and closes.
  Stream<List<MidiNetworkHostInfo>> browse(String serviceType) {
    final browse = _Browse(this, serviceType);
    return browse.controller.stream;
  }

  // ...........................................................................
  /// Creates the mDNS client of one browse.
  final MDnsClient Function() createClient;

  /// The time between two query rounds.
  final Duration queryInterval;

  /// How long a round waits for answers to one query.
  final Duration lookupTimeout;

  /// The rounds without answer after which a host counts as gone.
  final int missedRounds;

  // ...........................................................................
  final MidiTimerFactory _timerFactory;

  /// Returns the instance name of [domainName], e.g. `Studio` for
  /// `Studio._apple-midi._udp.local`.
  static String _instanceName(String domainName, String serviceType) {
    var name = domainName.endsWith('.')
        ? domainName.substring(0, domainName.length - 1)
        : domainName;
    final suffix = '.$serviceType.local';
    if (name.toLowerCase().endsWith(suffix.toLowerCase())) {
      name = name.substring(0, name.length - suffix.length);
    }
    return name;
  }
}

// #############################################################################
/// One running browse.
class _Browse {
  _Browse(this.browser, this.serviceType) {
    controller = StreamController<List<MidiNetworkHostInfo>>(
      onListen: () => unawaited(_start()),
      onCancel: _stop,
    );
  }

  final MidiNetworkBrowser browser;
  final String serviceType;
  late final StreamController<List<MidiNetworkHostInfo>> controller;
  final _hosts = <String, ({MidiNetworkHostInfo host, int missed})>{};
  MDnsClient? _client;
  Timer? _timer;
  List<MidiNetworkHostInfo>? _reported;
  var _active = true;

  Future<void> _start() async {
    final client = _client = browser.createClient();
    try {
      await client.start();
    } on Object catch (error, stackTrace) {
      controller.addError(error, stackTrace);
      await controller.close();
      return;
    }
    if (!_active) {
      client.stop();
      return;
    }
    await _round();
  }

  void _stop() {
    _active = false;
    _timer?.cancel();
    _client?.stop();
  }

  Future<void> _round() async {
    final Map<String, MidiNetworkHostInfo> found;
    try {
      found = await _query();
    } on StateError {
      // The listener cancelled and stopped the client during the round.
      return;
    }
    if (!_active) {
      return;
    }
    for (final entry in _hosts.entries.toList()) {
      if (!found.containsKey(entry.key)) {
        final missed = entry.value.missed + 1;
        if (missed >= browser.missedRounds) {
          _hosts.remove(entry.key);
        } else {
          _hosts[entry.key] = (host: entry.value.host, missed: missed);
        }
      }
    }
    for (final entry in found.entries) {
      _hosts[entry.key] = (host: entry.value, missed: 0);
    }
    _report();
    _timer = browser._timerFactory(
      browser.queryInterval,
      () => unawaited(_round()),
    );
  }

  void _report() {
    final hosts = [for (final entry in _hosts.values) entry.host]
      ..sort((a, b) => a.name.compareTo(b.name));
    final last = _reported;
    if (last != null &&
        last.length == hosts.length &&
        Iterable<int>.generate(
          hosts.length,
        ).every((i) => last[i] == hosts[i])) {
      return;
    }
    _reported = hosts;
    controller.add(List.unmodifiable(hosts));
  }

  Future<Map<String, MidiNetworkHostInfo>> _query() async {
    final client = _client!;
    final instances = <String>{};
    await for (final pointer in client.lookup<PtrResourceRecord>(
      ResourceRecordQuery.serverPointer('$serviceType.local'),
      timeout: browser.lookupTimeout,
    )) {
      instances.add(pointer.domainName);
    }
    final found = <String, MidiNetworkHostInfo>{};
    for (final instance in instances) {
      final host = await _resolve(client, instance);
      if (host != null) {
        found[instance] = host;
      }
    }
    return found;
  }

  Future<MidiNetworkHostInfo?> _resolve(
    MDnsClient client,
    String instance,
  ) async {
    final service = await _first(
      client.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(instance),
        timeout: browser.lookupTimeout,
      ),
    );
    if (service == null) {
      return null;
    }
    final address =
        await _first(
          client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(service.target),
            timeout: browser.lookupTimeout,
          ),
        ) ??
        await _first(
          client.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv6(service.target),
            timeout: browser.lookupTimeout,
          ),
        );
    if (address == null) {
      return null;
    }
    return MidiNetworkHostInfo(
      name: MidiNetworkBrowser._instanceName(instance, serviceType),
      address: address.address.address,
      port: service.port,
      source: MidiNetworkHostSource.bonjour,
      serviceType: serviceType,
    );
  }

  static Future<T?> _first<T extends Object>(Stream<T> stream) =>
      stream.cast<T?>().firstWhere((_) => true, orElse: () => null);
}
