// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/analysis/dependency/node.dart';
import 'package:analyzer/src/dart/ast/token.dart';
import 'package:meta/meta.dart';

/// Collector of information about external nodes referenced by a node.
///
/// The workflow for using it is that the library builder creates a new
/// instance, fills it with names of import prefixes using [addImportPrefix].
/// Then for each node defined in the library, [collect] is called with
/// corresponding AST nodes to record references to external names, and
/// construct the API or implementation [Dependencies].
class ReferenceCollector {
  /// Local scope inside the node, containing local names such as parameters,
  /// local variables, local functions, local type parameters, etc.
  final _LocalScopes _localScopes = _LocalScopes();

  /// The list of names that are referenced without any prefix, neither an
  /// import prefix, nor a target expression.
  _NameSet _unprefixedReferences = _NameSet();

  /// The list of names that are referenced using an import prefix.
  ///
  /// It is filled by [addImportPrefix] and shared across all nodes.
  List<_ReferencedImportPrefixedNames> _importPrefixedReferences = [];

  /// The list of names that are referenced with `super`.
  _NameSet _superReferences = _NameSet();

  /// The set of referenced class members.
  _ClassMemberReferenceSet _memberReferences = _ClassMemberReferenceSet();

  /// Record that the [name] is a name of an import prefix.
  ///
  /// So, when we see code like `prefix.foo` we know that `foo` should be
  /// resolved in the import scope that corresponds to `prefix` (unless the
  /// name `prefix` is shadowed by a local declaration).
  void addImportPrefix(String name) {
    assert(_localScopes.isEmpty);
    for (var import in _importPrefixedReferences) {
      if (import.prefix == name) {
        return;
      }
    }
    _importPrefixedReferences.add(_ReferencedImportPrefixedNames(name));
  }

  /// Construct and return a new [Dependencies] with the given [tokenSignature]
  /// and all recorded references to external nodes in the given AST nodes.
  Dependencies collect(List<int> tokenSignature,
      {String enclosingClassName,
      String thisNodeName,
      List<ConstructorInitializer> constructorInitializers,
      TypeName enclosingSuperClass,
      Expression expression,
      ExtendsClause extendsClause,
      FormalParameterList formalParameters,
      FormalParameterList formalParametersForDefaultValues,
      FunctionBody functionBody,
      ImplementsClause implementsClause,
      OnClause onClause,
      ConstructorName redirectedConstructor,
      TypeAnnotation returnType,
      TypeName superClass,
      TypeAnnotation type,
      TypeParameterList typeParameters,
      TypeParameterList typeParameters2,
      WithClause withClause}) {
    _localScopes.enter();

    // The name of the node shadows any external names.
    if (enclosingClassName != null) {
      _localScopes.add(enclosingClassName);
    }
    if (thisNodeName != null) {
      _localScopes.add(thisNodeName);
    }

    // Add type parameters first, they might be referenced later.
    _visitTypeParameterList(typeParameters);
    _visitTypeParameterList(typeParameters2);

    // Parts of classes.
    _visitTypeAnnotation(extendsClause?.superclass);
    _visitTypeAnnotation(superClass);
    _visitTypeAnnotations(withClause?.mixinTypes);
    _visitTypeAnnotations(onClause?.superclassConstraints);
    _visitTypeAnnotations(implementsClause?.interfaces);

    // Parts of executables.
    _visitFormalParameterList(formalParameters);
    _visitFormalParameterListDefaults(formalParametersForDefaultValues);
    _visitTypeAnnotation(returnType);
    _visitFunctionBody(functionBody);

    // Parts of constructors.
    _visitConstructorInitializers(enclosingSuperClass, constructorInitializers);
    _visitConstructorName(redirectedConstructor);

    // Parts of variables.
    _visitTypeAnnotation(type);
    _visitExpression(expression);

    _localScopes.exit();

    var unprefixedReferencedNames = _unprefixedReferences.toList();
    _unprefixedReferences = _NameSet();

    var importPrefixCount = 0;
    for (var i = 0; i < _importPrefixedReferences.length; i++) {
      var import = _importPrefixedReferences[i];
      if (import.names.isNotEmpty) {
        importPrefixCount++;
      }
    }

    var importPrefixes = List<String>(importPrefixCount);
    var importPrefixedReferencedNames = List<List<String>>(importPrefixCount);
    var importIndex = 0;
    for (var i = 0; i < _importPrefixedReferences.length; i++) {
      var import = _importPrefixedReferences[i];

      if (import.names.isNotEmpty) {
        importPrefixes[importIndex] = import.prefix;
        importPrefixedReferencedNames[importIndex] = import.names.toList();
        importIndex++;
      }

      import.clear();
    }

    var superReferencedNames = _superReferences.toList();
    _superReferences = _NameSet();

    var classMemberReferences = _memberReferences.toList();
    _memberReferences = _ClassMemberReferenceSet();

    return Dependencies(
      tokenSignature,
      unprefixedReferencedNames,
      importPrefixes,
      importPrefixedReferencedNames,
      superReferencedNames,
      classMemberReferences,
    );
  }

