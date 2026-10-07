// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// The timing and buffering of Network MIDI 2.0 sessions (M2-124-UM).
///
/// The defaults follow the specification's recommendations and the values
/// Windows MIDI Services uses; tests shorten them.
final class MidiNetworkMidi2Settings {
  /// Creates settings.
  ///
  /// - [invitationInterval] the wait between invitations of a client.
  /// - [invitationAttempts] the invitations sent before a client gives up.
  /// - [pendingTimeout] how long a client waits after Invitation Reply:
  ///   Pending, and a host for the answer to its authentication challenge.
  /// - [pingInterval] the time between pings of an established session.
  /// - [missedPingLimit] the pings in a row without any traffic from the
  ///   peer after which the session times out.
  /// - [forwardErrorCorrection] the previous UMP Data commands repeated in
  ///   front of every new one.
  /// - [retransmitBufferSize] the UMP Data commands kept for retransmit
  ///   requests; 0 refuses retransmission.
  /// - [retransmitDelay] the wait after a gap before the first retransmit
  ///   request, so reordered packets can arrive; doubled per request.
  /// - [retransmitAttempts] the requests per gap before the gap is
  ///   accepted as a loss.
  /// - [receiveBufferSize] the UMP Data commands held back behind a gap.
  /// - [keepAliveStart], [keepAliveStep], [keepAliveMax] the schedule of
  ///   empty UMP Data commands after data, which carry the forward error
  ///   correction of the last data and keep the sequence moving.
  /// - [byeTimeout], [byeAttempts] how long and how often a Bye waits for
  ///   its reply.
  /// - [reconnectInterval] the wait before a client invites again after a
  ///   timeout; null never reconnects.
  /// - [authenticationAttempts] the wrong digests a host accepts before it
  ///   ends the invitation.
  /// - [maxSessions] the most sessions a host keeps at a time.
  const MidiNetworkMidi2Settings({
    this.invitationInterval = const Duration(seconds: 1),
    this.invitationAttempts = 5,
    this.pendingTimeout = const Duration(seconds: 120),
    this.pingInterval = const Duration(seconds: 2),
    this.missedPingLimit = 5,
    this.forwardErrorCorrection = 2,
    this.retransmitBufferSize = 250,
    this.retransmitDelay = const Duration(milliseconds: 10),
    this.retransmitAttempts = 3,
    this.receiveBufferSize = 256,
    this.keepAliveStart = const Duration(milliseconds: 200),
    this.keepAliveStep = const Duration(milliseconds: 200),
    this.keepAliveMax = const Duration(seconds: 2),
    this.byeTimeout = const Duration(milliseconds: 500),
    this.byeAttempts = 3,
    this.reconnectInterval = const Duration(seconds: 5),
    this.authenticationAttempts = 3,
    this.maxSessions = 64,
  }) : assert(invitationAttempts > 0),
       assert(missedPingLimit > 0),
       assert(forwardErrorCorrection >= 0),
       assert(retransmitBufferSize >= 0),
       assert(retransmitAttempts >= 0),
       assert(receiveBufferSize > 0),
       assert(byeAttempts > 0),
       assert(authenticationAttempts > 0),
       assert(maxSessions > 0);

  // ...........................................................................
  /// The wait between invitations of a client.
  final Duration invitationInterval;

  /// The invitations sent before a client gives up.
  final int invitationAttempts;

  /// How long a client waits after Invitation Reply: Pending, and a host
  /// for the answer to its authentication challenge.
  final Duration pendingTimeout;

  /// The time between pings of an established session.
  final Duration pingInterval;

  /// The pings in a row without traffic after which the session times out.
  final int missedPingLimit;

  /// The previous UMP Data commands repeated in front of every new one.
  final int forwardErrorCorrection;

  /// The UMP Data commands kept for retransmit requests.
  final int retransmitBufferSize;

  /// The wait after a gap before the first retransmit request.
  final Duration retransmitDelay;

  /// The retransmit requests per gap before it is accepted as a loss.
  final int retransmitAttempts;

  /// The UMP Data commands held back behind a gap.
  final int receiveBufferSize;

  /// The wait before the first empty UMP Data command after data.
  final Duration keepAliveStart;

  /// How much longer each further empty UMP Data command waits.
  final Duration keepAliveStep;

  /// The longest wait between empty UMP Data commands.
  final Duration keepAliveMax;

  /// How long a Bye waits for its reply.
  final Duration byeTimeout;

  /// How often a Bye is sent without reply.
  final int byeAttempts;

  /// The wait before a client invites again after a timeout, or null.
  final Duration? reconnectInterval;

  /// The wrong digests a host accepts before it ends the invitation.
  final int authenticationAttempts;

  /// The most sessions a host keeps at a time.
  final int maxSessions;
}
