// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:nnbd_migration/src/decorated_type.dart';
import 'package:nnbd_migration/src/nullability_node.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'migration_visitor_test_base.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(NodeBuilderTest);
  });
}

@reflectiveTest
class NodeBuilderTest extends MigrationVisitorTestBase {
  /// Gets the [DecoratedType] associated with the constructor declaration whose
  /// name matches [search].
  DecoratedType decoratedConstructorDeclaration(String search) => variables
      .decoratedElementType(findNode.constructor(search).declaredElement);

  /// Gets the [DecoratedType] associated with the function declaration whose
  /// name matches [search].
  DecoratedType decoratedFunctionType(String search) =>
      variables.decoratedElementType(
          findNode.functionDeclaration(search).declaredElement);

  DecoratedType decoratedTypeParameterBound(String search) => variables
      .decoratedElementType(findNode.typeParameter(search).declaredElement);

  test_constructor_returnType_implicit_dynamic() async {
    await analyze('''
class C {
  C();
}
''');
    var decoratedType = decoratedConstructorDeclaration('C(').returnType;
    expect(decoratedType.node, same(never));
  }

  test_dynamic_type() async {
    await analyze('''
dynamic f() {}
''');
    var decoratedType = decoratedTypeAnnotation('dynamic');
    expect(decoratedFunctionType('f').returnType, same(decoratedType));
    assertEdge(always, decoratedType.node, hard: false);
  }

  test_field_type_simple() async {
    await analyze('''
class C {
  int f = 0;
}
''');
    var decoratedType = decoratedTypeAnnotation('int');
    expect(decoratedType.node, TypeMatcher<NullabilityNodeMutable>());
    expect(
        variables.decoratedElementType(
            findNode.fieldDeclaration('f').fields.variables[0].declaredElement),
        same(decoratedType));
  }