  /// Return the collector for the import prefix with the given [name].
  _ReferencedImportPrefixedNames _importPrefix(String name) {
    assert(!_localScopes.contains(name));
    for (var i = 0; i < _importPrefixedReferences.length; i++) {
      var references = _importPrefixedReferences[i];
      if (references.prefix == name) {
        return references;
      }
    }
    return null;
  }

  void _recordClassMemberReference(DartType targetType, String name) {
    if (targetType is InterfaceType) {
      _memberReferences.add(targetType.element, name);
    }
  }

  /// Record a new unprefixed name reference.
  void _recordUnprefixedReference(String name) {
    assert(!_localScopes.contains(name));
    _unprefixedReferences.add(name);
  }

  void _visitAdjacentStrings(AdjacentStrings node) {
    var strings = node.strings;
    for (var i = 0; i < strings.length; i++) {
      var string = strings[i];
      _visitExpression(string);
    }
  }

  void _visitArgumentList(ArgumentList node) {
    var arguments = node.arguments;
    for (var i = 0; i < arguments.length; i++) {
      var argument = arguments[i];
      _visitExpression(argument);
    }
  }

  void _visitAssignmentExpression(AssignmentExpression node) {
    var assignmentType = node.operator.type;

    _visitExpression(node.leftHandSide,
        get: assignmentType != TokenType.EQ, set: true);
    _visitExpression(node.rightHandSide);

    if (assignmentType != TokenType.EQ &&
        assignmentType != TokenType.QUESTION_QUESTION_EQ) {
      var operatorType = operatorFromCompoundAssignment(assignmentType);
      _recordClassMemberReference(
        node.leftHandSide.staticType,
        operatorType.lexeme,
      );
    }
  }

  void _visitBinaryExpression(BinaryExpression node) {
    var operatorName = node.operator.lexeme;
    var leftOperand = node.leftOperand;
    if (leftOperand is SuperExpression) {
      _superReferences.add(operatorName);
    } else {
      _visitExpression(leftOperand);
      _recordClassMemberReference(leftOperand.staticType, operatorName);
    }
    _visitExpression(node.rightOperand);
  }

  void _visitBlock(Block node) {
    if (node == null) return;

    _visitStatements(node.statements);
  }

  void _visitCascadeExpression(CascadeExpression node) {
    _visitExpression(node.target);
    var sections = node.cascadeSections;
    for (var i = 0; i < sections.length; i++) {
      var section = sections[i];
      _visitExpression(section);
    }
  }

  /// Record reference to the constructor of the [type] with the given [name].
  void _visitConstructor(TypeName type, SimpleIdentifier name) {
    _visitTypeAnnotation(type);

    if (name != null) {
      _recordClassMemberReference(type.type, name.name);
    } else {
      _recordClassMemberReference(type.type, '');
    }
  }

