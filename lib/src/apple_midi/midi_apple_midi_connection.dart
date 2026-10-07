// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_rtp/aud_midi_rtp.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../session/midi_network_connection.dart';
import '../session/midi_network_connection_listener.dart';
import 'midi_apple_midi_clock_sync.dart';
import 'midi_apple_midi_command.dart';
import 'midi_apple_midi_settings.dart';

// #############################################################################
/// An AppleMIDI session with one peer: the session protocol of Apple's
/// network MIDI driver around an RTP-MIDI stream (RFC 6295) in each
/// direction.
///
/// The initiator invites the responder with IN on the control port, then
/// on the data port; OK accepts, NO rejects, BY ends. The initiator
/// synchronises the clocks with three-way CK exchanges, a burst at the
/// start and then periodically. Both sides send receiver feedback (RS),
/// which lets the sender shorten its recovery journal (closed loop), and
/// guard packets after data, so a lost last packet is repaired too. Either
/// side ends the session after a silence; the initiator invites again.
///
/// The connection owns no socket: it hands datagrams to `transmit` and
/// takes the peer's commands and RTP packets through [handleCommand] and
/// [handleRtp].
final class MidiAppleMidiConnection implements MidiNetworkConnection {
  /// Creates a connection with the peer [host], whose port is the control
  /// port.
  ///
  /// - [isIncoming] whether the peer invited, i.e. this side responds.
  /// - [localName] the name this side presents.
  /// - [localSsrc] the SSRC of this side, the same for all its peers.
  /// - [transmit] sends one datagram to the peer's control or data port.
  /// - [listener] receives state changes, packets and losses.
  /// - [random] creates tokens and sequence numbers; secure by default.
  MidiAppleMidiConnection({
    required this.host,
    required this.isIncoming,
    required this.localName,
    required this.localSsrc,
    required void Function(Uint8List datagram, {required bool toDataPort})
    transmit,
    required this._listener,
    this.settings = const MidiAppleMidiSettings(),
    this._clock = const MidiSystemClock(),
    this._timerFactory = Timer.new,
    Random? random,
  }) : _transmitDatagram = transmit,
       _random = random ?? Random.secure(),
       _remoteName = host.name {
    _epoch = _clock.now();
    _initialTicks = settings.initialTimestamp ?? _random.nextInt(1 << 32);
  }

  // ...........................................................................
  /// Invites the peer and completes when the invitation ended; [state]
  /// tells whether the peer accepted.
  Future<void> invite() {
    _startInvitation();
    return _invitationDone.future;
  }

  /// Processes a session [command] of the peer, received on its data port
  /// when [onDataPort] is true, else on its control port.
  void handleCommand(MidiAppleMidiCommand command, {required bool onDataPort}) {
    if (_phase == _Phase.closed) {
      return;
    }
    _lastHeard = _clock.now();
    switch (command) {
      case MidiAppleMidiInvitation():
        _onInvitation(command, onDataPort: onDataPort);
      case MidiAppleMidiInvitationAccepted():
        _onAccepted(command, onDataPort: onDataPort);
      case MidiAppleMidiInvitationRejected():
        if (!isIncoming && _isInviting && command.token == _token) {
          _finish(_Phase.failed, 'the peer rejected the invitation');
        }
      case MidiAppleMidiEndSession():
        _onEnd(command);
      case MidiAppleMidiSync():
        _onSync(command);
      case MidiAppleMidiReceiverFeedback():
        _onFeedback(command);
      case MidiAppleMidiBitrateLimit():
        _bitrateLimit = command.limit;
    }
  }

  /// Processes an RTP-MIDI packet of the peer's data port.
  void handleRtp(Uint8List packet) {
    if (_phase != _Phase.connected ||
        packet.length < 12 ||
        ByteData.sublistView(packet).getUint32(8) != _remoteSsrc) {
      return;
    }
    _lastHeard = _clock.now();
    final receiver = _receiver!;
    final lostBefore = receiver.packetsLost;
    final messages = receiver.receive(packet);
    final lost = receiver.packetsLost - lostBefore;
    if (lost > 0) {
      _listener.packetsLost(this, lost, _lossCause);
    }
    _deliver(messages);
  }

