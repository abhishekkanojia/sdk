// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/src/dart/analysis/unlinked_api_signature.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../ast/parse_base.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(UnitApiSignatureTest);
  });
}

@reflectiveTest
class UnitApiSignatureTest extends ParseBase {
  void assertNotSameSignature(String oldCode, String newCode) {
    assertSignature(oldCode, newCode, same: false);
  }

  void assertSameSignature(String oldCode, String newCode) {
    assertSignature(oldCode, newCode, same: true);
  }

  void assertSignature(String oldCode, String newCode, {bool same}) {
    var path = convertPath('/test.dart');

    newFile(path, content: oldCode);
    var oldUnit = parseUnit(path).unit;
    var oldSignature = computeUnlinkedApiSignature(oldUnit);

    newFile(path, content: newCode);
    var newUnit = parseUnit(path).unit;
    var newSignature = computeUnlinkedApiSignature(newUnit);

    if (same) {
      expect(newSignature, oldSignature);
    } else {
      expect(newSignature, isNot(oldSignature));
    }
  }

  test_class_annotation() async {
    assertNotSameSignature(r'''
const a = 0;

class C {}
''', r'''
const a = 0;

@a
class C {}
''');
  }

  test_class_constructor_block_to_empty() {
    assertSameSignature(r'''
class C {
  C() {
    var v = 1;
  }
}
''', r'''
class C {
  C();
}
''');
  }

  test_class_constructor_body() {
    assertSameSignature(r'''
class C {
  C() {
    var v = 1;
  }
}
''', r'''
class C {
  C() {
    var v = 2;
  }
}
''');
  }

  test_class_constructor_empty_to_block() {
    assertSameSignature(r'''
class C {
  C();
}
''', r'''
class C {
  C() {
    var v = 1;
  }
}
''');
  }

  test_class_constructor_initializer_const() {
    assertNotSameSignature(r'''
class C {
  final int f;
  const C() : f = 1;
}
''', r'''
class C {
  final int f;
  const C() : f = 2;
}
''');
  }

  test_class_constructor_initializer_empty() {
    assertSameSignature(r'''
class C {
  C.foo() : ;
}
''', r'''
class C {
  C.foo() : f;
}
''');
  }

  test_class_constructor_initializer_notConst() {
    assertSameSignature(r'''
class C {
  final int f;
  C.foo() : f = 1;
  const C.bar();
}
''', r'''
class C {
  final int f;
  C.foo() : f = 2;
  const C.bar();
}
''');
  }

  test_class_constructor_parameters_add() {
    assertNotSameSignature(r'''
class C {
  C(int a);
}
''', r'''
class C {
  C(int a, int b);
}
''');
  }

  test_class_constructor_parameters_remove() {
    assertNotSameSignature(r'''
class C {
  C(int a, int b);
}
''', r'''
class C {
  C(int a);
}
''');
  }

  test_class_constructor_parameters_rename() {
    assertNotSameSignature(r'''
class C {
  C(int a);
}
''', r'''
class C {
  C(int b);
}
''');
  }

  test_class_constructor_parameters_type() {
    assertNotSameSignature(r'''
class C {
  C(int p);
}
''', r'''
class C {
  C(double p);
}
''');
  }

  test_class_extends() {
    assertNotSameSignature(r'''
class A {}
class B {}
''', r'''
class A {}
class B extends A {}
''');
  }

  test_class_field_withoutType() {
    assertNotSameSignature(r'''
class C {
  var a = 1;
}
''', r'''
class C {
  var a = 2;
}
''');
  }

  test_class_field_withoutType2() {
    assertNotSameSignature(r'''
class C {
  var a = 1, b = 2, c, d = 4;
}
''', r'''
class C {
  var a = 1, b, c = 3, d = 4;
}
''');
  }

  test_class_field_withType() {
    assertSameSignature(r'''
class C {
  int a = 1, b, c = 3;
}
''', r'''
class C {
  int a = 0, b = 2, c;
}
''');
  }

  test_class_field_withType_const() {
    assertNotSameSignature(r'''
class C {
  static const int a = 1;
}
''', r'''
class C {
  static const int a = 2;
}
''');
  }

  test_class_field_withType_final_hasConstConstructor() {
    assertNotSameSignature(r'''
class C {
  final int a = 1;
  const C();
}
''', r'''
class C {
  final int a = 2;
  const C();
}
''');
  }

  test_class_field_withType_final_noConstConstructor() {
    assertSameSignature(r'''
class C {
  final int a = 1;
}
''', r'''
class C {
  final int a = 2;
}
''');
  }

