// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:math';

// #############################################################################
/// Estimates the offset between the session clocks of two AppleMIDI
/// participants from CK exchanges, with outlier and drift filtering.
///
/// Every three-way exchange yields a sample: the local time, the remote
/// time read at the same moment, and the round trip. Assuming equal transit
/// times in both directions, the true offset lies within half the round trip
/// of the measured one. The estimator keeps the last [window] samples,
/// ignores those whose round trip exceeds the best one by more than the
/// jitter tolerance, and fits a line through the rest: its slope is the
/// drift between the clocks, bounded by [maxDrift] and only used once the
/// samples span [minDriftSpan]. A sample with a good round trip that
/// contradicts the estimate beyond its own uncertainty starts the estimate
/// anew, e.g. after the remote clock restarted.
///
/// All times are microseconds of the respective session clock.
final class MidiAppleMidiClockSync {
  /// Creates an estimator without samples.
  ///
  /// - [window] the number of samples kept.
  /// - [jitterTolerance] how much longer than the best round trip a
  ///   sample's round trip may be to count; the best round trip itself is
  ///   tolerated when it is larger.
  /// - [maxDrift] the largest drift accepted, e.g. 0.0005 for 500 ppm.
  /// - [minDriftSpan] the time the good samples must span before the drift
  ///   is estimated.
  MidiAppleMidiClockSync({
    this.window = 8,
    this.jitterTolerance = const Duration(milliseconds: 1),
    this.maxDrift = 0.0005,
    this.minDriftSpan = const Duration(seconds: 5),
  }) : assert(window > 0);

  // ...........................................................................
  /// Adds the sample of one exchange and returns whether it was accepted.
  ///
  /// - [localTime] the local time of the measurement.
  /// - [remoteTime] the remote time at [localTime].
  /// - [roundTrip] the round trip of the exchange; negative values are
  ///   rejected.
  bool add({
    required int localTime,
    required int remoteTime,
    required int roundTrip,
  }) {
    if (roundTrip < 0) {
      return false;
    }
    final sample = _Sample(localTime, remoteTime - localTime, roundTrip);
    if (_contradicts(sample)) {
      _samples.clear();
    }
    _samples.add(sample);
    if (_samples.length > window) {
      _samples.removeAt(0);
    }
    _fit();
    return true;
  }

  /// Forgets all samples.
  void reset() {
    _samples.clear();
    _fit();
  }

  // ...........................................................................
  /// Returns the estimated offset (remote minus local) at [localTime], or
  /// null without samples.
  int? offsetAt(int localTime) => _samples.isEmpty
      ? null
      : (_meanOffset + _drift * (localTime - _meanTime)).round();

  /// Returns the remote time that corresponds to [localTime], or null
  /// without samples.
  int? toRemote(int localTime) {
    final offset = offsetAt(localTime);
    return offset == null ? null : localTime + offset;
  }

  /// Returns the local time that corresponds to [remoteTime], or null
  /// without samples.
  int? toLocal(int remoteTime) => _samples.isEmpty
      ? null
      : ((remoteTime - _meanOffset + _drift * _meanTime) / (1 + _drift))
            .round();

  // ...........................................................................
  /// The number of samples kept.
  final int window;

  /// How much longer than the best round trip a usable round trip may be.
  final Duration jitterTolerance;

  /// The largest drift accepted.
  final double maxDrift;

  /// The time the good samples must span before the drift is estimated.
  final Duration minDriftSpan;

  /// Whether at least one sample was accepted since the last [reset].
  bool get isSynchronized => _samples.isNotEmpty;

  /// The number of samples kept right now.
  int get sampleCount => _samples.length;

  /// The estimated offset (remote minus local) at the time of the latest
  /// sample, or null without samples.
  Duration? get offset => _samples.isEmpty
      ? null
      : Duration(microseconds: offsetAt(_samples.last.localTime)!);

  /// The round trip of the latest sample, or null without samples.
  Duration? get roundTrip =>
      _samples.isEmpty ? null : Duration(microseconds: _samples.last.roundTrip);

  /// The smallest round trip of the samples kept, or null without samples.
  Duration? get bestRoundTrip =>
      _samples.isEmpty ? null : Duration(microseconds: _bestRoundTrip);

  /// The estimated drift: how much faster the remote clock runs, e.g.
  /// 0.00001 for 10 ppm.
  double get drift => _drift;

  // ...........................................................................
  final _samples = <_Sample>[];
  double _meanTime = 0;
  double _meanOffset = 0;
  double _drift = 0;

  int get _bestRoundTrip => _samples.map((s) => s.roundTrip).reduce(min);

  int _tolerance(int bestRoundTrip) =>
      max(jitterTolerance.inMicroseconds, bestRoundTrip ~/ 2);

  bool _contradicts(_Sample sample) {
    if (_samples.isEmpty) {
      return false;
    }
    final best = _bestRoundTrip;
    final tolerance = _tolerance(best);
    if (sample.roundTrip > best + tolerance) {
      return false;
    }
    final deviation = (sample.offset - offsetAt(sample.localTime)!).abs();
    return deviation > sample.roundTrip ~/ 2 + 2 * tolerance;
  }

  void _fit() {
    if (_samples.isEmpty) {
      _meanTime = _meanOffset = _drift = 0;
      return;
    }
    final best = _bestRoundTrip;
    final limit = best + _tolerance(best);
    final good = [
      for (final s in _samples)
        if (s.roundTrip <= limit) s,
    ];
    _meanTime =
        good.map((s) => s.localTime).reduce((a, b) => a + b) / good.length;
    _meanOffset =
        good.map((s) => s.offset).reduce((a, b) => a + b) / good.length;
    _drift = _slope(good);
  }

  double _slope(List<_Sample> good) {
    final span = good.last.localTime - good.first.localTime;
    if (good.length < 3 || span <= 0 || span < minDriftSpan.inMicroseconds) {
      return 0;
    }
    var covariance = 0.0;
    var variance = 0.0;
    for (final s in good) {
      final dt = s.localTime - _meanTime;
      covariance += dt * (s.offset - _meanOffset);
      variance += dt * dt;
    }
    return (covariance / variance).clamp(-maxDrift, maxDrift);
  }
}

// #############################################################################
class _Sample {
  const _Sample(this.localTime, this.offset, this.roundTrip);

  final int localTime;
  final int offset;
  final int roundTrip;
}
