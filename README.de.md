# aud_midi_network

Netzwerk-MIDI-Sessions in Dart: AppleMIDI auf Basis von aud_midi_rtp und Network MIDI 2.0, beide über UDP mit mDNS-Discovery.

Teil der aud_midi-Familie, siehe [aud_midi](https://github.com/audmidi/aud_midi).

## Ziele

- AppleMIDI-Sessions: Einladung, Clock-Sync, Feedback, Reconnect
- Network MIDI 2.0 (UDP) mit FEC und Retransmission
- mDNS-Suche, Advertising über OS-Registrare
- UDP-Proxy mit Paketverlust für Tests

## Stand

Reines Dart auf `dart:io` (`RawDatagramSocket`); läuft auf macOS, Linux,
Windows und Android, ohne Flutter.

- **AppleMIDI** (`MidiAppleMidiSession`, `MidiAppleMidiConnection`): das
  Session-Protokoll von Apples Netzwerktreiber auf einem Control-Port und
  dem Daten-Port darüber (Standard 5004/5005). Initiator und Responder;
  IN/OK/NO/BY auf beiden Ports mit Wiederholung und Backoff,
  Protokollversion 2, Initiator-Token, SSRC, Name; CK-Drei-Wege-Clock-Sync
  in Einheiten von 100 µs (ein Schwall zu Beginn, dann alle 10 s) mit
  Ausreißer- und Drift-Filter; RS-Receiver-Feedback, das das
  Closed-Loop-Journal des Senders steuert; RL wird gemerkt. RTP-MIDI kommt
  aus `aud_midi_rtp`: Payload-Typ 97, 10-kHz-Session-Clock,
  Recovery-Journal in jedem Paket, Guard-Pakete nach Daten, damit auch ein
  verlorenes letztes Paket repariert wird. Empfangszeiten sind die
  RTP-Zeiten des Senders, umgerechnet auf die Paket-Clock, auch über den
  32-Bit-Überlauf. Sessions enden mit BY oder nach Stille (fehlende
  CK-Antworten, 75 s ohne Verkehr); der Initiator lädt erneut ein, bis die
  Gegenseite antwortet; Noten, die eine verlorene Gegenseite klingen
  ließ, werden beendet.
- **Network MIDI 2.0** (`MidiNetworkMidi2Session`,
  `MidiNetworkMidi2Connection`, M2-124-UM): Host und Client auf einem
  UDP-Port; Einladung, Pending, Authentifizierung mit Shared Secret oder
  Benutzername und Passwort (SHA-256-Digests), Ping, Bye, NAK, Session
  Reset; UMP-Data-Kommandos mit Sequenznummern, Forward Error Correction
  (die letzten Kommandos wiederholen sich in jedem Datagramm, leere
  Kommandos halten sie nach Daten am Laufen), Retransmit-Anfragen und
  -Fehler, Verluste nur für Lücken, die nichts schließen konnte.
- **Backend** `MidiNetworkSessionBackend` (Name `netmidi`) implementiert
  `MidiBackend` und `MidiNetworkBackend` aus
  [aud_midi_core](https://github.com/audmidi/aud_midi_core): eine Session
  eines Protokolls; jede Verbindung wird ein Eingangs- und ein
  Ausgangsport (Transport `network`, `timestampsIn`; Byte-Ports für
  AppleMIDI, UMP-Ports für Network MIDI 2.0); Port-Events bei Verbindung
  und Trennung; Verluste als `networkLoss`-Diagnosen; Policies `anyone`,
  `contacts` und `specificPeers` (erlaubte Namen, Adressen oder Product
  Instance Ids).
- **Discovery**: `MidiNetworkBrowser` fragt `_apple-midi._udp` und
  `_midi2._udp` mit `multicast_dns` ab (PTR → SRV → A/AAAA). Advertising
  läuft über einen `MidiServiceAdvertiser` eines OS-Backends.
- **Tests**: `MidiLossyUdpProxy` leitet UDP zwischen Endpunkten weiter, mit
  geseedetem Verlust, Burst-Verlust, Umordnung, Duplikaten und Verzögerung.

Geprüft auf macOS 27 (Apple Silicon) mit echtem UDP auf localhost; 269
Tests (der Interop-Test unten ist standardmäßig übersprungen), jede Datei
zu 100 % von ihrem eigenen Test abgedeckt:

| Prüfung | Ergebnis |
| --- | --- |
| Zwei AppleMIDI-Sessions, Noten, Controller, SysEx mit 3000 Bytes | zugestellt; SysEx segmentiert und wieder zusammengesetzt |
| CK-Clock-Sync auf localhost | umgerechnete Zeiten 25–152 µs neben der Senderzeit (Median 95 µs, ein RTP-Tick sind 100 µs); die Offsets beider Seiten stimmen auf 6 µs überein |
| Dasselbe mit 0,5 ms Verzögerung und 0–2 ms Jitter | höchstens 175 µs |
| Recovery-Journal durch den Verlust-Proxy: 10 % Verlust mit Bursts, 5 % Umordnung, 3 % Duplikate, 400 Noten und Controller-Änderungen | Empfänger konvergiert: keine hängenden Noten, jeder Controller stimmt |
| Gezogenes Kabel (blockierter Proxy) | beide Seiten laufen in den Timeout, der Initiator lädt erneut ein, bis der Responder antwortet |
| Ablehnung per Policy, BY, Daten-Port von anderem Socket | NO, Trennung, Port übernommen |
| Zwei Network-MIDI-2.0-Sessions durch den Verlust-Proxy, 300 UMPs | alle in Reihenfolge zugestellt, jeder Verlust behoben |
| FEC ohne Retransmission, 3 von 10 Daten-Datagrammen verworfen | Lücken als Verluste gemeldet |
| Authentifizierungs-Digests | die Beispiele aus M2-124-UM 6.9 und 6.10 |

Interoperabilität: AppleMIDI folgt dem Wire-Format von Apples Treiber und
RFC 6295; `test/apple_midi/midi_apple_midi_interop_test.dart` tritt der
Netzwerk-Session von macOS („Session 1") bei, läuft aber nur mit
`AUD_MIDI_TEST_APPLE_INTEROP=1`, weil das Aktivieren dieser Session eine
globale Einstellung ändert — er ist noch nicht gelaufen. Network MIDI 2.0
folgt den Implementierungen von Zephyr und Windows MIDI Services; gegen
andere Implementierungen ist es noch nicht getestet.

Firewall und Berechtigungen: eingehendes UDP auf Control- und Daten-Port
(standardmäßig 5004 und 5005) oder auf dem Network-MIDI-2.0-Port, dazu
mDNS (UDP 5353, Multicast). iOS: `NSLocalNetworkUsageDescription`,
`NSBonjourServices` mit `_apple-midi._udp` und `_midi2._udp`.
macOS-Sandbox: `com.apple.security.network.client` und
`com.apple.security.network.server`; ab macOS 15 fragt das System nach
Zugriff aufs lokale Netzwerk. Android: `INTERNET`,
`CHANGE_WIFI_MULTICAST_STATE`, `ACCESS_WIFI_STATE` und ein
`MulticastLock` für mDNS. Windows: eine Firewall-Abfrage für die
UDP-Ports; MSIX braucht `internetClient` und `privateNetworkClientServer`.
Linux-Sandboxes: Snap `network` und `avahi-control`, Flatpak
`--system-talk-name=org.freedesktop.Avahi`.

Siehe den Plan in [aud_midi_pm](https://github.com/audmidi/aud_midi_pm/blob/main/doc/2026-Q4/tickets/2026-10-06-aud_midi_01-initial-midi-implementation.md).

## Installation

```bash
dart pub add aud_midi_network
```

## Mitwirken

Siehe [doc/guides/develop-guide.md](doc/guides/develop-guide.md).
