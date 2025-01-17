// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.kernel_procedure_builder;

import 'package:kernel/ast.dart'
    show
        Arguments,
        AsyncMarker,
        Class,
        Constructor,
        ConstructorInvocation,
        DartType,
        DynamicType,
        EmptyStatement,
        Expression,
        FunctionNode,
        Initializer,
        InterfaceType,
        Member,
        Name,
        Procedure,
        ProcedureKind,
        RedirectingInitializer,
        Statement,
        StaticInvocation,
        StringLiteral,
        SuperInitializer,
        TypeParameter,
        TypeParameterType,
        VariableDeclaration,
        VoidType,
        setParents;

import 'package:kernel/type_algebra.dart' show containsTypeVariable, substitute;

import '../loader.dart' show Loader;

import '../messages.dart'
    show
        Message,
        messageConstFactoryRedirectionToNonConst,
        messageMoreThanOneSuperOrThisInitializer,
        messageNonInstanceTypeVariableUse,
        messagePatchDeclarationMismatch,
        messagePatchDeclarationOrigin,
        messagePatchNonExternal,
        messageSuperInitializerNotLast,
        messageThisInitializerNotAlone,
        noLength;

import '../problems.dart' show unexpected;

import '../source/source_library_builder.dart' show SourceLibraryBuilder;

import '../type_inference/type_inference_engine.dart'
    show IncludesTypeParametersCovariantly;

import 'kernel_builder.dart'
    show
        ClassBuilder,
        ConstructorReferenceBuilder,
        Declaration,
        FormalParameterBuilder,
        KernelFormalParameterBuilder,
        KernelLibraryBuilder,
        KernelMetadataBuilder,
        KernelTypeBuilder,
        KernelTypeVariableBuilder,
        LibraryBuilder,
        MetadataBuilder,
        ProcedureBuilder,
        TypeVariableBuilder,
        isRedirectingGenerativeConstructorImplementation;

import 'kernel_shadow_ast.dart'
    show ShadowProcedure, VariableDeclarationJudgment;

import 'redirecting_factory_body.dart' show RedirectingFactoryBody;

import 'expression_generator_helper.dart' show ExpressionGeneratorHelper;

