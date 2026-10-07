// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// #############################################################################
/// The timing of AppleMIDI sessions.
///
/// The defaults follow Apple's driver: invitations about once a second,
/// a burst of clock synchronisations after the start and one every ten
/// seconds later — the protocol asks for at least one a minute — and
/// receiver feedback once a second. Tests shorten them.
final class MidiAppleMidiSettings {
  /// Creates settings.
  ///
  /// - [invitationInterval] the wait before the first repetition of an
  ///   invitation; every further one waits [invitationBackoff] times
  ///   longer, up to [maxInvitationInterval].
  /// - [invitationAttempts] the invitations sent per port before the
  ///   initiator gives up.
  /// - [initialSyncInterval], [initialSyncCount] the clock
  ///   synchronisations right after the start.
  /// - [syncInterval] the time between later synchronisations.
  /// - [missedSyncLimit] the unanswered synchronisations in a row after
  ///   which the initiator ends the session.
  /// - [sessionTimeout] the silence of the peer after which the session
  ///   ends; it must exceed the peer's synchronisation interval.
  /// - [feedbackInterval] the time between receiver feedbacks (RS).
  /// - [guardIntervals] the waits of the guard packets after data: empty
  ///   packets with the recovery journal that let the peer repair a lost
  ///   last packet; they stop once the peer acknowledged the data.
  /// - [reconnectInterval] the wait before the initiator invites again
  ///   after a timeout; null never reconnects.
  /// - [initialTimestamp] the first value of the session clock in units of
  ///   100 microseconds; random when null.
  /// - [maxSysExLength] the longest System Exclusive message received, in
  ///   data bytes.
  const MidiAppleMidiSettings({
    this.invitationInterval = const Duration(seconds: 1),
    this.invitationBackoff = 1.5,
    this.maxInvitationInterval = const Duration(seconds: 4),
    this.invitationAttempts = 12,
    this.initialSyncInterval = const Duration(milliseconds: 1500),
    this.initialSyncCount = 6,
    this.syncInterval = const Duration(seconds: 10),
    this.missedSyncLimit = 3,
    this.sessionTimeout = const Duration(seconds: 75),
    this.feedbackInterval = const Duration(seconds: 1),
    this.guardIntervals = const [
      Duration(milliseconds: 20),
      Duration(milliseconds: 100),
      Duration(milliseconds: 400),
    ],
    this.reconnectInterval = const Duration(seconds: 5),
    this.initialTimestamp,
    this.maxSysExLength = 1 << 20,
  }) : assert(invitationBackoff >= 1),
       assert(invitationAttempts > 0),
       assert(initialSyncCount >= 0),
       assert(missedSyncLimit > 0);

  // ...........................................................................
  /// The wait before the first repetition of an invitation.
  final Duration invitationInterval;

  /// How much longer every further repetition waits.
  final double invitationBackoff;

  /// The longest wait between two invitations.
  final Duration maxInvitationInterval;

  /// The invitations sent per port before the initiator gives up.
  final int invitationAttempts;

  /// The time between the synchronisations right after the start.
  final Duration initialSyncInterval;

  /// The number of synchronisations right after the start.
  final int initialSyncCount;

  /// The time between later synchronisations.
  final Duration syncInterval;

  /// The unanswered synchronisations after which the session ends.
  final int missedSyncLimit;

  /// The silence of the peer after which the session ends.
  final Duration sessionTimeout;

  /// The time between receiver feedbacks.
  final Duration feedbackInterval;

  /// The waits of the guard packets after data.
  final List<Duration> guardIntervals;

  /// The wait before the initiator invites again after a timeout, or null.
  final Duration? reconnectInterval;

  /// The first value of the session clock, or null for a random one.
  final int? initialTimestamp;

  /// The longest System Exclusive message received, in data bytes.
  final int maxSysExLength;
}