  @override
  Future<void> send(MidiPacket packet) async {
    if (packet is! MidiBytesPacket) {
      throw ArgumentError.value(
        packet,
        'packet',
        'AppleMIDI carries MIDI 1.0 bytes',
      );
    }
    if (_phase != _Phase.connected) {
      throw StateError('The connection to ${host.name} is not established');
    }
    final messages = _parser.add(packet.bytes.bytes, time: packet.time);
    final sender = _sender!;
    final packets = sender.send(messages);
    if (packets.isEmpty) {
      return;
    }
    _lastData = sender.extendedSequenceNumber - 1;
    _startGuards();
    for (final rtp in packets) {
      _transmitDatagram(rtp.toBytes(), toDataPort: true);
    }
  }

  @override
  Future<void> close() async {
    switch (_phase) {
      case _Phase.connected ||
          _Phase.awaitingData ||
          _Phase.invitingControl ||
          _Phase.invitingData:
        _retrying = false;
        _transmit(_endSession, toDataPort: false);
        _silence();
        _finish(_Phase.closed, 'closed by this side');
      case _Phase.idle || _Phase.failed:
        _reconnecting = false;
        _retrying = false;
        _finish(_Phase.closed, _endReason ?? 'closed by this side');
      case _Phase.closed:
        break;
    }
  }

  // ...........................................................................
  @override
  final MidiNetworkHostInfo host;

  @override
  final bool isIncoming;

  /// The name this side presents.
  final String localName;

  /// The SSRC of this side.
  final int localSsrc;

  /// The timing of the session.
  final MidiAppleMidiSettings settings;

  @override
  String get remoteName => _remoteName;

  /// The SSRC of the peer, or null before it answered.
  int? get remoteSsrc => _remoteSsrc;

  @override
  MidiNetworkConnectionState get state => switch (_phase) {
    _Phase.idle ||
    _Phase.invitingControl ||
    _Phase.invitingData ||
    _Phase.awaitingData => MidiNetworkConnectionState.inviting,
    _Phase.connected => MidiNetworkConnectionState.connected,
    _Phase.closed => MidiNetworkConnectionState.disconnected,
    _Phase.failed => MidiNetworkConnectionState.failed,
  };

  /// Why the connection ended, or null while it lives.
  String? get endReason => _endReason;

  /// Whether the initiator invites again after its timeout.
  bool get isReconnecting => _reconnecting;

  /// The clock synchronisation with the peer; times are microseconds of
  /// the session clocks.
  MidiAppleMidiClockSync get clockSync => _sync;

  /// The bit rate the peer asked for with RL, or null; the connection
  /// does not pace its packets.
  int? get bitrateLimit => _bitrateLimit;

  /// The current value of the local session clock in units of 100
  /// microseconds, the clock of CK and of the RTP timestamps.
  int get sessionTime => _ticks(_clock.now());

  /// The packet statistics of all sessions with the peer so far.
  MidiNetworkLossStats get lossStats {
    final receiver = _receiver;
    final base = _statsBase;
    return receiver == null
        ? base
        : MidiNetworkLossStats(
            packetsReceived: base.packetsReceived + receiver.packetsReceived,
            packetsLost: base.packetsLost + receiver.packetsLost,
            packetsRecovered: base.packetsRecovered + receiver.packetsRecovered,
            journalRepairs: base.journalRepairs + receiver.journalRepairs,
          );
  }

  @override
  MidiNetworkConnectionInfo get info => MidiNetworkConnectionInfo(
    host: host,
    state: state,
    clockOffset: _sync.offset,
    roundTrip: _sync.roundTrip,
    lossStats: lossStats,
  );

  // ...........................................................................
  final void Function(Uint8List datagram, {required bool toDataPort})
  _transmitDatagram;
  final MidiNetworkConnectionListener _listener;
  final MidiClock _clock;
  final MidiTimerFactory _timerFactory;
  final Random _random;
  late final MidiTime _epoch;
  late final int _initialTicks;
  final _sync = MidiAppleMidiClockSync();
  static const _rtpClockRate = 10000;

  var _phase = _Phase.idle;
  String _remoteName;
  int? _remoteSsrc;
  int _token = 0;
  String? _endReason;
  var _reconnecting = false;
  var _retrying = false;
  int? _bitrateLimit;
  var _invitationDone = Completer<void>();
  var _attempts = 0;
  var _lastHeard = MidiTime.zero;

  Timer? _invitationTimer;
  Timer? _syncTimer;
  Timer? _watchdogTimer;
  Timer? _feedbackTimer;
  Timer? _guardTimer;
  Timer? _reconnectTimer;

  final _pendingSyncs = <int, int>{};
  var _missedSyncs = 0;
  var _syncCount = 0;
  var _repliedTicks = -1;
  var _repliedMicros = 0;