  test_genericFunctionType_namedParameterType() async {
    await analyze('''
void f(void Function({int y}) x) {}
''');
    var decoratedType =
        decoratedGenericFunctionTypeAnnotation('void Function({int y})');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedType));
    expect(decoratedType.node, TypeMatcher<NullabilityNodeMutable>());
    var decoratedIntType = decoratedTypeAnnotation('int');
    expect(decoratedType.namedParameters['y'], same(decoratedIntType));
    expect(decoratedIntType.node, isNotNull);
    expect(decoratedIntType.node, isNot(never));
  }

  test_genericFunctionType_returnType() async {
    await analyze('''
void f(int Function() x) {}
''');
    var decoratedType =
        decoratedGenericFunctionTypeAnnotation('int Function()');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedType));
    expect(decoratedType.node, TypeMatcher<NullabilityNodeMutable>());
    var decoratedIntType = decoratedTypeAnnotation('int');
    expect(decoratedType.returnType, same(decoratedIntType));
    expect(decoratedIntType.node, isNotNull);
    expect(decoratedIntType.node, isNot(never));
  }

  test_genericFunctionType_unnamedParameterType() async {
    await analyze('''
void f(void Function(int) x) {}
''');
    var decoratedType =
        decoratedGenericFunctionTypeAnnotation('void Function(int)');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedType));
    expect(decoratedType.node, TypeMatcher<NullabilityNodeMutable>());
    var decoratedIntType = decoratedTypeAnnotation('int');
    expect(decoratedType.positionalParameters[0], same(decoratedIntType));
    expect(decoratedIntType.node, isNotNull);
    expect(decoratedIntType.node, isNot(never));
  }

  test_interfaceType_generic_instantiate_to_dynamic() async {
    await analyze('''
void f(List x) {}
''');
    var decoratedListType = decoratedTypeAnnotation('List');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedListType));
    expect(decoratedListType.node, isNotNull);
    expect(decoratedListType.node, isNot(never));
    var decoratedArgType = decoratedListType.typeArguments[0];
    expect(decoratedArgType.node, same(always));
  }

  test_interfaceType_generic_instantiate_to_generic_type() async {
    await analyze('''
class C<T> {}
class D<T extends C<int>> {}
void f(D x) {}
''');
    var decoratedListType = decoratedTypeAnnotation('D x');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedListType));
    expect(decoratedListType.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedListType.typeArguments, hasLength(1));
    var decoratedArgType = decoratedListType.typeArguments[0];
    expect(decoratedArgType.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedArgType.typeArguments, hasLength(1));
    var decoratedArgArgType = decoratedArgType.typeArguments[0];
    expect(decoratedArgArgType.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedArgArgType.typeArguments, isEmpty);
  }

  test_interfaceType_generic_instantiate_to_generic_type_2() async {
    await analyze('''
class C<T, U> {}
class D<T extends C<int, String>, U extends C<num, double>> {}
void f(D x) {}
''');
    var decoratedDType = decoratedTypeAnnotation('D x');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedDType));
    expect(decoratedDType.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedDType.typeArguments, hasLength(2));
    var decoratedArg0Type = decoratedDType.typeArguments[0];
    expect(decoratedArg0Type.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedArg0Type.typeArguments, hasLength(2));
    var decoratedArg0Arg0Type = decoratedArg0Type.typeArguments[0];
    expect(decoratedArg0Arg0Type.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedArg0Arg0Type.typeArguments, isEmpty);
    var decoratedArg0Arg1Type = decoratedArg0Type.typeArguments[1];
    expect(decoratedArg0Arg1Type.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedArg0Arg1Type.typeArguments, isEmpty);
    var decoratedArg1Type = decoratedDType.typeArguments[1];
    expect(decoratedArg1Type.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedArg1Type.typeArguments, hasLength(2));
    var decoratedArg1Arg0Type = decoratedArg1Type.typeArguments[0];
    expect(decoratedArg1Arg0Type.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedArg1Arg0Type.typeArguments, isEmpty);
    var decoratedArg1Arg1Type = decoratedArg1Type.typeArguments[1];
    expect(decoratedArg1Arg1Type.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedArg1Arg1Type.typeArguments, isEmpty);
  }

  test_interfaceType_generic_instantiate_to_object() async {
    await analyze('''
class C<T extends Object> {}
void f(C x) {}
''');
    var decoratedListType = decoratedTypeAnnotation('C x');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedListType));
    expect(decoratedListType.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedListType.typeArguments, hasLength(1));
    var decoratedArgType = decoratedListType.typeArguments[0];
    expect(decoratedArgType.node, TypeMatcher<NullabilityNodeMutable>());
    expect(decoratedArgType.typeArguments, isEmpty);
  }

  test_interfaceType_typeParameter() async {
    await analyze('''
void f(List<int> x) {}
''');
    var decoratedListType = decoratedTypeAnnotation('List<int>');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedListType));
    expect(decoratedListType.node, isNotNull);
    expect(decoratedListType.node, isNot(never));
    var decoratedIntType = decoratedTypeAnnotation('int');
    expect(decoratedListType.typeArguments[0], same(decoratedIntType));
    expect(decoratedIntType.node, isNotNull);
    expect(decoratedIntType.node, isNot(never));
  }

  test_topLevelFunction_parameterType_implicit_dynamic() async {
    await analyze('''
void f(x) {}
''');
    var decoratedType =
        variables.decoratedElementType(findNode.simple('x').staticElement);
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedType));
    expect(decoratedType.type.isDynamic, isTrue);
    assertUnion(always, decoratedType.node);
  }

  test_topLevelFunction_parameterType_named_no_default() async {
    await analyze('''
void f({String s}) {}
''');
    var decoratedType = decoratedTypeAnnotation('String');
    var functionType = decoratedFunctionType('f');
    expect(functionType.namedParameters['s'], same(decoratedType));
    expect(decoratedType.node, isNotNull);
    expect(decoratedType.node, isNot(never));
    expect(decoratedType.node, isNot(always));
    expect(functionType.namedParameters['s'].node.isPossiblyOptional, true);
  }

  test_topLevelFunction_parameterType_named_no_default_required() async {
    addMetaPackage();
    await analyze('''
import 'package:meta/meta.dart';
void f({@required String s}) {}
''');
    var decoratedType = decoratedTypeAnnotation('String');
    var functionType = decoratedFunctionType('f');
    expect(functionType.namedParameters['s'], same(decoratedType));
    expect(decoratedType.node, isNotNull);
    expect(decoratedType.node, isNot(never));
    expect(decoratedType.node, isNot(always));
    expect(functionType.namedParameters['s'].node.isPossiblyOptional, false);
  }

  test_topLevelFunction_parameterType_named_with_default() async {
    await analyze('''
void f({String s: 'x'}) {}
''');
    var decoratedType = decoratedTypeAnnotation('String');
    var functionType = decoratedFunctionType('f');
    expect(functionType.namedParameters['s'], same(decoratedType));
    expect(decoratedType.node, isNotNull);
    expect(decoratedType.node, isNot(never));
    expect(functionType.namedParameters['s'].node.isPossiblyOptional, false);
  }

  test_topLevelFunction_parameterType_positionalOptional() async {
    await analyze('''
void f([int i]) {}
''');
    var decoratedType = decoratedTypeAnnotation('int');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedType));
    expect(decoratedType.node, isNotNull);
    expect(decoratedType.node, isNot(never));
  }

  test_topLevelFunction_parameterType_simple() async {
    await analyze('''
void f(int i) {}
''');
    var decoratedType = decoratedTypeAnnotation('int');
    expect(decoratedFunctionType('f').positionalParameters[0],
        same(decoratedType));
    expect(decoratedType.node, isNotNull);
    expect(decoratedType.node, isNot(never));
  }

  test_topLevelFunction_returnType_implicit_dynamic() async {
    await analyze('''
f() {}
''');
    var decoratedType = decoratedFunctionType('f').returnType;
    expect(decoratedType.type.isDynamic, isTrue);
    assertUnion(always, decoratedType.node);
  }

  test_topLevelFunction_returnType_simple() async {
    await analyze('''
int f() => 0;
''');
    var decoratedType = decoratedTypeAnnotation('int');
    expect(decoratedFunctionType('f').returnType, same(decoratedType));
    expect(decoratedType.node, isNotNull);
    expect(decoratedType.node, isNot(never));
  }

  test_type_comment_bang() async {
    await analyze('''
void f(int/*!*/ i) {}
''');
    assertEdge(decoratedTypeAnnotation('int').node, never, hard: true);
  }

  test_type_comment_question() async {
    await analyze('''
void f(int/*?*/ i) {}
''');
    assertEdge(always, decoratedTypeAnnotation('int').node, hard: false);
  }

  test_type_parameter_explicit_bound() async {
    await analyze('''
class C<T extends Object> {}
''');
    var bound = decoratedTypeParameterBound('T');
    expect(decoratedTypeAnnotation('Object'), same(bound));
    expect(bound.node, isNot(always));
    expect(bound.type, typeProvider.objectType);
  }

  test_type_parameter_implicit_bound() async {
    // The implicit bound of `T` is automatically `Object?`.  TODO(paulberry):
    // consider making it possible for type inference to infer an explicit bound
    // of `Object`.
    await analyze('''
class C<T> {}
''');
    var bound = decoratedTypeParameterBound('T');
    assertUnion(always, bound.node);
    expect(bound.type, same(typeProvider.objectType));
  }

  test_variableDeclaration_type_simple() async {
    await analyze('''
main() {
  int i;
}
''');
    var decoratedType = decoratedTypeAnnotation('int');
    expect(decoratedType.node, TypeMatcher<NullabilityNodeMutable>());
  }

  test_void_type() async {
    await analyze('''
void f() {}
''');
    var decoratedType = decoratedTypeAnnotation('void');
    expect(decoratedFunctionType('f').returnType, same(decoratedType));
    assertEdge(always, decoratedType.node, hard: false);
  }
}
