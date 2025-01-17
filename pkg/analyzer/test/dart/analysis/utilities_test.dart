// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/src/test_utilities/resource_provider_mixin.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(UtilitiesTest);
  });
}

@reflectiveTest
class UtilitiesTest with ResourceProviderMixin {
  test_parseString_errors_noThrow() {
    String content = '''
void main() => print('Hello, world!')
''';
    ParseStringResult result =
        parseString(content: content, throwIfDiagnostics: false);
    expect(result.content, content);
    expect(result.errors, hasLength(1));
    expect(result.lineInfo, isNotNull);
    expect(result.unit.toString(),
        equals("void main() => print('Hello, world!');"));
  }

  test_parseString_errors_throw() {
    String content = '''
void main() => print('Hello, world!')
''';
    expect(() => parseString(content: content),
        throwsA(const TypeMatcher<ArgumentError>()));
  }

  test_parseString_featureSet_nnbd_off() {
    String content = '''
int? f() => 1;
''';
    var featureSet = FeatureSet.forTesting(sdkVersion: '2.3.0');
    expect(featureSet.isEnabled(Feature.non_nullable), isFalse);
    ParseStringResult result = parseString(
        content: content, throwIfDiagnostics: false, featureSet: featureSet);
    expect(result.content, content);
    expect(result.errors, hasLength(1));
    expect(result.lineInfo, isNotNull);
    expect(result.unit.toString(), equals('int? f() => 1;'));
  }

  test_parseString_featureSet_nnbd_on() {
    String content = '''
int? f() => 1;
''';
    var featureSet =
        FeatureSet.forTesting(additionalFeatures: [Feature.non_nullable]);
    ParseStringResult result = parseString(
        content: content, throwIfDiagnostics: false, featureSet: featureSet);
    expect(result.content, content);
    expect(result.errors, isEmpty);
    expect(result.lineInfo, isNotNull);
    expect(result.unit.toString(), equals('int? f() => 1;'));
  }

  test_parseString_lineInfo() {
    String content = '''
main() {
  print('Hello, world!');
}
''';
    ParseStringResult result = parseString(content: content);
    expect(result.lineInfo, same(result.unit.lineInfo));
    expect(result.lineInfo.lineStarts, [0, 9, 35, 37]);
  }

  test_parseString_noErrors() {
    String content = '''
void main() => print('Hello, world!');
''';
    ParseStringResult result = parseString(content: content);
    expect(result.content, content);
    expect(result.errors, isEmpty);
    expect(result.lineInfo, isNotNull);
    expect(result.unit.toString(),
        equals("void main() => print('Hello, world!');"));
  }
}
