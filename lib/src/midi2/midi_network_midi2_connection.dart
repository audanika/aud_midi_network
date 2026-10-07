// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:aud_midi_core/aud_midi_core.dart';
import 'package:aud_midi_standard/aud_midi_standard.dart';

import '../session/midi_network_connection.dart';
import '../session/midi_network_connection_listener.dart';
import 'midi_network_midi2_command.dart';
import 'midi_network_midi2_credentials.dart';
import 'midi_network_midi2_settings.dart';

// #############################################################################
/// A Network MIDI 2.0 session with one peer (M2-124-UM 6 and 7), in the
/// client role when this side invites and in the host role when the peer
/// does.
///
/// The connection owns no socket: it hands its datagrams to `transmit` and
/// takes the decoded commands of the peer's datagrams through [handle].
/// UMP Data commands carry 16-bit sequence numbers; every datagram repeats
/// the previous commands for forward error correction, a gap the
/// correction cannot close triggers retransmit requests, and a gap that
/// stays open counts as a loss. Pings watch the peer; a client invites
/// again after a timeout.
final class MidiNetworkMidi2Connection implements MidiNetworkConnection {
  /// Creates a connection with the peer [host].
  ///
  /// - [isIncoming] whether the peer invited, i.e. this side is the host.
  /// - [localEndpointName], [localProductInstanceId] the identity of this
  ///   side.
  /// - [transmit] sends one datagram to the peer.
  /// - [listener] receives state changes, packets and losses.
  /// - [credentials] what a client proves when the host asks.
  /// - [requiredSecret], [requiredUsers] what a host asks clients to prove:
  ///   a user name and password when users are given, else the shared
  ///   secret when given, else nothing.
  /// - [random] creates nonces and ping ids; secure by default.
  MidiNetworkMidi2Connection({
    required this.host,
    required this.isIncoming,
    required this.localEndpointName,
    required this.localProductInstanceId,
    required void Function(Uint8List datagram) transmit,
    required this._listener,
    this.credentials,
    this.requiredSecret,
    List<MidiNetworkMidi2UserCredentials> requiredUsers = const [],
    this.settings = const MidiNetworkMidi2Settings(),
    this._clock = const MidiSystemClock(),
    this._timerFactory = Timer.new,
    Random? random,
  }) : requiredUsers = List.unmodifiable(requiredUsers),
       _transmitDatagram = transmit,
       _random = random ?? Random.secure(),
       _remoteName = host.name;

  // ...........................................................................
  /// Invites the host and completes when the invitation ended; [state]
  /// tells whether the host accepted.
  Future<void> invite() {
    _startInvitation();
    return _invitationDone.future;
  }

  /// Processes the [commands] of one datagram from the peer.
  void handle(List<MidiNetworkMidi2Command> commands) {
    if (_phase == _Phase.closed) {
      return;
    }
    _missedPings = 0;
    _refusedInDatagram = false;
    _datagramsReceived++;
    for (final command in commands) {
      if (_phase == _Phase.closed) {
        break;
      }
      _dispatch(command);
    }
  }

  @override
  Future<void> send(MidiPacket packet) async {
    if (packet is! MidiUmpPacket) {
      throw ArgumentError.value(
        packet,
        'packet',
        'Network MIDI 2.0 carries Universal MIDI Packets',
      );
    }
    if (_phase != _Phase.established) {
      throw StateError('The connection to ${host.name} is not established');
    }
    _restartKeepAlive();
    _transmitData(_split(packet.words));
  }

  /// Starts the sequence numbers of both sides at 0 again (Session Reset).
  ///
  /// Throws a [StateError] while the connection is not established.
  void reset() {
    if (_phase != _Phase.established) {
      throw StateError('The connection to ${host.name} is not established');
    }
    _resetSequences();
    _transmit([const MidiNetworkMidi2SessionReset()]);
  }