abstract class KernelFunctionBuilder
    extends ProcedureBuilder<KernelTypeBuilder> {
  final String nativeMethodName;

  FunctionNode function;

  Statement actualBody;

  KernelFunctionBuilder(
      List<MetadataBuilder> metadata,
      int modifiers,
      KernelTypeBuilder returnType,
      String name,
      List<TypeVariableBuilder> typeVariables,
      List<FormalParameterBuilder> formals,
      KernelLibraryBuilder compilationUnit,
      int charOffset,
      this.nativeMethodName)
      : super(metadata, modifiers, returnType, name, typeVariables, formals,
            compilationUnit, charOffset);

  KernelFunctionBuilder get actualOrigin;

  void set body(Statement newBody) {
//    if (newBody != null) {
//      if (isAbstract) {
//        // TODO(danrubel): Is this check needed?
//        return internalProblem(messageInternalProblemBodyOnAbstractMethod,
//            newBody.fileOffset, fileUri);
//      }
//    }
    actualBody = newBody;
    if (function != null) {
      // A forwarding semi-stub is a method that is abstract in the source code,
      // but which needs to have a forwarding stub body in order to ensure that
      // covariance checks occur.  We don't want to replace the forwarding stub
      // body with null.
      var parent = function.parent;
      if (!(newBody == null &&
          parent is Procedure &&
          parent.isForwardingSemiStub)) {
        function.body = newBody;
        newBody?.parent = function;
      }
    }
  }

  void setRedirectingFactoryBody(Member target, List<DartType> typeArguments) {
    if (actualBody != null) {
      unexpected("null", "${actualBody.runtimeType}", charOffset, fileUri);
    }
    actualBody = new RedirectingFactoryBody(target, typeArguments);
    function.body = actualBody;
    actualBody?.parent = function;
    if (isPatch) {
      actualOrigin.setRedirectingFactoryBody(target, typeArguments);
    }
  }

  Statement get body => actualBody ??= new EmptyStatement();

  bool get isNative => nativeMethodName != null;

  FunctionNode buildFunction(LibraryBuilder library) {
    assert(function == null);
    FunctionNode result = new FunctionNode(body, asyncMarker: asyncModifier);
    IncludesTypeParametersCovariantly needsCheckVisitor;
    if (!isConstructor && !isFactory && parent is ClassBuilder) {
      Class enclosingClass = parent.target;
      if (enclosingClass.typeParameters.isNotEmpty) {
        needsCheckVisitor = new IncludesTypeParametersCovariantly(
            enclosingClass.typeParameters);
      }
    }
    if (typeVariables != null) {
      for (KernelTypeVariableBuilder t in typeVariables) {
        TypeParameter parameter = t.parameter;
        result.typeParameters.add(parameter);
        if (needsCheckVisitor != null) {
          if (parameter.bound.accept(needsCheckVisitor)) {
            parameter.isGenericCovariantImpl = true;
          }
        }
      }
      setParents(result.typeParameters, result);
    }
    if (formals != null) {
      for (KernelFormalParameterBuilder formal in formals) {
        VariableDeclaration parameter = formal.build(library, 0);
        if (needsCheckVisitor != null) {
          if (parameter.type.accept(needsCheckVisitor)) {
            parameter.isGenericCovariantImpl = true;
          }
        }
        if (formal.isNamed) {
          result.namedParameters.add(parameter);
        } else {
          result.positionalParameters.add(parameter);
        }
        parameter.parent = result;
        if (formal.isRequired) {
          result.requiredParameterCount++;
        }
      }
    }
    if (isSetter && (formals?.length != 1 || formals[0].isOptional)) {
      // Replace illegal parameters by single dummy parameter.
      // Do this after building the parameters, since the diet listener
      // assumes that parameters are built, even if illegal in number.
      VariableDeclaration parameter =
          new VariableDeclarationJudgment("#synthetic", 0);
      result.positionalParameters.clear();
      result.positionalParameters.add(parameter);
      parameter.parent = result;
      result.namedParameters.clear();
      result.requiredParameterCount = 1;
    }
    if (returnType != null) {
      result.returnType = returnType.build(library);
    }
    if (!isConstructor && !isInstanceMember && parent is ClassBuilder) {
      List<TypeParameter> typeParameters = parent.target.typeParameters;
      if (typeParameters.isNotEmpty) {
        Map<TypeParameter, DartType> substitution;
        DartType removeTypeVariables(DartType type) {
          if (substitution == null) {
            substitution = <TypeParameter, DartType>{};
            for (TypeParameter parameter in typeParameters) {
              substitution[parameter] = const DynamicType();
            }
          }
          library.addProblem(
              messageNonInstanceTypeVariableUse, charOffset, noLength, fileUri);
          return substitute(type, substitution);
        }

        Set<TypeParameter> set = typeParameters.toSet();
        for (VariableDeclaration parameter in result.positionalParameters) {
          if (containsTypeVariable(parameter.type, set)) {
            parameter.type = removeTypeVariables(parameter.type);
          }
        }
        for (VariableDeclaration parameter in result.namedParameters) {
          if (containsTypeVariable(parameter.type, set)) {
            parameter.type = removeTypeVariables(parameter.type);
          }
        }
        if (containsTypeVariable(result.returnType, set)) {
          result.returnType = removeTypeVariables(result.returnType);
        }
      }
    }
    return function = result;
  }

  Member build(SourceLibraryBuilder library);

  void becomeNative(Loader loader) {
    Declaration constructor = loader.getNativeAnnotation();
    Arguments arguments =
        new Arguments(<Expression>[new StringLiteral(nativeMethodName)]);
    Expression annotation;
    if (constructor.isConstructor) {
      annotation = new ConstructorInvocation(constructor.target, arguments)
        ..isConst = true;
    } else {
      annotation = new StaticInvocation(constructor.target, arguments)
        ..isConst = true;
    }
    target.addAnnotation(annotation);
  }

  bool checkPatch(KernelFunctionBuilder patch) {
    if (!isExternal) {
      patch.library.addProblem(
          messagePatchNonExternal, patch.charOffset, noLength, patch.fileUri,
          context: [
            messagePatchDeclarationOrigin.withLocation(
                fileUri, charOffset, noLength)
          ]);
      return false;
    }
    return true;
  }

  void reportPatchMismatch(Declaration patch) {
    library.addProblem(messagePatchDeclarationMismatch, patch.charOffset,
        noLength, patch.fileUri, context: [
      messagePatchDeclarationOrigin.withLocation(fileUri, charOffset, noLength)
    ]);
  }
}

