# aud_midi_network

Netzwerk-MIDI-Sessions in Dart: AppleMIDI auf Basis von aud_midi_rtp und Network MIDI 2.0, beide über UDP mit mDNS-Discovery.

Teil der aud_midi-Familie, siehe [aud_midi](https://github.com/audanika/aud_midi).

## Ziele

- AppleMIDI-Sessions: Einladung, Clock-Sync, Feedback, Reconnect
- Network MIDI 2.0 (UDP) mit FEC und Retransmission
- mDNS-Suche, Advertising über OS-Registrare
- UDP-Proxy mit Paketverlust für Tests

## Stand

Nur Boilerplate. Die Implementierung folgt in späteren Tickets, siehe den Plan in [audanika_midi_pm](https://github.com/audanika/audanika_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md).

## Installation

```bash
dart pub add aud_midi_network
```

## Mitwirken

Siehe [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