  void _visitConstructorInitializers(
      TypeName superClass, List<ConstructorInitializer> initializers) {
    if (initializers == null) return;

    for (var i = 0; i < initializers.length; i++) {
      var initializer = initializers[i];
      if (initializer is AssertInitializer) {
        // TODO(scheglov) implement
      } else if (initializer is ConstructorFieldInitializer) {
        _visitExpression(initializer.expression);
      } else if (initializer is SuperConstructorInvocation) {
        _visitConstructor(superClass, initializer.constructorName);
        _visitArgumentList(initializer.argumentList);
      } else if (initializer is RedirectingConstructorInvocation) {
        _visitArgumentList(initializer.argumentList);
        // Strongly speaking, we reference a field of the enclosing class.
        //
        // However the current plan is to resolve the whole library on a change.
        // So, we will resolve the enclosing constructor anyway.
      } else {
        throw UnimplementedError('(${initializer.runtimeType}) $initializer');
      }
    }
  }

  void _visitConstructorName(ConstructorName node) {
    if (node == null) return;

    _visitConstructor(node.type, node.name);
  }

  void _visitExpression(Expression node, {bool get: true, bool set: false}) {
    if (node == null) return;

    if (node is AdjacentStrings) {
      _visitAdjacentStrings(node);
    } else if (node is AsExpression) {
      _visitExpression(node.expression);
      _visitTypeAnnotation(node.type);
    } else if (node is AssignmentExpression) {
      _visitAssignmentExpression(node);
    } else if (node is AwaitExpression) {
      _visitExpression(node.expression);
    } else if (node is BinaryExpression) {
      _visitBinaryExpression(node);
    } else if (node is BooleanLiteral) {
      // no dependencies
    } else if (node is CascadeExpression) {
      _visitCascadeExpression(node);
    } else if (node is ConditionalExpression) {
      _visitExpression(node.condition);
      _visitExpression(node.thenExpression);
      _visitExpression(node.elseExpression);
    } else if (node is DoubleLiteral) {
      // no dependencies
    } else if (node is FunctionExpression) {
      _visitFunctionExpression(node);
    } else if (node is FunctionExpressionInvocation) {
      _visitExpression(node.function);
      _visitTypeArguments(node.typeArguments);
      _visitArgumentList(node.argumentList);
    } else if (node is IndexExpression) {
      _visitIndexExpression(node, get: get, set: set);
    } else if (node is InstanceCreationExpression) {
      _visitInstanceCreationExpression(node);
    } else if (node is IntegerLiteral) {
      // no dependencies
    } else if (node is IsExpression) {
      _visitExpression(node.expression);
      _visitTypeAnnotation(node.type);
    } else if (node is ListLiteral) {
      _visitListLiteral(node);
    } else if (node is MapLiteral) {
      _visitMapLiteral(node);
    } else if (node is MethodInvocation) {
      _visitMethodInvocation(node);
    } else if (node is NamedExpression) {
      _visitExpression(node.expression);
    } else if (node is NullLiteral) {
      // no dependencies
    } else if (node is ParenthesizedExpression) {
      _visitExpression(node.expression);
    } else if (node is PostfixExpression) {
      _visitPostfixExpression(node);
    } else if (node is PrefixExpression) {
      _visitPrefixExpression(node);
    } else if (node is PrefixedIdentifier) {
      _visitPrefixedIdentifier(node);
    } else if (node is PropertyAccess) {
      _visitPropertyAccess(node, get: get, set: set);
    } else if (node is RethrowExpression) {
      // no dependencies
    } else if (node is SetLiteral) {
      _visitSetLiteral(node);
    } else if (node is SimpleIdentifier) {
      _visitSimpleIdentifier(node, get: get, set: set);
    } else if (node is SimpleStringLiteral) {
      // no dependencies
    } else if (node is StringInterpolation) {
      _visitStringInterpolation(node);
    } else if (node is SymbolLiteral) {
      // no dependencies
    } else if (node is ThisExpression) {
      // Strongly speaking, "this" should add dependencies.
      // Just like any class reference, it depends on the class hierarchy.
      // For example adding a new type to the `implements` clause might make
      // it OK to pass `this` as an argument of an invocation.
      //
      // However the current plan is to resolve the whole library on a change.
      // So, we will resolve all implementations that reference `this`.
    } else if (node is ThrowExpression) {
      _visitExpression(node.expression);
    } else {
      throw UnimplementedError('(${node.runtimeType}) $node');
    }
  }