class KernelProcedureBuilder extends KernelFunctionBuilder {
  final ShadowProcedure procedure;
  final int charOpenParenOffset;

  AsyncMarker actualAsyncModifier = AsyncMarker.Sync;

  @override
  KernelProcedureBuilder actualOrigin;

  KernelProcedureBuilder(
      List<MetadataBuilder> metadata,
      int modifiers,
      KernelTypeBuilder returnType,
      String name,
      List<TypeVariableBuilder> typeVariables,
      List<FormalParameterBuilder> formals,
      ProcedureKind kind,
      KernelLibraryBuilder compilationUnit,
      int startCharOffset,
      int charOffset,
      this.charOpenParenOffset,
      int charEndOffset,
      [String nativeMethodName])
      : procedure = new ShadowProcedure(null, kind, null, returnType == null,
            fileUri: compilationUnit?.fileUri)
          ..startFileOffset = startCharOffset
          ..fileOffset = charOffset
          ..fileEndOffset = charEndOffset,
        super(metadata, modifiers, returnType, name, typeVariables, formals,
            compilationUnit, charOffset, nativeMethodName);

  @override
  KernelProcedureBuilder get origin => actualOrigin ?? this;

  ProcedureKind get kind => procedure.kind;

  AsyncMarker get asyncModifier => actualAsyncModifier;

  Statement get body {
    if (actualBody == null && !isAbstract && !isExternal) {
      actualBody = new EmptyStatement();
    }
    return actualBody;
  }

  void set asyncModifier(AsyncMarker newModifier) {
    actualAsyncModifier = newModifier;
    if (function != null) {
      // No parent, it's an enum.
      function.asyncMarker = actualAsyncModifier;
      function.dartAsyncMarker = actualAsyncModifier;
    }
  }

  bool get isEligibleForTopLevelInference {
    if (library.legacyMode) return false;
    if (isInstanceMember) {
      if (returnType == null) return true;
      if (formals != null) {
        for (var formal in formals) {
          if (formal.type == null) return true;
        }
      }
    }
    return false;
  }

  Procedure build(SourceLibraryBuilder library) {
    // TODO(ahe): I think we may call this twice on parts. Investigate.
    if (procedure.name == null) {
      procedure.function = buildFunction(library);
      procedure.function.parent = procedure;
      procedure.function.fileOffset = charOpenParenOffset;
      procedure.function.fileEndOffset = procedure.fileEndOffset;
      procedure.isAbstract = isAbstract;
      procedure.isStatic = isStatic;
      procedure.isExternal = isExternal;
      procedure.isConst = isConst;
      procedure.name = new Name(name, library.target);
    }
    if (!library.loader.target.legacyMode &&
        (isSetter || (isOperator && name == '[]=')) &&
        returnType == null) {
      procedure.function.returnType = const VoidType();
    }
    return procedure;
  }