  test_class_field_withType_hasConstConstructor() {
    assertSameSignature(r'''
class C {
  int a = 1;
  const C();
}
''', r'''
class C {
  int a = 2;
  const C();
}
''');
  }

  test_class_field_withType_static_final_hasConstConstructor() {
    assertSameSignature(r'''
class C {
  static final int a = 1;
  const C();
}
''', r'''
class C {
  static final int a = 2;
  const C();
}
''');
  }

  test_class_field_withType_static_hasConstConstructor() {
    assertSameSignature(r'''
class C {
  static int a = 1;
  const C();
}
''', r'''
class C {
  static int a = 2;
  const C();
}
''');
  }

  test_class_implements() {
    assertNotSameSignature(r'''
class A {}
class B {}
''', r'''
class A {}
class B implements A {}
''');
  }

  test_class_method_annotation() {
    assertNotSameSignature(r'''
const a = 0;

class C {
  void foo() {}
}
''', r'''
const a = 0;

class C {
  @a
  void foo() {}
}
''');
  }

  test_class_method_body_async_to_sync() {
    assertSameSignature(r'''
class C {
  Future foo() async {}
}
''', r'''
class C {
  Future foo() {}
}
''');
  }

  test_class_method_body_block() {
    assertSameSignature(r'''
class C {
  int foo() {
    return 1;
  }
}
''', r'''
class C {
  int foo() {
    return 2;
  }
}
''');
  }

  test_class_method_body_block_to_expression() {
    assertSameSignature(r'''
class C {
  int foo() {
    return 1;
  }
}
''', r'''
class C {
  int foo() => 2;
}
''');
  }

  test_class_method_body_empty_to_block() {
    assertSameSignature(r'''
class C {
  int foo();
}
''', r'''
class C {
  int foo() {
    var v = 0;
  }
}
''');
  }

  test_class_method_body_expression() {
    assertSameSignature(r'''
class C {
  int foo() => 1;
}
''', r'''
class C {
  int foo() => 2;
}
''');
  }

  test_class_method_body_sync_to_async() {
    assertSameSignature(r'''
class C {
  Future foo() {}
}
''', r'''
class C {
  Future foo() async {}
}
''');
  }

  test_class_method_getter_body_block_to_expression() {
    assertSameSignature(r'''
class C {
  int get foo {
    return 1;
  }
}
''', r'''
class C {
  int get foo => 2;
}
''');
  }

  test_class_method_getter_body_empty_to_expression() {
    assertSameSignature(r'''
class C {
  int get foo;
}
''', r'''
class C {
  int get foo => 2;
}
''');
  }

  test_class_method_parameters_add() {
    assertNotSameSignature(r'''
class C {
  foo(int a) {}
}
''', r'''
class C {
  foo(int a, int b) {}
}
''');
  }

  test_class_method_parameters_remove() {
    assertNotSameSignature(r'''
class C {
  foo(int a, int b) {}
}
''', r'''
class C {
  foo(int a) {}
}
''');
  }

  test_class_method_parameters_rename() {
    assertNotSameSignature(r'''
class C {
  void foo(int a) {}
}
''', r'''
class C {
  void foo(int b) {}
}
''');
  }

  test_class_method_parameters_type() {
    assertNotSameSignature(r'''
class C {
  void foo(int p) {}
}
''', r'''
class C {
  void foo(double p) {}
}
''');
  }

  test_class_method_returnType() {
    assertNotSameSignature(r'''
class C {
  int foo() => 0;
}
''', r'''
class C {
  num foo() => 0;
}
''');
  }

  test_class_method_typeParameters_add() async {
    assertNotSameSignature(r'''
class C {
  void foo() {}
}
''', r'''
class C {
  void foo<T>() {}
}
''');
  }

  test_class_method_typeParameters_remove() {
    assertNotSameSignature(r'''
class C {
  void foo<T>() {}
}
''', r'''
class C {
  void foo() {}
}
''');
  }

  test_class_method_typeParameters_rename() {
    assertNotSameSignature(r'''
class C {
  void foo<T>() {}
}
''', r'''
class C {
  void foo<U>() {}
}
''');
  }

  test_class_modifier() {
    assertNotSameSignature(r'''
class C {}
''', r'''
abstract class C {}
''');
  }

  test_class_with() {
    assertNotSameSignature(r'''
class A {}
class B {}
class C extends A {}
''', r'''
class A {}
class B {}
class C extends A with B {}
''');
  }

  test_commentAdd() {
    assertSameSignature(r'''
var a = 1;
var b = 2;
var c = 3;
''', r'''
var a = 1; // comment

/// comment 1
/// comment 2
var b = 2;

/**
 *  Comment
 */
var c = 3;
''');
  }