  @override
  Future<void> close() {
    switch (_phase) {
      case _Phase.established:
        _phase = _Phase.closing;
        _cancelTimers();
        _byeAttempts = 0;
        _sendBye();
      case _Phase.closing:
        break;
      case _Phase.inviting || _Phase.pending || _Phase.authenticating:
        _transmit([
          MidiNetworkMidi2Bye(
            reason: isIncoming
                ? MidiNetworkMidi2Bye.reasonUserTerminated
                : MidiNetworkMidi2Bye.reasonInvitationCanceled,
          ),
        ]);
        _finish(_Phase.closed, 'closed by this side');
      case _Phase.idle || _Phase.closed || _Phase.failed:
        _cancelTimers();
        _reconnecting = false;
        _retrying = false;
        if (_phase != _Phase.closed) {
          _finish(_Phase.closed, _endReason ?? 'closed by this side');
        }
    }
    return _closed.future;
  }

  // ...........................................................................
  @override
  final MidiNetworkHostInfo host;

  @override
  final bool isIncoming;

  /// The UMP Endpoint Name of this side.
  final String localEndpointName;

  /// The Product Instance Id of this side.
  final String localProductInstanceId;

  /// What a client proves when the host asks, or null.
  final MidiNetworkMidi2Credentials? credentials;

  /// The shared secret a host asks clients for, or null.
  final MidiNetworkMidi2SharedSecret? requiredSecret;

  /// The users a host admits; cannot be modified.
  final List<MidiNetworkMidi2UserCredentials> requiredUsers;

  /// The timing and buffering.
  final MidiNetworkMidi2Settings settings;

  @override
  String get remoteName => _remoteName;

  /// The Product Instance Id the peer gave; empty until it answered.
  String get remoteProductInstanceId => _remoteProductInstanceId;

  @override
  MidiNetworkConnectionState get state => switch (_phase) {
    _Phase.idle ||
    _Phase.inviting ||
    _Phase.pending ||
    _Phase.authenticating => MidiNetworkConnectionState.inviting,
    _Phase.established ||
    _Phase.closing => MidiNetworkConnectionState.connected,
    _Phase.closed => MidiNetworkConnectionState.disconnected,
    _Phase.failed => MidiNetworkConnectionState.failed,
  };

  /// Why the connection ended, or null while it lives.
  String? get endReason => _endReason;

  /// Whether the client invites again after its timeout.
  bool get isReconnecting => _reconnecting;

  /// The last measured round trip, or null before the first ping reply.
  Duration? get roundTrip => _roundTrip;

  /// The packet statistics; UMP Data commands count as packets.
  MidiNetworkLossStats get lossStats => MidiNetworkLossStats(
    packetsReceived: _received,
    packetsLost: _lost,
    packetsRecovered: _recovered,
  );

  /// The number of datagrams received from the peer.
  int get datagramsReceived => _datagramsReceived;

  @override
  MidiNetworkConnectionInfo get info => MidiNetworkConnectionInfo(
    host: host,
    state: state,
    roundTrip: _roundTrip,
    lossStats: lossStats,
  );

  // ...........................................................................
  final void Function(Uint8List datagram) _transmitDatagram;
  final MidiNetworkConnectionListener _listener;
  final MidiClock _clock;
  final MidiTimerFactory _timerFactory;
  final Random _random;

  var _phase = _Phase.idle;
  String _remoteName;
  String _remoteProductInstanceId = '';
  String? _endReason;
  var _invitationDone = Completer<void>();
  final _closed = Completer<void>();

  Timer? _invitationTimer;
  Timer? _pingTimer;
  Timer? _keepAliveTimer;
  Timer? _retransmitTimer;
  Timer? _byeTimer;
  Timer? _reconnectTimer;
  var _reconnecting = false;
  var _retrying = false;
  var _invitationAttempts = 0;
  var _byeAttempts = 0;
  var _keepAliveDelay = Duration.zero;

  Uint8List? _nonce;
  var _authenticationFailures = 0;
  var _digestSent = false;