  @override
  void buildOutlineExpressions(LibraryBuilder library) {
    ClassBuilder classBuilder = isClassMember ? parent : null;
    KernelMetadataBuilder.buildAnnotations(
        target,
        metadata,
        library,
        classBuilder,
        this,
        computeFormalParameterScope(classBuilder?.scope ?? library.scope));
  }

  Procedure get target => origin.procedure;

  @override
  int finishPatch() {
    if (!isPatch) return 0;

    // TODO(ahe): restore file-offset once we track both origin and patch file
    // URIs. See https://github.com/dart-lang/sdk/issues/31579
    origin.procedure.fileUri = fileUri;
    origin.procedure.startFileOffset = procedure.startFileOffset;
    origin.procedure.fileOffset = procedure.fileOffset;
    origin.procedure.fileEndOffset = procedure.fileEndOffset;
    origin.procedure.annotations
        .forEach((m) => m.fileOffset = procedure.fileOffset);

    origin.procedure.isAbstract = procedure.isAbstract;
    origin.procedure.isExternal = procedure.isExternal;
    origin.procedure.function = procedure.function;
    origin.procedure.function.parent = origin.procedure;
    return 1;
  }

  @override
  void becomeNative(Loader loader) {
    procedure.isExternal = true;
    super.becomeNative(loader);
  }

  @override
  void applyPatch(Declaration patch) {
    if (patch is KernelProcedureBuilder) {
      if (checkPatch(patch)) {
        patch.actualOrigin = this;
      }
    } else {
      reportPatchMismatch(patch);
    }
  }
}

// TODO(ahe): Move this to own file?
class KernelConstructorBuilder extends KernelFunctionBuilder {
  final Constructor constructor;

  final int charOpenParenOffset;

  bool hasMovedSuperInitializer = false;

  SuperInitializer superInitializer;

  RedirectingInitializer redirectingInitializer;

  @override
  KernelConstructorBuilder actualOrigin;

  KernelConstructorBuilder(
      List<MetadataBuilder> metadata,
      int modifiers,
      KernelTypeBuilder returnType,
      String name,
      List<TypeVariableBuilder> typeVariables,
      List<FormalParameterBuilder> formals,
      KernelLibraryBuilder compilationUnit,
      int startCharOffset,
      int charOffset,
      this.charOpenParenOffset,
      int charEndOffset,
      [String nativeMethodName])
      : constructor = new Constructor(null, fileUri: compilationUnit?.fileUri)
          ..startFileOffset = startCharOffset
          ..fileOffset = charOffset
          ..fileEndOffset = charEndOffset,
        super(metadata, modifiers, returnType, name, typeVariables, formals,
            compilationUnit, charOffset, nativeMethodName);

  @override
  KernelConstructorBuilder get origin => actualOrigin ?? this;

  bool get isInstanceMember => false;

  bool get isConstructor => true;

  AsyncMarker get asyncModifier => AsyncMarker.Sync;

  ProcedureKind get kind => null;

  bool get isRedirectingGenerativeConstructor {
    return isRedirectingGenerativeConstructorImplementation(constructor);
  }

  bool get isEligibleForTopLevelInference {
    if (library.legacyMode) return false;
    if (formals != null) {
      for (var formal in formals) {
        if (formal.type == null && formal.isInitializingFormal) return true;
      }
    }
    return false;
  }

  Constructor build(SourceLibraryBuilder library) {
    if (constructor.name == null) {
      constructor.function = buildFunction(library);
      constructor.function.parent = constructor;
      constructor.function.fileOffset = charOpenParenOffset;
      constructor.function.fileEndOffset = constructor.fileEndOffset;
      constructor.function.typeParameters = const <TypeParameter>[];
      constructor.isConst = isConst;
      constructor.isExternal = isExternal;
      constructor.name = new Name(name, library.target);
    }
    if (isEligibleForTopLevelInference) {
      for (KernelFormalParameterBuilder formal in formals) {
        if (formal.type == null && formal.isInitializingFormal) {
          formal.declaration.type = null;
        }
      }
      library.loader.typeInferenceEngine.toBeInferred[constructor] = library;
    }
    return constructor;
  }