  MidiRtpSender? _sender;
  MidiRtpReceiver? _receiver;
  var _parser = MidiByteParser();
  var _statsBase = const MidiNetworkLossStats();
  var _lossCause = 'packets were lost';
  int? _lastFeedback;
  var _lastData = -1;
  var _guardIndex = 0;

  bool get _isInviting =>
      _phase == _Phase.invitingControl || _phase == _Phase.invitingData;

  MidiAppleMidiEndSession get _endSession =>
      MidiAppleMidiEndSession(token: _token, ssrc: localSsrc);

  // ######################
  // Clock
  // ######################

  /// Returns [time] in microseconds of the local session clock.
  int _micros(MidiTime time) =>
      _initialTicks * 100 + time.difference(_epoch).inMicroseconds;

  int _ticks(MidiTime time) => (_micros(time) / 100).round();

  MidiTime _packageTime(int micros) =>
      _epoch + Duration(microseconds: micros - _initialTicks * 100);

  /// Converts the time the receiver gave a message, 100 microseconds per
  /// RTP timestamp unit, to the package clock.
  MidiTime _toPackage(MidiTime rtpTime, MidiTime now) {
    final expected = _sync.toRemote(_micros(now));
    if (expected == null) {
      return now;
    }
    final timestamp = (rtpTime.microseconds / 100).round() & 0xFFFFFFFF;
    final reference = (expected / 100).round();
    final delta =
        ((timestamp - reference + 0x80000000) & 0xFFFFFFFF) - 0x80000000;
    final time = _packageTime(_sync.toLocal((reference + delta) * 100)!);
    return time.isAfter(now) ? now : time;
  }

  // ######################
  // Initiator
  // ######################

  void _startInvitation() {
    _cancelTimers();
    _reconnecting = false;
    _endReason = null;
    _phase = _Phase.invitingControl;
    _token = _random.nextInt(1 << 32);
    _remoteSsrc = null;
    _attempts = 0;
    if (_invitationDone.isCompleted) {
      _invitationDone = Completer<void>();
    }
    _sendInvitation();
    _listener.connectionChanged(this);
  }

  void _sendInvitation() {
    _attempts++;
    final delay =
        settings.invitationInterval *
        pow(settings.invitationBackoff, _attempts - 1);
    _invitationTimer = _timerFactory(
      delay > settings.maxInvitationInterval
          ? settings.maxInvitationInterval
          : delay,
      () {
        if (_attempts < settings.invitationAttempts) {
          _sendInvitation();
        } else if (_retrying) {
          _retry('the peer did not answer the invitation');
        } else {
          _finish(_Phase.failed, 'the peer did not answer the invitation');
        }
      },
    );
    _transmit(
      MidiAppleMidiInvitation(token: _token, ssrc: localSsrc, name: localName),
      toDataPort: _phase == _Phase.invitingData,
    );
  }

  void _onAccepted(
    MidiAppleMidiInvitationAccepted reply, {
    required bool onDataPort,
  }) {
    if (isIncoming || reply.token != _token) {
      return;
    }
    if (_phase == _Phase.invitingControl && !onDataPort) {
      _remember(reply);
      _invitationTimer?.cancel();
      _phase = _Phase.invitingData;
      _attempts = 0;
      _sendInvitation();
    } else if (_phase == _Phase.invitingData && onDataPort) {
      _establish();
    }
  }

  // ######################
  // Responder
  // ######################

  void _onInvitation(
    MidiAppleMidiInvitation invitation, {
    required bool onDataPort,
  }) {
    if (!isIncoming) {
      _transmit(
        MidiAppleMidiInvitationRejected(
          token: invitation.token,
          ssrc: localSsrc,
          name: localName,
        ),
        toDataPort: onDataPort,
      );
      return;
    }
    final known = invitation.token == _token && _phase != _Phase.idle;
    if (onDataPort) {
      _onDataInvitation(invitation, known: known);
      return;
    }
    if (!known) {
      _silence();
      _cancelTimers();
      _token = invitation.token;
      _remember(invitation);
      _phase = _Phase.awaitingData;
      _invitationTimer = _timerFactory(
        settings.sessionTimeout,
        () => _finish(_Phase.failed, 'the peer did not invite the data port'),
      );
      _listener.connectionChanged(this);
    }
    _transmit(_accepted, toDataPort: false);
  }

