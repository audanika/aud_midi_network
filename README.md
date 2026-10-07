# aud_midi_network

Network MIDI sessions in Dart: AppleMIDI on top of aud_midi_rtp and Network MIDI 2.0, both over UDP with mDNS discovery.

Part of the aud_midi family, see [aud_midi](https://github.com/audanika/aud_midi).

## Goals

- AppleMIDI sessions: invitation, clock sync, feedback, reconnection
- Network MIDI 2.0 (UDP) with FEC and retransmission
- mDNS browsing, advertising through OS registrars
- Lossy UDP proxy for tests

## State

Pure Dart on `dart:io` (`RawDatagramSocket`); runs on macOS, Linux,
Windows and Android, without Flutter.

- **AppleMIDI** (`MidiAppleMidiSession`, `MidiAppleMidiConnection`): the
  session protocol of Apple's network driver on a control port and the
  data port above it (default 5004/5005). Initiator and responder;
  IN/OK/NO/BY on both ports with retries and backoff, protocol version 2,
  initiator token, SSRC, name; CK three-way clock sync in units of
  100 µs (a burst at the start, then every 10 s) with outlier and drift
  filtering; RS receiver feedback that drives the closed-loop journal of
  the sender; RL is kept. RTP-MIDI comes from `aud_midi_rtp`: payload type
  97, 10 kHz session clock, recovery journal in every packet, guard
  packets after data so a lost last packet is repaired too. Received
  times are the sender's RTP times mapped to the package clock, across
  the 32-bit wraparound. Sessions end on BY or after silence (missed CK
  replies, 75 s without traffic); the initiator invites again until the
  peer answers; notes left sounding by a lost peer are ended.
- **Network MIDI 2.0** (`MidiNetworkMidi2Session`,
  `MidiNetworkMidi2Connection`, M2-124-UM): host and client on one UDP
  port; invitation, pending, authentication with shared secret or user
  name and password (SHA-256 digests), ping, bye, NAK, session reset; UMP
  Data commands with sequence numbers, forward error correction (the last
  commands repeat in every datagram, empty commands keep it going after
  data), retransmit requests and errors, losses only for gaps nothing
  closed.
- **Backend** `MidiNetworkSessionBackend` (name `netmidi`) implements
  `MidiBackend` and `MidiNetworkBackend` of
  [aud_midi_core](https://github.com/audanika/aud_midi_core): one session
  of one protocol; each connection becomes an input and an output port
  (transport `network`, `timestampsIn`; byte ports for AppleMIDI, UMP
  ports for Network MIDI 2.0); port events on connect and disconnect;
  losses as `networkLoss` diagnostics; policies `anyone`, `contacts` and
  `specificPeers` (allowed names, addresses or product instance ids).
- **Discovery**: `MidiNetworkBrowser` queries `_apple-midi._udp` and
  `_midi2._udp` with `multicast_dns` (PTR → SRV → A/AAAA). Advertising
  goes through a `MidiServiceAdvertiser` of an OS backend.
- **Tests**: `MidiLossyUdpProxy` forwards UDP between endpoints with
  seeded loss, burst loss, reordering, duplication and delay.

Verified on macOS 27 (Apple silicon) with real UDP on localhost; 269
tests (the interop test below is skipped by default), every file covered
100 % by its own test:

| Check | Result |
| --- | --- |
| Two AppleMIDI sessions, notes, controllers, 3000-byte SysEx | delivered; SysEx segmented and reassembled |
| CK clock sync on localhost | mapped times 25–152 µs from the sender's time (median 95 µs, one RTP tick is 100 µs); the offsets of both sides agree within 6 µs |
| Same with 0.5 ms delay and 0–2 ms jitter | at most 175 µs |
| Recovery journal through the lossy proxy: 10 % loss with bursts, 5 % reordering, 3 % duplicates, 400 notes and controller changes | receiver converges: no hanging notes, every controller right |
| Pulled cable (blocked proxy) | both sides time out, the initiator invites again until the responder answers |
| Rejection by policy, BY, data port from another socket | NO, disconnect, port adopted |
| Two Network MIDI 2.0 sessions through the lossy proxy, 300 UMPs | all delivered in order, every loss recovered |
| FEC without retransmission, 3 of 10 data datagrams dropped | gaps reported as losses |
| Authentication digests | the examples of M2-124-UM 6.9 and 6.10 |

Interoperability: AppleMIDI follows the wire format of Apple's driver
and RFC 6295; `test/apple_midi/midi_apple_midi_interop_test.dart` joins
the macOS network session ("Session 1") but only runs with
`AUD_MIDI_TEST_APPLE_INTEROP=1`, because enabling that session changes a
global setting — it has not run yet. Network MIDI 2.0 follows the
Zephyr and Windows MIDI Services implementations; no other
implementation was tested yet.

Firewall and permissions: inbound UDP on the control and data port
(5004 and 5005 by default) or on the Network MIDI 2.0 port, and mDNS
(UDP 5353, multicast). iOS: `NSLocalNetworkUsageDescription`,
`NSBonjourServices` with `_apple-midi._udp` and `_midi2._udp`. macOS
sandbox: `com.apple.security.network.client` and
`com.apple.security.network.server`; macOS 15+ asks for local network
access. Android: `INTERNET`, `CHANGE_WIFI_MULTICAST_STATE`,
`ACCESS_WIFI_STATE` and a `MulticastLock` for mDNS. Windows: a firewall
prompt for the UDP ports; MSIX needs `internetClient` and
`privateNetworkClientServer`. Linux sandboxes: Snap `network` and
`avahi-control`, Flatpak `--system-talk-name=org.freedesktop.Avahi`.

See the plan in [aud_midi_pm](https://github.com/audanika/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md).

## Installation

```bash
dart pub add aud_midi_network
```

## Contributing

See [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