  test_commentRemove() {
    assertSameSignature(r'''
var a = 1; // comment

/// comment 1
/// comment 2
var b = 2;

/**
 *  Comment
 */
var c = 3;
''', r'''
var a = 1;
var b = 2;
var c = 3;
''');
  }

  test_function_annotation() {
    assertNotSameSignature(r'''
const a = 0;

void foo() {}
''', r'''
const a = 0;

@a
void foo() {}
''');
  }

  test_function_body_async_to_sync() {
    assertSameSignature(r'''
Future foo() async {}
''', r'''
Future foo() {}
''');
  }

  test_function_body_block() {
    assertSameSignature(r'''
int foo() {
  return 1;
}
''', r'''
int foo() {
  return 2;
}
''');
  }

  test_function_body_block_to_expression() {
    assertSameSignature(r'''
int foo() {
  return 1;
}
''', r'''
int foo() => 2;
''');
  }

  test_function_body_expression() {
    assertSameSignature(r'''
int foo() => 1;
''', r'''
int foo() => 2;
''');
  }

  test_function_body_sync_to_async() {
    assertSameSignature(r'''
Future foo() {}
''', r'''
Future foo() async {}
''');
  }

  test_function_getter_block_to_expression() {
    assertSameSignature(r'''
int get foo {
  return 1;
}
''', r'''
int get foo => 2;
''');
  }

  test_function_parameters_rename() {
    assertNotSameSignature(r'''
void foo(int a) {}
''', r'''
void foo(int b) {}
''');
  }

  test_function_parameters_type() {
    assertNotSameSignature(r'''
void foo(int p) {}
''', r'''
void foo(double p) {}
''');
  }

  test_function_returnType() {
    assertNotSameSignature(r'''
int foo() => 0;
''', r'''
num foo() => 0;
''');
  }

  test_function_typeParameters_add() {
    assertNotSameSignature(r'''
void foo() {}
''', r'''
void foo<T>() {}
''');
  }

  test_function_typeParameters_remove() {
    assertNotSameSignature(r'''
void foo<T>() {}
''', r'''
void foo() {}
''');
  }

  test_function_typeParameters_rename() {
    assertNotSameSignature(r'''
void foo<T>() {}
''', r'''
void foo<U>() {}
''');
  }

  test_issue34850() {
    assertNotSameSignature(r'''
foo
Future<List<int>> bar() {}
''', r'''
foo
Future<List<int>> bar(int x) {}
''');
  }

  test_mixin_field_withoutType() {
    assertNotSameSignature(r'''
mixin M {
  var a = 1;
}
''', r'''
mixin M {
  var a = 2;
}
''');
  }

  test_mixin_field_withType() {
    assertSameSignature(r'''
mixin M {
  int a = 1, b, c = 3;
}
''', r'''
mixin M {
  int a = 0, b = 2, c;
}
''');
  }

  test_mixin_implements() {
    assertNotSameSignature(r'''
class A {}
mixin M {}
''', r'''
class A {}
mixin M implements A {}
''');
  }

  test_mixin_method_body_block() {
    assertSameSignature(r'''
mixin M {
  int foo() {
    return 1;
  }
}
''', r'''
mixin M {
  int foo() {
    return 2;
  }
}
''');
  }

  test_mixin_method_body_expression() {
    assertSameSignature(r'''
mixin M {
  int foo() => 1;
}
''', r'''
mixin M {
  int foo() => 2;
}
''');
  }

  test_mixin_on() {
    assertNotSameSignature(r'''
class A {}
mixin M {}
''', r'''
class A {}
mixin M on A {}
''');
  }

  test_topLevelVariable_withoutType() {
    assertNotSameSignature(r'''
var a = 1;
''', r'''
var a = 2;
''');
  }

  test_topLevelVariable_withoutType2() {
    assertNotSameSignature(r'''
var a = 1, b = 2, c, d = 4;;
''', r'''
var a = 1, b, c = 3, d = 4;;
''');
  }

  test_topLevelVariable_withType() {
    assertSameSignature(r'''
int a = 1, b, c = 3;
''', r'''
int a = 0, b = 2, c;
''');
  }

  test_topLevelVariable_withType_const() {
    assertNotSameSignature(r'''
const int a = 1;
''', r'''
const int a = 2;
''');
  }

  test_topLevelVariable_withType_final() {
    assertSameSignature(r'''
final int a = 1;
''', r'''
final int a = 2;
''');
  }

  test_typedef_generic_parameters_type() {
    assertNotSameSignature(r'''
typedef F = void Function(int);
''', r'''
typedef F = void Function(double);
''');
  }
}