  @override
  void buildOutlineExpressions(LibraryBuilder library) {
    ClassBuilder classBuilder = isClassMember ? parent : null;
    KernelMetadataBuilder.buildAnnotations(
        target,
        metadata,
        library,
        classBuilder,
        this,
        computeFormalParameterScope(classBuilder?.scope ?? library.scope));
  }

  FunctionNode buildFunction(LibraryBuilder library) {
    // According to the specification §9.3 the return type of a constructor
    // function is its enclosing class.
    FunctionNode functionNode = super.buildFunction(library);
    ClassBuilder enclosingClass = parent;
    List<DartType> typeParameterTypes = new List<DartType>();
    for (int i = 0; i < enclosingClass.target.typeParameters.length; i++) {
      TypeParameter typeParameter = enclosingClass.target.typeParameters[i];
      typeParameterTypes.add(new TypeParameterType(typeParameter));
    }
    functionNode.returnType =
        new InterfaceType(enclosingClass.target, typeParameterTypes);
    return functionNode;
  }

  Constructor get target => origin.constructor;

  void injectInvalidInitializer(
      Message message, int charOffset, ExpressionGeneratorHelper helper) {
    List<Initializer> initializers = constructor.initializers;
    Initializer lastInitializer = initializers.removeLast();
    assert(lastInitializer == superInitializer ||
        lastInitializer == redirectingInitializer);
    Initializer error = helper.buildInvalidInitializer(
        helper.desugarSyntheticExpression(
            helper.buildProblem(message, charOffset, noLength)),
        charOffset);
    initializers.add(error..parent = constructor);
    initializers.add(lastInitializer);
  }

  void addInitializer(
      Initializer initializer, ExpressionGeneratorHelper helper) {
    List<Initializer> initializers = constructor.initializers;
    if (initializer is SuperInitializer) {
      if (superInitializer != null || redirectingInitializer != null) {
        injectInvalidInitializer(messageMoreThanOneSuperOrThisInitializer,
            initializer.fileOffset, helper);
      } else {
        initializers.add(initializer..parent = constructor);
        superInitializer = initializer;
      }
    } else if (initializer is RedirectingInitializer) {
      if (superInitializer != null || redirectingInitializer != null) {
        injectInvalidInitializer(messageMoreThanOneSuperOrThisInitializer,
            initializer.fileOffset, helper);
      } else if (constructor.initializers.isNotEmpty) {
        Initializer first = constructor.initializers.first;
        Initializer error = helper.buildInvalidInitializer(
            helper.desugarSyntheticExpression(helper.buildProblem(
                messageThisInitializerNotAlone, first.fileOffset, noLength)),
            first.fileOffset);
        initializers.add(error..parent = constructor);
      } else {
        initializers.add(initializer..parent = constructor);
        redirectingInitializer = initializer;
      }
    } else if (redirectingInitializer != null) {
      injectInvalidInitializer(
          messageThisInitializerNotAlone, initializer.fileOffset, helper);
    } else if (superInitializer != null) {
      injectInvalidInitializer(
          messageSuperInitializerNotLast, superInitializer.fileOffset, helper);
    } else {
      initializers.add(initializer..parent = constructor);
    }
  }