  void _visitForEachStatement(ForEachStatement node) {
    var loopVariable = node.loopVariable;
    if (loopVariable != null) {
      _visitTypeAnnotation(loopVariable.type);
    }

    var loopIdentifier = node.identifier;
    if (loopIdentifier != null) {
      _visitExpression(loopIdentifier);
    }

    _visitExpression(node.iterable);

    _localScopes.enter();
    if (loopVariable != null) {
      _localScopes.add(loopVariable.identifier.name);
    }

    _visitStatement(node.body);

    _localScopes.exit();
  }

  void _visitFormalParameterList(FormalParameterList node) {
    if (node == null) return;

    var parameters = node.parameters;
    for (var i = 0; i < parameters.length; i++) {
      FormalParameter parameter = parameters[i];
      if (parameter is DefaultFormalParameter) {
        DefaultFormalParameter defaultParameter = parameter;
        parameter = defaultParameter.parameter;
      }
      if (parameter.identifier != null) {
        _localScopes.add(parameter.identifier.name);
      }
      if (parameter is FieldFormalParameter) {
        _visitTypeAnnotation(parameter.type);
        // Strongly speaking, we reference a field of the enclosing class.
        //
        // However the current plan is to resolve the whole library on a change.
        // So, we will resolve the enclosing constructor anyway.
      } else if (parameter is FunctionTypedFormalParameter) {
        _visitTypeAnnotation(parameter.returnType);
        _visitFormalParameterList(parameter.parameters);
      } else if (parameter is SimpleFormalParameter) {
        _visitTypeAnnotation(parameter.type);
      } else {
        throw StateError('Unexpected: (${parameter.runtimeType}) $parameter');
      }
    }
  }

  void _visitFormalParameterListDefaults(FormalParameterList node) {
    if (node == null) return;

    var parameters = node.parameters;
    for (var i = 0; i < parameters.length; i++) {
      FormalParameter parameter = parameters[i];
      if (parameter is DefaultFormalParameter) {
        _visitExpression(parameter.defaultValue);
      }
    }
  }

  void _visitForStatement(ForStatement node) {
    _localScopes.enter();

    _visitVariableList(node.variables);
    _visitExpression(node.initialization);
    _visitExpression(node.condition);

    var updaters = node.updaters;
    for (var i = 0; i < updaters.length; i++) {
      _visitExpression(updaters[i]);
    }

    _visitStatement(node.body);

    _localScopes.exit();
  }

  void _visitFunctionBody(FunctionBody node) {
    if (node == null) return;

    if (node is BlockFunctionBody) {
      _visitStatement(node.block);
    } else if (node is EmptyFunctionBody) {
      return;
    } else if (node is ExpressionFunctionBody) {
      _visitExpression(node.expression);
    } else {
      throw UnimplementedError('(${node.runtimeType}) $node');
    }
  }

  void _visitFunctionDeclarationStatement(FunctionDeclarationStatement node) {
    var function = node.functionDeclaration;
    _visitTypeAnnotation(function.returnType);
    _visitFunctionExpression(function.functionExpression);
  }

  void _visitFunctionExpression(FunctionExpression node) {
    _localScopes.enter();
    _visitTypeParameterList(node.typeParameters);
    _visitFormalParameterList(node.parameters);
    _visitFormalParameterListDefaults(node.parameters);
    _visitFunctionBody(node.body);
    _localScopes.exit();
  }