  var _txSequence = 0;
  var _rxExpected = 0;
  final _sent = ListQueue<MidiNetworkMidi2UmpData>();
  final _pending = <int, MidiNetworkMidi2UmpData>{};
  var _retransmitRequests = 0;
  var _remoteRetransmits = true;

  final _pings = <int, MidiTime>{};
  var _missedPings = 0;
  Duration? _roundTrip;
  var _refusedInDatagram = false;

  var _received = 0;
  var _lost = 0;
  var _recovered = 0;
  var _datagramsReceived = 0;

  bool get _isInviting =>
      _phase == _Phase.inviting ||
      _phase == _Phase.pending ||
      _phase == _Phase.authenticating;

  // ######################
  // Dispatch
  // ######################

  void _dispatch(MidiNetworkMidi2Command command) {
    switch (command) {
      case MidiNetworkMidi2Invitation():
        _onInvitation(command);
      case MidiNetworkMidi2InvitationWithAuthentication():
        _onAuthenticatedInvitation(command.digest, null);
      case MidiNetworkMidi2InvitationWithUserAuthentication():
        _onAuthenticatedInvitation(command.digest, command.userName);
      case MidiNetworkMidi2InvitationAccepted():
        _onAccepted(command);
      case MidiNetworkMidi2InvitationPending():
        _onPending();
      case MidiNetworkMidi2AuthenticationRequired():
        _onChallenge(command);
      case MidiNetworkMidi2Ping():
        _transmit([MidiNetworkMidi2PingReply(pingId: command.pingId)]);
      case MidiNetworkMidi2PingReply():
        _onPingReply(command);
      case MidiNetworkMidi2UmpData():
        if (_inSession(command)) _onUmpData(command);
      case MidiNetworkMidi2RetransmitRequest():
        if (_inSession(command)) _onRetransmitRequest(command);
      case MidiNetworkMidi2RetransmitError():
        if (_inSession(command)) _abandonGap('the peer cannot retransmit');
      case MidiNetworkMidi2SessionReset():
        if (_inSession(command)) _onSessionReset();
      case MidiNetworkMidi2SessionResetReply():
        _inSession(command);
      case MidiNetworkMidi2Nak():
        _onNak(command);
      case MidiNetworkMidi2Bye():
        _onBye(command);
      case MidiNetworkMidi2ByeReply():
        if (_phase == _Phase.closing) _finish(_Phase.closed, 'closed');
      case MidiNetworkMidi2UnknownCommand():
        _nak(command.header, MidiNetworkMidi2Nak.reasonCommandNotSupported);
      case MidiNetworkMidi2InvalidCommand():
        _nak(command.header, MidiNetworkMidi2Nak.reasonCommandMalformed);
    }
  }

  /// Returns whether the session is established; otherwise answers
  /// [command] with Bye: Session Not Established, once per datagram.
  bool _inSession(MidiNetworkMidi2Command command) {
    if (_phase == _Phase.established) {
      return true;
    }
    if (!_refusedInDatagram) {
      _refusedInDatagram = true;
      _transmit([
        const MidiNetworkMidi2Bye(
          reason: MidiNetworkMidi2Bye.reasonSessionNotEstablished,
        ),
      ]);
    }
    return false;
  }

  void _nak(int header, int reason) {
    if (_phase == _Phase.established) {
      _transmit([MidiNetworkMidi2Nak(reason: reason, originalHeader: header)]);
    }
  }

  // ######################
  // Client
  // ######################

  void _startInvitation() {
    _cancelTimers();
    _reconnecting = false;
    _phase = _Phase.inviting;
    _endReason = null;
    _digestSent = false;
    _nonce = null;
    _invitationAttempts = 0;
    if (_invitationDone.isCompleted) {
      _invitationDone = Completer<void>();
    }
    _sendInvitation();
    _listener.connectionChanged(this);
  }

