# aud_midi_network

Network MIDI sessions in Dart: AppleMIDI on top of aud_midi_rtp and Network MIDI 2.0, both over UDP with mDNS discovery.

Part of the aud_midi family, see [aud_midi](https://github.com/audanika/aud_midi).

## Goals

- AppleMIDI sessions: invitation, clock sync, feedback, reconnection
- Network MIDI 2.0 (UDP) with FEC and retransmission
- mDNS browsing, advertising through OS registrars
- Lossy UDP proxy for tests

## State

Boilerplate only. The implementation follows in later tickets, see the plan in [aud_midi](https://github.com/audanika/aud_midi/blob/main/blog/2026/10/01_plan_the_package_implementation.md).

## Installation

```bash
dart pub add aud_midi_network
```

## Contributing

See [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