  void _visitIndexExpression(IndexExpression node,
      {@required bool get, @required bool set}) {
    var target = node.target;
    if (target == null) {
      // no dependencies
    } else if (target is SuperExpression) {
      if (get) {
        _superReferences.add('[]');
      }
      if (set) {
        _superReferences.add('[]=');
      }
    } else {
      _visitExpression(target);
      var targetType = target.staticType;
      if (get) {
        _recordClassMemberReference(targetType, '[]');
      }
      if (set) {
        _recordClassMemberReference(targetType, '[]=');
      }
    }

    _visitExpression(node.index);
  }

  void _visitInstanceCreationExpression(InstanceCreationExpression node) {
    _visitConstructorName(node.constructorName);
    _visitArgumentList(node.argumentList);
  }

  void _visitListLiteral(ListLiteral node) {
    _visitTypeArguments(node.typeArguments);
    var elements = node.elements;
    for (var i = 0; i < elements.length; i++) {
      var element = elements[i];
      _visitExpression(element);
    }
  }

  void _visitMapLiteral(MapLiteral node) {
    _visitTypeArguments(node.typeArguments);
    var entries = node.entries;
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i];
      _visitExpression(entry.key);
      _visitExpression(entry.value);
    }
  }

  void _visitMethodInvocation(MethodInvocation node) {
    var realTarget = node.realTarget;
    if (realTarget == null) {
      _visitExpression(node.methodName);
    } else if (realTarget is SuperExpression) {
      _superReferences.add(node.methodName.name);
    } else {
      _visitExpression(node.target);
      _recordClassMemberReference(
        realTarget.staticType,
        node.methodName.name,
      );
    }
    _visitTypeArguments(node.typeArguments);
    _visitArgumentList(node.argumentList);
  }

  void _visitPostfixExpression(PostfixExpression node) {
    _visitExpression(node.operand);

    var operator = node.operator.type;
    if (operator == TokenType.MINUS_MINUS) {
      _recordClassMemberReference(node.operand.staticType, '-');
    } else if (operator == TokenType.PLUS_PLUS) {
      _recordClassMemberReference(node.operand.staticType, '+');
    } else {
      throw UnimplementedError('$operator');
    }
  }

  void _visitPrefixedIdentifier(PrefixedIdentifier node) {
    var prefix = node.prefix;
    var prefixElement = prefix.staticElement;
    if (prefixElement is PrefixElement) {
      var prefixName = prefix.name;
      var importPrefix = _importPrefix(prefixName);
      importPrefix.add(node.identifier.name);
    } else {
      _visitExpression(prefix);
      _recordClassMemberReference(prefix.staticType, node.identifier.name);
    }
  }

  void _visitPrefixExpression(PrefixExpression node) {
    _visitExpression(node.operand);

    var operatorName = node.operator.lexeme;
    if (operatorName == '-') operatorName = 'unary-';

    _recordClassMemberReference(node.operand.staticType, operatorName);
  }

  void _visitPropertyAccess(PropertyAccess node,
      {@required bool get, @required bool set}) {
    var realTarget = node.realTarget;
    var name = node.propertyName.name;

    if (realTarget is SuperExpression) {
      if (get) {
        _superReferences.add(name);
      }
      if (set) {
        _superReferences.add('$name=');
      }
    } else {
      _visitExpression(node.target);
      if (get) {
        _recordClassMemberReference(realTarget.staticType, name);
      }
      if (set) {
        _recordClassMemberReference(realTarget.staticType, '$name=');
      }
    }
  }

  void _visitSetLiteral(SetLiteral node) {
    _visitTypeArguments(node.typeArguments);
    var elements = node.elements;
    for (var i = 0; i < elements.length; i++) {
      var element = elements[i];
      _visitExpression(element);
    }
  }

  void _visitSimpleIdentifier(SimpleIdentifier node,
      {@required bool get, @required bool set}) {
    if (node.isSynthetic) return;

    var name = node.name;
    if (_localScopes.contains(name) || name == 'void' || name == 'dynamic') {
      return;
    }

    if (get) {
      _recordUnprefixedReference(name);
    }
    if (set) {
      _recordUnprefixedReference('$name=');
    }
  }

  void _visitStatement(Statement node) {
    if (node == null) return;

    if (node is AssertStatement) {
      _visitExpression(node.condition);
      _visitExpression(node.message);
    } else if (node is Block) {
      _visitBlock(node);
    } else if (node is BreakStatement) {
      // nothing
    } else if (node is ContinueStatement) {
      // nothing
    } else if (node is DoStatement) {
      _visitStatement(node.body);
      _visitExpression(node.condition);
    } else if (node is EmptyStatement) {
      // nothing
    } else if (node is ExpressionStatement) {
      _visitExpression(node.expression);
    } else if (node is ForEachStatement) {
      _visitForEachStatement(node);
    } else if (node is ForStatement) {
      _visitForStatement(node);
    } else if (node is FunctionDeclarationStatement) {
      _visitFunctionDeclarationStatement(node);
    } else if (node is IfStatement) {
      _visitExpression(node.condition);
      _visitStatement(node.thenStatement);
      _visitStatement(node.elseStatement);
    } else if (node is LabeledStatement) {
      _visitStatement(node.statement);
    } else if (node is ReturnStatement) {
      _visitExpression(node.expression);
    } else if (node is SwitchStatement) {
      _visitSwitchStatement(node);
    } else if (node is TryStatement) {
      _visitTryStatement(node);
    } else if (node is VariableDeclarationStatement) {
      _visitVariableList(node.variables);
    } else if (node is WhileStatement) {
      _visitExpression(node.condition);
      _visitStatement(node.body);
    } else if (node is YieldStatement) {
      _visitExpression(node.expression);
    } else {
      throw UnimplementedError('(${node.runtimeType}) $node');
    }
  }

  void _visitStatements(List<Statement> statements) {
    _localScopes.enter();

    for (var i = 0; i < statements.length; i++) {
      var statement = statements[i];
      if (statement is FunctionDeclarationStatement) {
        _localScopes.add(statement.functionDeclaration.name.name);
      } else if (statement is VariableDeclarationStatement) {
        var variables = statement.variables.variables;
        for (int i = 0; i < variables.length; i++) {
          _localScopes.add(variables[i].name.name);
        }
      }
    }

    for (var i = 0; i < statements.length; i++) {
      var statement = statements[i];
      _visitStatement(statement);
    }

    _localScopes.exit();
  }

  void _visitStringInterpolation(StringInterpolation node) {
    var elements = node.elements;
    for (var i = 0; i < elements.length; i++) {
      var element = elements[i];
      if (element is InterpolationExpression) {
        _visitExpression(element.expression);
      }
    }
  }

  void _visitSwitchStatement(SwitchStatement node) {
    _visitExpression(node.expression);
    var members = node.members;
    for (var i = 0; i < members.length; i++) {
      var member = members[i];
      if (member is SwitchCase) {
        _visitExpression(member.expression);
      }
      _visitStatements(member.statements);
    }
  }

  void _visitTryStatement(TryStatement node) {
    _visitBlock(node.body);

    var catchClauses = node.catchClauses;
    for (var i = 0; i < catchClauses.length; i++) {
      var catchClause = catchClauses[i];
      _visitTypeAnnotation(catchClause.exceptionType);

      _localScopes.enter();

      var exceptionParameter = catchClause.exceptionParameter;
      if (exceptionParameter != null) {
        _localScopes.add(exceptionParameter.name);
      }

      var stackTraceParameter = catchClause.stackTraceParameter;
      if (stackTraceParameter != null) {
        _localScopes.add(stackTraceParameter.name);
      }

      _visitBlock(catchClause.body);

      _localScopes.exit();
    }

    _visitBlock(node.finallyBlock);
  }

  void _visitTypeAnnotation(TypeAnnotation node) {
    if (node == null) return;

    if (node is GenericFunctionType) {
      _localScopes.enter();

      if (node.typeParameters != null) {
        var typeParameters = node.typeParameters.typeParameters;
        for (var i = 0; i < typeParameters.length; i++) {
          var typeParameter = typeParameters[i];
          _localScopes.add(typeParameter.name.name);
        }
        for (var i = 0; i < typeParameters.length; i++) {
          var typeParameter = typeParameters[i];
          _visitTypeAnnotation(typeParameter.bound);
        }
      }

      _visitTypeAnnotation(node.returnType);
      _visitFormalParameterList(node.parameters);

      _localScopes.exit();
    } else if (node is TypeName) {
      var identifier = node.name;
      _visitExpression(identifier);
      _visitTypeArguments(node.typeArguments);
    } else {
      throw UnimplementedError('(${node.runtimeType}) $node');
    }
  }

  void _visitTypeAnnotations(List<TypeAnnotation> typeAnnotations) {
    if (typeAnnotations == null) return;

    for (var i = 0; i < typeAnnotations.length; i++) {
      var typeAnnotation = typeAnnotations[i];
      _visitTypeAnnotation(typeAnnotation);
    }
  }

  void _visitTypeArguments(TypeArgumentList node) {
    if (node == null) return;

    _visitTypeAnnotations(node.arguments);
  }

  void _visitTypeParameterList(TypeParameterList node) {
    if (node == null) return;

    var typeParameters = node.typeParameters;

    // Define all type parameters in the local scope.
    for (var i = 0; i < typeParameters.length; i++) {
      var typeParameter = typeParameters[i];
      _localScopes.add(typeParameter.name.name);
    }

    // Record bounds.
    for (var i = 0; i < typeParameters.length; i++) {
      var typeParameter = typeParameters[i];
      _visitTypeAnnotation(typeParameter.bound);
    }
  }

  void _visitVariableList(VariableDeclarationList node) {
    if (node == null) return;

    _visitTypeAnnotation(node.type);

    var variables = node.variables;
    for (int i = 0; i < variables.length; i++) {
      var variable = variables[i];
      _localScopes.add(variable.name.name);
      _visitExpression(variable.initializer);
    }
  }
}