  void _sendInvitation() {
    _invitationAttempts++;
    _invitationTimer = _timerFactory(settings.invitationInterval, () {
      if (_invitationAttempts < settings.invitationAttempts) {
        _sendInvitation();
      } else if (_retrying) {
        _retry('the host did not answer');
      } else {
        _giveUp('the host did not answer');
      }
    });
    final nonce = _nonce;
    final credentials = this.credentials;
    _transmit([
      if (nonce == null)
        MidiNetworkMidi2Invitation(
          endpointName: localEndpointName,
          productInstanceId: localProductInstanceId,
          capabilities: switch (credentials) {
            MidiNetworkMidi2SharedSecret() =>
              MidiNetworkMidi2Invitation.capabilityAuthentication,
            MidiNetworkMidi2UserCredentials() =>
              MidiNetworkMidi2Invitation.capabilityUserAuthentication,
            null => 0,
          },
        )
      else if (credentials is MidiNetworkMidi2UserCredentials)
        MidiNetworkMidi2InvitationWithUserAuthentication(
          digest: credentials.digest(nonce),
          userName: credentials.userName,
        )
      else
        MidiNetworkMidi2InvitationWithAuthentication(
          digest: credentials!.digest(nonce),
        ),
    ]);
  }

  void _onAccepted(MidiNetworkMidi2InvitationAccepted reply) {
    if (isIncoming) {
      _nak(reply.header, MidiNetworkMidi2Nak.reasonCommandNotExpected);
    } else if (_isInviting) {
      _remember(reply.endpointName, reply.productInstanceId);
      _establish();
    } else if (_phase != _Phase.established) {
      _transmit([
        const MidiNetworkMidi2Bye(
          reason: MidiNetworkMidi2Bye.reasonNoPendingSession,
        ),
      ]);
    }
  }

  void _onPending() {
    if (isIncoming || !_isInviting) {
      return;
    }
    _phase = _Phase.pending;
    _invitationTimer?.cancel();
    _invitationTimer = _timerFactory(
      settings.pendingTimeout,
      () => _giveUp('the host did not decide in time'),
    );
  }

  void _onChallenge(MidiNetworkMidi2AuthenticationRequired challenge) {
    if (isIncoming || !_isInviting) {
      return;
    }
    _remember(challenge.endpointName, challenge.productInstanceId);
    final users = challenge is MidiNetworkMidi2UserAuthenticationRequired;
    final fits = users
        ? credentials is MidiNetworkMidi2UserCredentials
        : credentials is MidiNetworkMidi2SharedSecret;
    if (!fits) {
      _giveUp('the host requires authentication');
      return;
    }
    if (_digestSent &&
        challenge.authenticationState ==
            MidiNetworkMidi2AuthenticationRequired.incorrectDigest) {
      _giveUp('the host rejected the credentials');
      return;
    }
    _digestSent = true;
    _nonce = Uint8List.fromList(challenge.nonce);
    _phase = _Phase.authenticating;
    _invitationTimer?.cancel();
    _invitationAttempts = 0;
    _sendInvitation();
  }

  void _giveUp(String reason) {
    _transmit([
      const MidiNetworkMidi2Bye(
        reason: MidiNetworkMidi2Bye.reasonInvitationCanceled,
      ),
    ]);
    _finish(_Phase.failed, reason);
  }

  // ######################
  // Host
  // ######################

  void _onInvitation(MidiNetworkMidi2Invitation invitation) {
    if (!isIncoming) {
      return;
    }
    _remember(invitation.endpointName, invitation.productInstanceId);
    switch (_phase) {
      case _Phase.established:
        _acceptAgain();
      case _Phase.authenticating:
        _sendChallenge(MidiNetworkMidi2AuthenticationRequired.firstRequest);
      default:
        _admit(invitation.capabilities);
    }
  }