  @override
  int finishPatch() {
    if (!isPatch) return 0;

    // TODO(ahe): restore file-offset once we track both origin and patch file
    // URIs. See https://github.com/dart-lang/sdk/issues/31579
    origin.constructor.fileUri = fileUri;
    origin.constructor.startFileOffset = constructor.startFileOffset;
    origin.constructor.fileOffset = constructor.fileOffset;
    origin.constructor.fileEndOffset = constructor.fileEndOffset;
    origin.constructor.annotations
        .forEach((m) => m.fileOffset = constructor.fileOffset);

    origin.constructor.isExternal = constructor.isExternal;
    origin.constructor.function = constructor.function;
    origin.constructor.function.parent = origin.constructor;
    origin.constructor.initializers = constructor.initializers;
    setParents(origin.constructor.initializers, origin.constructor);
    return 1;
  }

  @override
  void becomeNative(Loader loader) {
    constructor.isExternal = true;
    super.becomeNative(loader);
  }

  @override
  void applyPatch(Declaration patch) {
    if (patch is KernelConstructorBuilder) {
      if (checkPatch(patch)) {
        patch.actualOrigin = this;
      }
    } else {
      reportPatchMismatch(patch);
    }
  }
}

class KernelRedirectingFactoryBuilder extends KernelProcedureBuilder {
  final ConstructorReferenceBuilder redirectionTarget;
  List<DartType> typeArguments;

  KernelRedirectingFactoryBuilder(
      List<MetadataBuilder> metadata,
      int modifiers,
      KernelTypeBuilder returnType,
      String name,
      List<TypeVariableBuilder> typeVariables,
      List<FormalParameterBuilder> formals,
      KernelLibraryBuilder compilationUnit,
      int startCharOffset,
      int charOffset,
      int charOpenParenOffset,
      int charEndOffset,
      [String nativeMethodName,
      this.redirectionTarget])
      : super(
            metadata,
            modifiers,
            returnType,
            name,
            typeVariables,
            formals,
            ProcedureKind.Factory,
            compilationUnit,
            startCharOffset,
            charOffset,
            charOpenParenOffset,
            charEndOffset,
            nativeMethodName);

  @override
  Statement get body => actualBody;

  @override
  void setRedirectingFactoryBody(Member target, List<DartType> typeArguments) {
    if (actualBody != null) {
      unexpected("null", "${actualBody.runtimeType}", charOffset, fileUri);
    }

    // Ensure that constant factories only have constant targets/bodies.
    if (isConst && !target.isConst) {
      library.addProblem(messageConstFactoryRedirectionToNonConst, charOffset,
          noLength, fileUri);
    }

    actualBody = new RedirectingFactoryBody(target, typeArguments);
    function.body = actualBody;
    actualBody?.parent = function;
    if (isPatch) {
      if (function.typeParameters != null) {
        Map<TypeParameter, DartType> substitution = <TypeParameter, DartType>{};
        for (int i = 0; i < function.typeParameters.length; i++) {
          substitution[function.typeParameters[i]] =
              new TypeParameterType(actualOrigin.function.typeParameters[i]);
        }
        List<DartType> newTypeArguments =
            new List<DartType>(typeArguments.length);
        for (int i = 0; i < newTypeArguments.length; i++) {
          newTypeArguments[i] = substitute(typeArguments[i], substitution);
        }
        typeArguments = newTypeArguments;
      }
      actualOrigin.setRedirectingFactoryBody(target, typeArguments);
    }
  }

  @override
  Procedure build(SourceLibraryBuilder library) {
    Procedure result = super.build(library);
    result.isRedirectingFactoryConstructor = true;
    if (redirectionTarget.typeArguments != null) {
      typeArguments =
          new List<DartType>(redirectionTarget.typeArguments.length);
      for (int i = 0; i < typeArguments.length; i++) {
        typeArguments[i] = redirectionTarget.typeArguments[i].build(library);
      }
    }
    return result;
  }

  @override
  int finishPatch() {
    if (!isPatch) return 0;

    super.finishPatch();

    if (origin is KernelRedirectingFactoryBuilder) {
      KernelRedirectingFactoryBuilder redirectingOrigin = origin;
      redirectingOrigin.typeArguments = typeArguments;
    }

    return 1;
  }
}