/// The sorted set of [ClassMemberReference]s.
class _ClassMemberReferenceSet {
  final List<ClassMemberReference> references = [];

  void add(ClassElement class_, String name) {
    var target = LibraryQualifiedName(class_.library.source.uri, class_.name);
    var reference = ClassMemberReference(target, name);
    if (!references.contains(reference)) {
      references.add(reference);
    }
  }

  /// Return the sorted list of unique class member references.
  List<ClassMemberReference> toList() {
    references.sort(ClassMemberReference.compare);
    return references;
  }
}

/// The stack of names that are defined in a local scope inside the node,
/// such as parameters, local variables, local functions, local type
/// parameters, etc.
class _LocalScopes {
  /// The stack of name sets.
  final List<_NameSet> scopes = [];

  bool get isEmpty => scopes.isEmpty;

  /// Add the given [name] to the current local scope.
  void add(String name) {
    scopes.last.add(name);
  }

  /// Return whether the given [name] is defined in one of the local scopes.
  bool contains(String name) {
    for (var i = 0; i < scopes.length; i++) {
      if (scopes[i].contains(name)) {
        return true;
      }
    }
    return false;
  }

  /// Enter a new local scope, e.g. a block, or a type parameter scope.
  void enter() {
    scopes.add(_NameSet());
  }

  /// Exit the current local scope.
  void exit() {
    scopes.removeLast();
  }
}

class _NameSet {
  final List<String> names = [];

  bool get isNotEmpty => names.isNotEmpty;

  void add(String name) {
    // TODO(scheglov) consider just adding, but toList() sort and unique
    if (!contains(name)) {
      names.add(name);
    }
  }

  bool contains(String name) => names.contains(name);

  List<String> toList() {
    names.sort(_compareStrings);
    return names;
  }

  static int _compareStrings(String first, String second) {
    return first.compareTo(second);
  }
}

class _ReferencedImportPrefixedNames {
  final String prefix;
  _NameSet names = _NameSet();

  _ReferencedImportPrefixedNames(this.prefix);

  void add(String name) {
    names.add(name);
  }

  void clear() {
    names = _NameSet();
  }
}