  void _admit(int capabilities) {
    final users = requiredUsers.isNotEmpty;
    if (!users && requiredSecret == null) {
      _establish();
      return;
    }
    final needed = users
        ? MidiNetworkMidi2Invitation.capabilityUserAuthentication
        : MidiNetworkMidi2Invitation.capabilityAuthentication;
    if (capabilities & needed == 0) {
      _refuse(
        MidiNetworkMidi2Bye.reasonNoMatchingAuthenticationMethod,
        'the client cannot authenticate',
      );
      return;
    }
    _phase = _Phase.authenticating;
    _invitationTimer = _timerFactory(
      settings.pendingTimeout,
      () => _refuse(
        MidiNetworkMidi2Bye.reasonTimeout,
        'the client did not authenticate in time',
      ),
    );
    _sendChallenge(MidiNetworkMidi2AuthenticationRequired.firstRequest);
    _listener.connectionChanged(this);
  }

  void _sendChallenge(int authenticationState) {
    final nonce = _nonce ??= MidiNetworkMidi2Credentials.createNonce(_random);
    _transmit([
      if (requiredUsers.isNotEmpty)
        MidiNetworkMidi2UserAuthenticationRequired(
          endpointName: localEndpointName,
          productInstanceId: localProductInstanceId,
          nonce: nonce,
          authenticationState: authenticationState,
        )
      else
        MidiNetworkMidi2AuthenticationRequired(
          endpointName: localEndpointName,
          productInstanceId: localProductInstanceId,
          nonce: nonce,
          authenticationState: authenticationState,
        ),
    ]);
  }

  void _onAuthenticatedInvitation(Uint8List digest, String? userName) {
    if (!isIncoming) {
      return;
    }
    if (_phase == _Phase.established) {
      _acceptAgain();
      return;
    }
    if (_phase != _Phase.authenticating) {
      _refuse(
        MidiNetworkMidi2Bye.reasonMissingPriorInvitation,
        'authentication without challenge',
      );
      return;
    }
    final MidiNetworkMidi2Credentials? expected;
    if (requiredUsers.isEmpty) {
      expected = userName == null ? requiredSecret : null;
    } else {
      expected = userName == null
          ? null
          : requiredUsers.where((u) => u.userName == userName).firstOrNull;
      if (userName != null && expected == null) {
        _refuse(
          MidiNetworkMidi2Bye.reasonUserNameNotFound,
          'unknown user $userName',
        );
        return;
      }
    }
    if (expected == null) {
      _refuse(
        MidiNetworkMidi2Bye.reasonNoMatchingAuthenticationMethod,
        'the client used another authentication method',
      );
      return;
    }
    if (MidiNetworkMidi2Credentials.digestsMatch(
      expected.digest(_nonce!),
      digest,
    )) {
      _establish();
      return;
    }
    if (++_authenticationFailures >= settings.authenticationAttempts) {
      _refuse(
        MidiNetworkMidi2Bye.reasonAuthenticationFailed,
        'the client failed to authenticate',
      );
      return;
    }
    _nonce = MidiNetworkMidi2Credentials.createNonce(_random);
    _sendChallenge(MidiNetworkMidi2AuthenticationRequired.incorrectDigest);
  }

  /// Answers the invitation of a client that is in session already: it
  /// lost the session, so both sides start their sequences anew.
  void _acceptAgain() {
    _resetSequences();
    _transmit([_accepted]);
  }

  void _refuse(int reason, String cause) {
    _transmit([MidiNetworkMidi2Bye(reason: reason)]);
    _finish(_Phase.failed, cause);
  }

  MidiNetworkMidi2InvitationAccepted get _accepted =>
      MidiNetworkMidi2InvitationAccepted(
        endpointName: localEndpointName,
        productInstanceId: localProductInstanceId,
      );

  // ######################
  // Session
  // ######################

  void _remember(String name, String productInstanceId) {
    if (name.isNotEmpty) {
      _remoteName = name;
    }
    _remoteProductInstanceId = productInstanceId;
  }