  void _onDataInvitation(
    MidiAppleMidiInvitation invitation, {
    required bool known,
  }) {
    if (!known) {
      _transmit(
        MidiAppleMidiInvitationRejected(
          token: invitation.token,
          ssrc: localSsrc,
          name: localName,
        ),
        toDataPort: true,
      );
      return;
    }
    if (_phase == _Phase.awaitingData) {
      _establish();
    }
    _transmit(_accepted, toDataPort: true);
  }

  MidiAppleMidiInvitationAccepted get _accepted =>
      MidiAppleMidiInvitationAccepted(
        token: _token,
        ssrc: localSsrc,
        name: localName,
      );

  // ######################
  // Session
  // ######################

  void _remember(MidiAppleMidiSessionCommand command) {
    _remoteSsrc = command.ssrc;
    if (command.name.isNotEmpty) {
      _remoteName = command.name;
    }
  }

  void _establish() {
    _cancelTimers();
    _phase = _Phase.connected;
    _retrying = false;
    final previous = _receiver;
    if (previous != null) {
      _statsBase = lossStats;
    }
    _sync.reset();
    _pendingSyncs.clear();
    _missedSyncs = 0;
    _syncCount = 0;
    _lastFeedback = null;
    _lastData = -1;
    _parser = MidiByteParser(maxSysExLength: settings.maxSysExLength);
    _sender = MidiRtpSender(
      ssrc: localSsrc,
      sequenceNumber: _random.nextInt(0x10000),
      clock: MidiRtpClock(
        rate: _rtpClockRate,
        time: _epoch,
        timestamp: _initialTicks & 0xFFFFFFFF,
      ),
    );
    _receiver = MidiRtpReceiver(
      maxSysExLength: settings.maxSysExLength,
      onIssue: (kind, cause) {
        if (kind == MidiDiagnosticKind.networkLoss) {
          _lossCause = cause;
        }
      },
    );
    _lastHeard = _clock.now();
    _scheduleWatchdog();
    _scheduleFeedback();
    _complete();
    _listener.connectionChanged(this);
    if (!isIncoming && _phase == _Phase.connected) {
      _synchronise();
    }
  }

  void _onEnd(MidiAppleMidiEndSession command) {
    if (_remoteSsrc != null && command.ssrc != _remoteSsrc) {
      return;
    }
    if (_isInviting) {
      // A bye with another token ends an earlier session with the same
      // peer, not the invitation in progress.
      if (command.token == 0 || command.token == _token) {
        _finish(_Phase.failed, 'the peer ended the invitation');
      }
      return;
    }
    if (_phase == _Phase.connected || _phase == _Phase.awaitingData) {
      _silence();
      _finish(_Phase.closed, 'the peer ended the session');
    }
  }

  void _timeOut(String reason) {
    _transmit(_endSession, toDataPort: false);
    _silence();
    if (!isIncoming && settings.reconnectInterval != null) {
      _retrying = true;
      _retry(reason);
    } else {
      _finish(_Phase.failed, reason);
    }
  }

  /// Ends the current attempt and invites again later, until the peer
  /// answers or the connection is closed.
  void _retry(String reason) {
    _reconnecting = true;
    _finish(_Phase.failed, reason);
    _reconnectTimer = _timerFactory(
      settings.reconnectInterval!,
      _startInvitation,
    );
  }

  void _finish(_Phase phase, String reason) {
    _cancelTimers();
    _phase = phase;
    _endReason = reason;
    _complete();
    _listener.connectionChanged(this);
  }

  void _complete() {
    if (!_invitationDone.isCompleted) {
      _invitationDone.complete();
    }
  }

  void _cancelTimers() {
    for (final timer in [
      _invitationTimer,
      _syncTimer,
      _watchdogTimer,
      _feedbackTimer,
      _guardTimer,
      _reconnectTimer,
    ]) {
      timer?.cancel();
    }
  }

  void _scheduleWatchdog() {
    _watchdogTimer = _timerFactory(settings.sessionTimeout ~/ 4, () {
      if (_clock.now().difference(_lastHeard) > settings.sessionTimeout) {
        _timeOut('the peer went silent');
      } else {
        _scheduleWatchdog();
      }
    });
  }

  // ######################
  // Clock synchronising
  // ######################

  void _synchronise() {
    if (_pendingSyncs.isNotEmpty) {
      _pendingSyncs.clear();
      if (++_missedSyncs >= settings.missedSyncLimit) {
        _timeOut('the peer stopped answering the clock synchronisation');
        return;
      }
    }
    _syncCount++;
    _syncTimer = _timerFactory(
      _syncCount < settings.initialSyncCount || _missedSyncs > 0
          ? settings.initialSyncInterval
          : settings.syncInterval,
      _synchronise,
    );
    final now = _clock.now();
    final ticks = _ticks(now);
    _pendingSyncs[ticks] = _micros(now);
    _transmit(
      MidiAppleMidiSync(ssrc: localSsrc, count: 0, timestamps: [ticks, 0, 0]),
      toDataPort: true,
    );
  }

