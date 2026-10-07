// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:math';

// #############################################################################
/// How an unreliable link treats datagrams: random and burst loss,
/// duplication, reordering and delay.
///
/// Burst loss follows the Gilbert-Elliott model: before each datagram the
/// link moves from the good to the bad state with [burstStart] and back
/// with [burstEnd]; a datagram is lost with [loss] in the good and with
/// [burstLoss] in the bad state. A delivered datagram waits [delay] plus a
/// random share of [jitter]; with [reorder] it waits [reorderDelay] longer,
/// so later datagrams overtake it; with [duplicate] it arrives twice.
final class MidiNetworkImpairment {
  /// Creates an impairment; all probabilities range from 0 to 1.
  const MidiNetworkImpairment({
    this.loss = 0,
    this.burstStart = 0,
    this.burstEnd = 1,
    this.burstLoss = 1,
    this.duplicate = 0,
    this.reorder = 0,
    this.delay = Duration.zero,
    this.jitter = Duration.zero,
    this.reorderDelay = const Duration(milliseconds: 5),
  }) : assert(loss >= 0 && loss <= 1),
       assert(burstStart >= 0 && burstStart <= 1),
       assert(burstEnd >= 0 && burstEnd <= 1),
       assert(burstLoss >= 0 && burstLoss <= 1),
       assert(duplicate >= 0 && duplicate <= 1),
       assert(reorder >= 0 && reorder <= 1);

  // ...........................................................................
  /// Decides the fate of one datagram on a link in the burst state
  /// [inBurst].
  ///
  /// Returns the new burst state, the delays of the datagram's deliveries
  /// (none when it is lost, two when it is duplicated) and whether it is
  /// held back so that later datagrams overtake it.
  ///
  /// - [random] the source of all decisions; seed it for reproducible runs.
  ({bool inBurst, List<Duration> deliveries, bool reordered}) decide(
    Random random, {
    required bool inBurst,
  }) {
    final burst = inBurst
        ? random.nextDouble() >= burstEnd
        : random.nextDouble() < burstStart;
    if (random.nextDouble() < (burst ? burstLoss : loss)) {
      return (inBurst: burst, deliveries: const [], reordered: false);
    }
    var wait = delay + jitter * random.nextDouble();
    final reordered = random.nextDouble() < reorder;
    if (reordered) {
      wait += reorderDelay;
    }
    return (
      inBurst: burst,
      deliveries: [
        wait,
        if (random.nextDouble() < duplicate) wait + _duplicateGap,
      ],
      reordered: reordered,
    );
  }

  // ...........................................................................
  /// The probability to lose a datagram in the good state.
  final double loss;

  /// The probability to enter the bad state before a datagram.
  final double burstStart;

  /// The probability to leave the bad state before a datagram.
  final double burstEnd;

  /// The probability to lose a datagram in the bad state.
  final double burstLoss;

  /// The probability to deliver a datagram twice.
  final double duplicate;

  /// The probability to hold a datagram back by [reorderDelay].
  final double reorder;

  /// The fixed delay of every datagram.
  final Duration delay;

  /// The largest random delay added to [delay].
  final Duration jitter;

  /// The extra delay of a reordered datagram.
  final Duration reorderDelay;

  /// Whether the impairment never touches a datagram.
  bool get isNone =>
      loss == 0 &&
      burstStart == 0 &&
      duplicate == 0 &&
      reorder == 0 &&
      delay == Duration.zero &&
      jitter == Duration.zero;

  // ...........................................................................
  @override
  String toString() =>
      'MidiNetworkImpairment(loss: $loss, burstStart: $burstStart, '
      'burstEnd: $burstEnd, burstLoss: $burstLoss, duplicate: $duplicate, '
      'reorder: $reorder, delay: $delay, jitter: $jitter, '
      'reorderDelay: $reorderDelay)';

  // ...........................................................................
  /// A link that delivers every datagram at once, exactly once.
  static const MidiNetworkImpairment none = MidiNetworkImpairment();

  static const Duration _duplicateGap = Duration(microseconds: 100);
}