  void _establish() {
    _cancelTimers();
    _phase = _Phase.established;
    _retrying = false;
    _resetSequences();
    _pings.clear();
    _missedPings = 0;
    _schedulePing();
    _restartKeepAlive();
    _complete(_invitationDone);
    _listener.connectionChanged(this);
    if (isIncoming && _phase == _Phase.established) {
      _transmit([_accepted]);
    }
  }

  void _resetSequences() {
    _txSequence = 0;
    _rxExpected = 0;
    _sent.clear();
    _pending.clear();
    _retransmitTimer?.cancel();
    _retransmitRequests = 0;
  }

  void _onSessionReset() {
    _resetSequences();
    _transmit([const MidiNetworkMidi2SessionResetReply()]);
  }

  void _onBye(MidiNetworkMidi2Bye bye) {
    _transmit([const MidiNetworkMidi2ByeReply()]);
    final reason = 'the peer said bye (reason ${bye.reason})';
    if (_isInviting && !isIncoming) {
      // A timeout or a missing session concern an earlier session with the
      // same address and port, never the invitation in progress.
      if (bye.reason != MidiNetworkMidi2Bye.reasonTimeout &&
          bye.reason != MidiNetworkMidi2Bye.reasonSessionNotEstablished) {
        _finish(_Phase.failed, reason);
      }
    } else if (_phase != _Phase.closed && _phase != _Phase.failed) {
      _finish(_Phase.closed, reason);
    }
  }

  void _onNak(MidiNetworkMidi2Nak nak) {
    final code = nak.originalHeader >> 24;
    if (code == MidiNetworkMidi2RetransmitRequest.commandCode) {
      _remoteRetransmits = false;
      _abandonGap('the peer does not retransmit');
    } else if (!isIncoming &&
        _isInviting &&
        code <= MidiNetworkMidi2InvitationWithUserAuthentication.commandCode) {
      _finish(_Phase.failed, 'the host refused the invitation');
    }
  }

  void _sendBye() {
    _byeAttempts++;
    _byeTimer = _timerFactory(settings.byeTimeout, () {
      if (_byeAttempts < settings.byeAttempts) {
        _sendBye();
      } else {
        _finish(_Phase.closed, 'closed without bye reply');
      }
    });
    _transmit([
      const MidiNetworkMidi2Bye(
        reason: MidiNetworkMidi2Bye.reasonUserTerminated,
      ),
    ]);
  }

  void _finish(_Phase phase, String reason) {
    _cancelTimers();
    _phase = phase;
    _endReason = reason;
    _pending.clear();
    _complete(_invitationDone);
    if (phase == _Phase.closed) {
      _complete(_closed);
    }
    _listener.connectionChanged(this);
  }

  void _complete(Completer<void> completer) {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  void _cancelTimers() {
    for (final timer in [
      _invitationTimer,
      _pingTimer,
      _keepAliveTimer,
      _retransmitTimer,
      _byeTimer,
      _reconnectTimer,
    ]) {
      timer?.cancel();
    }
  }

  // ######################
  // Liveness
  // ######################

  void _schedulePing() {
    _pingTimer = _timerFactory(settings.pingInterval, _ping);
  }

  void _ping() {
    if (_missedPings >= settings.missedPingLimit) {
      _timeOut();
      return;
    }
    _missedPings++;
    final id = _random.nextInt(0x7FFFFFFF);
    _pings[id] = _clock.now();
    if (_pings.length > 2 * settings.missedPingLimit) {
      _pings.remove(_pings.keys.first);
    }
    _schedulePing();
    _transmit([MidiNetworkMidi2Ping(pingId: id)]);
  }

  void _onPingReply(MidiNetworkMidi2PingReply reply) {
    final sent = _pings.remove(reply.pingId);
    if (sent == null) {
      _nak(reply.header, MidiNetworkMidi2Nak.reasonBadPingReply);
      return;
    }
    _roundTrip = _clock.now().difference(sent);
  }

  void _timeOut() {
    _transmit([
      const MidiNetworkMidi2Bye(reason: MidiNetworkMidi2Bye.reasonTimeout),
    ]);
    if (!isIncoming && settings.reconnectInterval != null) {
      _retrying = true;
      _retry('the peer stopped answering');
    } else {
      _finish(_Phase.failed, 'the peer stopped answering');
    }
  }

  /// Ends the current attempt and invites again later, until the host
  /// answers or the connection is closed.
  void _retry(String reason) {
    _reconnecting = true;
    _finish(_Phase.failed, reason);
    _reconnectTimer = _timerFactory(
      settings.reconnectInterval!,
      _startInvitation,
    );
  }

  void _restartKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveDelay = settings.keepAliveStart;
    _scheduleKeepAlive();
  }