  void _onSync(MidiAppleMidiSync sync) {
    if (_phase != _Phase.connected) {
      return;
    }
    final [t1, t2, t3] = sync.timestamps;
    switch (sync.count) {
      case 0:
        final now = _clock.now();
        _repliedTicks = _ticks(now);
        _repliedMicros = _micros(now);
        _transmit(
          MidiAppleMidiSync(
            ssrc: localSsrc,
            count: 1,
            timestamps: [t1, _repliedTicks, 0],
          ),
          toDataPort: true,
        );
      case 1:
        final sent = _pendingSyncs.remove(t1);
        if (sent == null) {
          return;
        }
        final now = _clock.now();
        final received = _micros(now);
        _missedSyncs = 0;
        _sample(
          localTime: (sent + received) ~/ 2,
          remoteTime: t2 * 100,
          roundTrip: received - sent,
        );
        _transmit(
          MidiAppleMidiSync(
            ssrc: localSsrc,
            count: 2,
            timestamps: [t1, t2, _ticks(now)],
          ),
          toDataPort: true,
        );
      default:
        _sample(
          localTime: t2 == _repliedTicks ? _repliedMicros : t2 * 100,
          remoteTime: (t1 + t3) * 50,
          roundTrip: (t3 - t1) * 100,
        );
    }
  }

  void _sample({
    required int localTime,
    required int remoteTime,
    required int roundTrip,
  }) {
    if (_sync.add(
      localTime: localTime,
      remoteTime: remoteTime,
      roundTrip: roundTrip,
    )) {
      _listener.connectionChanged(this);
    }
  }

  // ######################
  // Journal
  // ######################

  void _scheduleFeedback() {
    _feedbackTimer = _timerFactory(settings.feedbackInterval, () {
      _scheduleFeedback();
      final sequenceNumber = _receiver!.feedbackSequenceNumber;
      if (sequenceNumber != null && sequenceNumber != _lastFeedback) {
        _lastFeedback = sequenceNumber;
        _transmit(
          MidiAppleMidiReceiverFeedback(
            ssrc: localSsrc,
            sequenceNumber: sequenceNumber,
          ),
          toDataPort: false,
        );
      }
    });
  }

  void _onFeedback(MidiAppleMidiReceiverFeedback feedback) {
    final sender = _sender;
    if (_phase != _Phase.connected || feedback.ssrc != _remoteSsrc) {
      return;
    }
    sender!.acknowledge(feedback.sequenceNumber);
    if (_acknowledged) {
      _guardTimer?.cancel();
    }
  }

  bool get _acknowledged => (_sender!.acknowledged ?? -1) >= _lastData;

  void _startGuards() {
    _guardTimer?.cancel();
    _guardIndex = 0;
    _nextGuard();
  }

  void _nextGuard() {
    if (_guardIndex >= settings.guardIntervals.length) {
      return;
    }
    _guardTimer = _timerFactory(settings.guardIntervals[_guardIndex++], () {
      if (_acknowledged) {
        return;
      }
      _nextGuard();
      _transmitDatagram(
        _sender!.guard(time: _clock.now()).toBytes(),
        toDataPort: true,
      );
    });
  }

  void _deliver(List<MidiTimedMessage> messages) {
    final now = _clock.now();
    for (final (:message, :time) in messages) {
      _listener.packetReceived(
        this,
        MidiBytesPacket(
          bytes: MidiByteEncoder.encode(message)!,
          time: _toPackage(time, now),
        ),
      );
    }
  }

  /// Ends the notes and pedals the peer left sounding.
  void _silence() {
    final receiver = _receiver;
    if (receiver != null && _phase == _Phase.connected) {
      final now = _clock.now();
      _deliver([
        for (final (:message, time: _) in receiver.close())
          (message: message, time: now),
      ]);
    }
  }

  void _transmit(MidiAppleMidiCommand command, {required bool toDataPort}) =>
      _transmitDatagram(command.encode(), toDataPort: toDataPort);
}

// #############################################################################
/// The phases of an AppleMIDI session.
enum _Phase {
  idle,
  invitingControl,
  invitingData,
  awaitingData,
  connected,
  closed,
  failed,
}
