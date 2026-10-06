// @license
// Copyright (c) Audanika
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:aud_midi_network/aud_midi_network.dart';
import 'package:test/test.dart';

void main() {
  group('Example', () {
    group('greet()', () {
      test('should greet the name', () {
        expect(const Example('World').greet(), 'Hello World!');
      });
    });
  });
}