  void _scheduleKeepAlive() {
    _keepAliveTimer = _timerFactory(_keepAliveDelay, () {
      final next = _keepAliveDelay + settings.keepAliveStep;
      _keepAliveDelay = next > settings.keepAliveMax
          ? settings.keepAliveMax
          : next;
      _scheduleKeepAlive();
      _transmitData([_nextData(const [])]);
    });
  }

  // ######################
  // Data, send
  // ######################

  List<MidiNetworkMidi2UmpData> _split(List<int> words) {
    final result = <MidiNetworkMidi2UmpData>[];
    var start = 0;
    var end = 0;
    while (end < words.length) {
      final size = Ump.sizeOf(words[end]);
      if (end + size - start > MidiNetworkMidi2UmpData.maxWords) {
        result.add(_nextData(words.sublist(start, end)));
        start = end;
      }
      end += size;
    }
    result.add(_nextData(words.sublist(start, end)));
    return result;
  }

  MidiNetworkMidi2UmpData _nextData(List<int> words) {
    final data = MidiNetworkMidi2UmpData(
      sequenceNumber: _txSequence,
      words: words,
    );
    _txSequence = (_txSequence + 1) & 0xFFFF;
    return data;
  }

  void _transmitData(List<MidiNetworkMidi2UmpData> fresh) {
    _sent.addAll(fresh);
    var first = _sent.length - fresh.length;
    var batch = <MidiNetworkMidi2UmpData>[];
    var size = 4;
    for (final command in fresh) {
      final cost = _cost(command);
      if (batch.isNotEmpty &&
          size + cost > MidiNetworkMidi2Command.maxPacketBytes) {
        _transmit(_withCorrection(batch, first, size));
        first += batch.length;
        batch = [];
        size = 4;
      }
      batch.add(command);
      size += cost;
    }
    _transmit(_withCorrection(batch, first, size));
    final keep = max(
      settings.retransmitBufferSize,
      settings.forwardErrorCorrection,
    );
    while (_sent.length > keep) {
      _sent.removeFirst();
    }
  }

  List<MidiNetworkMidi2Command> _withCorrection(
    List<MidiNetworkMidi2UmpData> batch,
    int first,
    int size,
  ) {
    final copies = <MidiNetworkMidi2UmpData>[];
    var budget = MidiNetworkMidi2Command.maxPacketBytes - size;
    for (
      var i = first - 1;
      i >= 0 && copies.length < settings.forwardErrorCorrection;
      i--
    ) {
      final copy = _sent.elementAt(i);
      final cost = _cost(copy);
      if (cost > budget) {
        break;
      }
      budget -= cost;
      copies.insert(0, copy);
    }
    return [...copies, ...batch];
  }

  void _onRetransmitRequest(MidiNetworkMidi2RetransmitRequest request) {
    if (settings.retransmitBufferSize == 0) {
      _nak(request.header, MidiNetworkMidi2Nak.reasonCommandNotSupported);
      return;
    }
    final index = _sent.isEmpty
        ? 0
        : (request.sequenceNumber - _sent.first.sequenceNumber) & 0xFFFF;
    if (index >= _sent.length) {
      _transmit([
        MidiNetworkMidi2RetransmitError(
          reason: MidiNetworkMidi2RetransmitError.reasonDataNotAvailable,
          sequenceNumber: _sent.isEmpty
              ? _txSequence
              : _sent.first.sequenceNumber,
        ),
      ]);
      return;
    }
    final available = _sent.length - index;
    final count = request.count == 0
        ? available
        : min(request.count, available);
    var batch = <MidiNetworkMidi2Command>[];
    var size = 4;
    for (final command in _sent.skip(index).take(count)) {
      final cost = _cost(command);
      if (batch.isNotEmpty &&
          size + cost > MidiNetworkMidi2Command.maxPacketBytes) {
        _transmit(batch);
        batch = [];
        size = 4;
      }
      batch.add(command);
      size += cost;
    }
    _transmit(batch);
  }

  // ######################
  // Data, receive
  // ######################

  void _onUmpData(MidiNetworkMidi2UmpData data) {
    final distance = (data.sequenceNumber - _rxExpected) & 0xFFFF;
    if (distance >= 0x8000 || _pending.containsKey(data.sequenceNumber)) {
      return;
    }
    if (distance > 0) {
      _pending[data.sequenceNumber] = data;
      if (_pending.length > settings.receiveBufferSize) {
        _abandonGap('too many packets wait behind a gap');
      } else if (!(_retransmitTimer?.isActive ?? false)) {
        _retransmitRequests = 0;
        _retransmitTimer = _timerFactory(
          settings.retransmitDelay,
          _requestRetransmit,
        );
      }
      return;
    }
    if (_pending.isNotEmpty) {
      _lost++;
      _recovered++;
    }
    _deliver(data);
    _drainPending();
  }

  void _deliver(MidiNetworkMidi2UmpData data) {
    _rxExpected = (_rxExpected + 1) & 0xFFFF;
    _received++;
    if (data.words.isNotEmpty) {
      _listener.packetReceived(
        this,
        MidiUmpPacket(words: data.words, time: _clock.now()),
      );
    }
  }

  void _drainPending() {
    for (
      var next = _pending.remove(_rxExpected);
      next != null;
      next = _pending.remove(_rxExpected)
    ) {
      _deliver(next);
    }
    if (_pending.isEmpty) {
      _retransmitTimer?.cancel();
    }
  }

  int get _gapLength =>
      _pending.keys.map((s) => (s - _rxExpected) & 0xFFFF).reduce(min);

  void _requestRetransmit() {
    if (!_remoteRetransmits ||
        _retransmitRequests >= settings.retransmitAttempts) {
      _abandonGap('the peer did not retransmit in time');
      return;
    }
    _retransmitRequests++;
    _retransmitTimer = _timerFactory(
      settings.retransmitDelay * (1 << _retransmitRequests),
      _requestRetransmit,
    );
    _transmit([
      MidiNetworkMidi2RetransmitRequest(
        sequenceNumber: _rxExpected,
        count: _gapLength,
      ),
    ]);
  }

  void _abandonGap(String cause) {
    if (_pending.isEmpty) {
      return;
    }
    final missing = _gapLength;
    _lost += missing;
    _rxExpected = (_rxExpected + missing) & 0xFFFF;
    _listener.packetsLost(this, missing, cause);
    _drainPending();
    if (_pending.isNotEmpty && _phase == _Phase.established) {
      _retransmitRequests = 0;
      _retransmitTimer = _timerFactory(
        settings.retransmitDelay,
        _requestRetransmit,
      );
    }
  }

  // ######################
  // Transmit
  // ######################

  void _transmit(List<MidiNetworkMidi2Command> commands) =>
      _transmitDatagram(MidiNetworkMidi2Command.encodePacket(commands));

  static int _cost(MidiNetworkMidi2UmpData data) => 4 + 4 * data.words.length;
}

// #############################################################################
/// The phases of a Network MIDI 2.0 session, M2-124-UM 6.1.
enum _Phase {
  idle,
  inviting,
  pending,
  authenticating,
  established,
  closing,
  closed,
  failed,
}
