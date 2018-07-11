// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef RUNTIME_VM_COMPILER_FRONTEND_KERNEL_TO_IL_H_
#define RUNTIME_VM_COMPILER_FRONTEND_KERNEL_TO_IL_H_

#if !defined(DART_PRECOMPILED_RUNTIME)

#include <functional>
#include <initializer_list>

#include "vm/growable_array.h"
#include "vm/hash_map.h"

#include "vm/compiler/backend/flow_graph.h"
#include "vm/compiler/backend/il.h"
#include "vm/compiler/frontend/flow_graph_builder.h"
#include "vm/compiler/frontend/kernel_translation_helper.h"
#include "vm/compiler/frontend/scope_builder.h"

namespace dart {
namespace kernel {

class StreamingFlowGraphBuilder;
struct InferredTypeMetadata;

class KernelConstMapKeyEqualsTraits {
 public:
  static const char* Name() { return "KernelConstMapKeyEqualsTraits"; }
  static bool ReportStats() { return false; }

  static bool IsMatch(const Object& a, const Object& b) {
    const Smi& key1 = Smi::Cast(a);
    const Smi& key2 = Smi::Cast(b);
    return (key1.Value() == key2.Value());
  }
  static bool IsMatch(const intptr_t key1, const Object& b) {
    return KeyAsSmi(key1) == Smi::Cast(b).raw();
  }
  static uword Hash(const Object& obj) {
    const Smi& key = Smi::Cast(obj);
    return HashValue(key.Value());
  }
  static uword Hash(const intptr_t key) {
    return HashValue(Smi::Value(KeyAsSmi(key)));
  }
  static RawObject* NewKey(const intptr_t key) { return KeyAsSmi(key); }

 private:
  static uword HashValue(intptr_t pos) { return pos % (Smi::kMaxValue - 13); }

  static RawSmi* KeyAsSmi(const intptr_t key) {
    ASSERT(key >= 0);
    return Smi::New(key);
  }
};
typedef UnorderedHashMap<KernelConstMapKeyEqualsTraits> KernelConstantsMap;

class BreakableBlock;
class CatchBlock;
class FlowGraphBuilder;
class SwitchBlock;
class TryCatchBlock;
class TryFinallyBlock;

class Fragment {
 public:
  Instruction* entry;
  Instruction* current;

  Fragment() : entry(NULL), current(NULL) {}

  Fragment(std::initializer_list<Fragment> list) : entry(NULL), current(NULL) {
    for (Fragment i : list) {
      *this += i;
    }
  }

  explicit Fragment(Instruction* instruction)
      : entry(instruction), current(instruction) {}

  Fragment(Instruction* entry, Instruction* current)
      : entry(entry), current(current) {}

  bool is_open() { return entry == NULL || current != NULL; }
  bool is_closed() { return !is_open(); }

  void Prepend(Instruction* start);

  Fragment& operator+=(const Fragment& other);
  Fragment& operator<<=(Instruction* next);

  Fragment closed();
};

Fragment operator+(const Fragment& first, const Fragment& second);
Fragment operator<<(const Fragment& fragment, Instruction* next);

typedef ZoneGrowableArray<PushArgumentInstr*>* ArgumentArray;

struct YieldContinuation {
  Instruction* entry;
  intptr_t try_index;

  YieldContinuation(Instruction* entry, intptr_t try_index)
      : entry(entry), try_index(try_index) {}

  YieldContinuation()
      : entry(NULL), try_index(CatchClauseNode::kInvalidTryIndex) {}
};

class BaseFlowGraphBuilder {
 public:
  BaseFlowGraphBuilder(const ParsedFunction* parsed_function,
                       intptr_t last_used_block_id,
                       ZoneGrowableArray<intptr_t>* context_level_array = NULL)
      : parsed_function_(parsed_function),
        function_(parsed_function_->function()),
        thread_(Thread::Current()),
        zone_(thread_->zone()),
        context_level_array_(context_level_array),
        context_depth_(0),
        last_used_block_id_(last_used_block_id),
        try_catch_block_(NULL),
        next_used_try_index_(0),
        stack_(NULL),
        pending_argument_count_(0) {}

  Fragment LoadField(intptr_t offset, intptr_t class_id = kDynamicCid);
  Fragment LoadNativeField(const NativeFieldDesc* native_field);
  Fragment LoadIndexed(intptr_t index_scale);

  void SetTempIndex(Definition* definition);

  Fragment LoadLocal(LocalVariable* variable);
  Fragment StoreLocal(TokenPosition position, LocalVariable* variable);
  Fragment StoreLocalRaw(TokenPosition position, LocalVariable* variable);
  Fragment LoadContextAt(int depth);
  Fragment StoreInstanceField(
      TokenPosition position,
      intptr_t offset,
      StoreBarrierType emit_store_barrier = kEmitStoreBarrier);

  void Push(Definition* definition);
  Value* Pop();
  Fragment Drop();
  // Drop given number of temps from the stack but preserve top of the stack.
  Fragment DropTempsPreserveTop(intptr_t num_temps_to_drop);
  Fragment MakeTemp();

  // Create a pseudo-local variable for a location on the expression stack.
  // Note: SSA construction currently does not support inserting Phi functions
  // for expression stack locations - only real local variables are supported.
  // This means that you can't use MakeTemporary in a way that would require
  // a Phi in SSA form. For example example below will be miscompiled or
  // will crash debug VM with assertion when building SSA for optimizing
  // compiler:
  //
  //     t = MakeTemporary()
  //     Branch B1 or B2
  //     B1:
  //       StoreLocal(t, v0)
  //       goto B3
  //     B2:
  //       StoreLocal(t, v1)
  //       goto B3
  //     B3:
  //       LoadLocal(t)
  //
  LocalVariable* MakeTemporary();

  Fragment PushArgument();
  ArgumentArray GetArguments(int count);

  TargetEntryInstr* BuildTargetEntry();
  JoinEntryInstr* BuildJoinEntry();
  JoinEntryInstr* BuildJoinEntry(intptr_t try_index);

  Fragment StrictCompare(Token::Kind kind, bool number_check = false);
  Fragment Goto(JoinEntryInstr* destination);
  Fragment IntConstant(int64_t value);
  Fragment Constant(const Object& value);
  Fragment NullConstant();
  Fragment SmiRelationalOp(Token::Kind kind);
  Fragment SmiBinaryOp(Token::Kind op, bool is_truncating = false);
  Fragment LoadFpRelativeSlot(intptr_t offset);
  Fragment StoreFpRelativeSlot(intptr_t offset);
  Fragment BranchIfTrue(TargetEntryInstr** then_entry,
                        TargetEntryInstr** otherwise_entry,
                        bool negate = false);
  Fragment BranchIfNull(TargetEntryInstr** then_entry,
                        TargetEntryInstr** otherwise_entry,
                        bool negate = false);
  Fragment BranchIfEqual(TargetEntryInstr** then_entry,
                         TargetEntryInstr** otherwise_entry,
                         bool negate = false);
  Fragment BranchIfStrictEqual(TargetEntryInstr** then_entry,
                               TargetEntryInstr** otherwise_entry);
  Fragment ThrowException(TokenPosition position);
  Fragment TailCall(const Code& code);

  intptr_t GetNextDeoptId() {
    intptr_t deopt_id = thread_->GetNextDeoptId();
    if (context_level_array_ != NULL) {
      intptr_t level = context_depth_;
      context_level_array_->Add(deopt_id);
      context_level_array_->Add(level);
    }
    return deopt_id;
  }

  intptr_t AllocateTryIndex() { return next_used_try_index_++; }

  Fragment LoadArgDescriptor() {
    ASSERT(parsed_function_->has_arg_desc_var());
    return LoadLocal(parsed_function_->arg_desc_var());
  }

  Fragment TestTypeArgsLen(Fragment eq_branch,
                           Fragment neq_branch,
                           intptr_t num_type_args);
  Fragment TestDelayedTypeArgs(LocalVariable* closure,
                               Fragment present,
                               Fragment absent);
  Fragment TestAnyTypeArgs(Fragment present, Fragment absent);

  JoinEntryInstr* BuildThrowNoSuchMethod();

 protected:
  intptr_t AllocateBlockId() { return ++last_used_block_id_; }
  intptr_t CurrentTryIndex();

  const ParsedFunction* parsed_function_;
  const Function& function_;
  Thread* thread_;
  Zone* zone_;
  // Contains (deopt_id, context_level) pairs.
  ZoneGrowableArray<intptr_t>* context_level_array_;
  intptr_t context_depth_;
  intptr_t last_used_block_id_;

  // A chained list of try-catch blocks. Chaining and lookup is done by the
  // [TryCatchBlock] class.
  TryCatchBlock* try_catch_block_;
  intptr_t next_used_try_index_;

 private:
  Value* stack_;
  intptr_t pending_argument_count_;

  friend class TryCatchBlock;
  friend class StreamingFlowGraphBuilder;
  friend class FlowGraphBuilder;
  friend class PrologueBuilder;
};

class FlowGraphBuilder : public BaseFlowGraphBuilder {
 public:
  FlowGraphBuilder(ParsedFunction* parsed_function,
                   const ZoneGrowableArray<const ICData*>& ic_data_array,
                   ZoneGrowableArray<intptr_t>* context_level_array,
                   InlineExitCollector* exit_collector,
                   bool optimizing,
                   intptr_t osr_id,
                   intptr_t first_block_id = 1);
  virtual ~FlowGraphBuilder();

  FlowGraph* BuildGraph();

  // Returns true if the given function needs dynamic invocation forwarder:
  // that is if any of the arguments require checking on the dynamic
  // call-site: if function has no parameters or has only covariant parameters
  // as such function already checks all of its parameters.
  static bool NeedsDynamicInvocationForwarder(const Function& function);

 private:
  BlockEntryInstr* BuildPrologue(TargetEntryInstr* normal_entry,
                                 PrologueInfo* prologue_info);

  FlowGraph* BuildGraphOfMethodExtractor(const Function& method);
  FlowGraph* BuildGraphOfNoSuchMethodDispatcher(const Function& function);
  FlowGraph* BuildGraphOfInvokeFieldDispatcher(const Function& function);

  Fragment NativeFunctionBody(intptr_t first_positional_offset,
                              const Function& function);

  Fragment TranslateFinallyFinalizers(TryFinallyBlock* outer_finally,
                                      intptr_t target_context_depth);

  Fragment EnterScope(intptr_t kernel_offset,
                      intptr_t* num_context_variables = NULL);
  Fragment ExitScope(intptr_t kernel_offset);

  Fragment AdjustContextTo(int depth);

  Fragment PushContext(int size);
  Fragment PopContext();

  Fragment LoadInstantiatorTypeArguments();
  Fragment LoadFunctionTypeArguments();
  Fragment InstantiateType(const AbstractType& type);
  Fragment InstantiateTypeArguments(const TypeArguments& type_arguments);
  Fragment TranslateInstantiatedTypeArguments(
      const TypeArguments& type_arguments);

  Fragment AllocateContext(intptr_t size);
  Fragment AllocateObject(TokenPosition position,
                          const Class& klass,
                          intptr_t argument_count);
  Fragment AllocateObject(const Class& klass, const Function& closure_function);
  Fragment BooleanNegate();
  Fragment CatchBlockEntry(const Array& handler_types,
                           intptr_t handler_index,
                           bool needs_stacktrace,
                           bool is_synthesized);
  Fragment TryCatch(int try_handler_index);
  Fragment CheckStackOverflowInPrologue(TokenPosition position);
  Fragment CheckStackOverflow(TokenPosition position);
  Fragment CloneContext(intptr_t num_context_variables);
  Fragment CreateArray();
  Fragment InstanceCall(TokenPosition position,
                        const String& name,
                        Token::Kind kind,
                        intptr_t type_args_len,
                        intptr_t argument_count,
                        const Array& argument_names,
                        intptr_t checked_argument_count,
                        const Function& interface_target,
                        const InferredTypeMetadata* result_type = NULL);
  Fragment ClosureCall(intptr_t type_args_len,
                       intptr_t argument_count,
                       const Array& argument_names);
  Fragment RethrowException(TokenPosition position, int catch_try_index);
  Fragment LoadClassId();
  Fragment LoadField(intptr_t offset, intptr_t class_id = kDynamicCid);
  Fragment LoadField(const Field& field);
  Fragment LoadLocal(LocalVariable* variable);
  Fragment InitStaticField(const Field& field);
  Fragment LoadStaticField();
  Fragment NativeCall(const String* name, const Function* function);
  Fragment Return(TokenPosition position);
  Fragment CheckNull(TokenPosition position,
                     LocalVariable* receiver,
                     const String& function_name);
  void SetResultTypeForStaticCall(StaticCallInstr* call,
                                  const Function& target,
                                  intptr_t argument_count,
                                  const InferredTypeMetadata* result_type);
  Fragment StaticCall(TokenPosition position,
                      const Function& target,
                      intptr_t argument_count,
                      ICData::RebindRule rebind_rule);
  Fragment StaticCall(TokenPosition position,
                      const Function& target,
                      intptr_t argument_count,
                      const Array& argument_names,
                      ICData::RebindRule rebind_rule,
                      const InferredTypeMetadata* result_type = NULL,
                      intptr_t type_args_len = 0);
  Fragment StoreIndexed(intptr_t class_id);
  Fragment StoreInstanceFieldGuarded(const Field& field,
                                     bool is_initialization_store);
  Fragment StoreInstanceField(
      TokenPosition position,
      intptr_t offset,
      StoreBarrierType emit_store_barrier = kEmitStoreBarrier);
  Fragment StoreInstanceField(
      const Field& field,
      bool is_initialization_store,
      StoreBarrierType emit_store_barrier = kEmitStoreBarrier);
  Fragment StoreStaticField(TokenPosition position, const Field& field);
  Fragment StringInterpolate(TokenPosition position);
  Fragment StringInterpolateSingle(TokenPosition position);
  Fragment ThrowTypeError();
  Fragment ThrowNoSuchMethodError();
  Fragment BuildImplicitClosureCreation(const Function& target);
  Fragment GuardFieldLength(const Field& field, intptr_t deopt_id);
  Fragment GuardFieldClass(const Field& field, intptr_t deopt_id);

  Fragment EvaluateAssertion();
  Fragment CheckVariableTypeInCheckedMode(const AbstractType& dst_type,
                                          const String& name_symbol);
  Fragment CheckBoolean(TokenPosition position);
  Fragment CheckAssignable(
      const AbstractType& dst_type,
      const String& dst_name,
      AssertAssignableInstr::Kind kind = AssertAssignableInstr::kUnknown);

  Fragment AssertBool(TokenPosition position);
  Fragment AssertAssignable(
      TokenPosition position,
      const AbstractType& dst_type,
      const String& dst_name,
      AssertAssignableInstr::Kind kind = AssertAssignableInstr::kUnknown);
  Fragment AssertSubtype(TokenPosition position,
                         const AbstractType& sub_type,
                         const AbstractType& super_type,
                         const String& dst_name);

  bool NeedsDebugStepCheck(const Function& function, TokenPosition position);
  bool NeedsDebugStepCheck(Value* value, TokenPosition position);
  Fragment DebugStepCheck(TokenPosition position);

  LocalVariable* LookupVariable(intptr_t kernel_offset);

  bool IsInlining() { return exit_collector_ != NULL; }

  bool IsCompiledForOsr() { return osr_id_ != Thread::kNoDeoptId; }

  void InlineBailout(const char* reason);

  TranslationHelper translation_helper_;
  Thread* thread_;
  Zone* zone_;

  ParsedFunction* parsed_function_;
  const bool optimizing_;
  intptr_t osr_id_;
  const ZoneGrowableArray<const ICData*>& ic_data_array_;
  InlineExitCollector* exit_collector_;

  intptr_t next_function_id_;
  intptr_t AllocateFunctionId() { return next_function_id_++; }

  intptr_t loop_depth_;
  intptr_t try_depth_;
  intptr_t catch_depth_;
  intptr_t for_in_depth_;

  GraphEntryInstr* graph_entry_;

  ScopeBuildingResult* scopes_;

  GrowableArray<YieldContinuation> yield_continuations_;

  LocalVariable* CurrentException() {
    return scopes_->exception_variables[catch_depth_ - 1];
  }
  LocalVariable* CurrentStackTrace() {
    return scopes_->stack_trace_variables[catch_depth_ - 1];
  }
  LocalVariable* CurrentRawException() {
    return scopes_->raw_exception_variables[catch_depth_ - 1];
  }
  LocalVariable* CurrentRawStackTrace() {
    return scopes_->raw_stack_trace_variables[catch_depth_ - 1];
  }
  LocalVariable* CurrentCatchContext() {
    return scopes_->catch_context_variables[try_depth_];
  }

  // A chained list of breakable blocks. Chaining and lookup is done by the
  // [BreakableBlock] class.
  BreakableBlock* breakable_block_;

  // A chained list of switch blocks. Chaining and lookup is done by the
  // [SwitchBlock] class.
  SwitchBlock* switch_block_;

  // A chained list of try-finally blocks. Chaining and lookup is done by the
  // [TryFinallyBlock] class.
  TryFinallyBlock* try_finally_block_;

  // A chained list of catch blocks. Chaining and lookup is done by the
  // [CatchBlock] class.
  CatchBlock* catch_block_;

  ActiveClass active_class_;

  StreamingFlowGraphBuilder* streaming_flow_graph_builder_;

  friend class BreakableBlock;
  friend class CatchBlock;
  friend class StreamingFlowGraphBuilder;
  friend class SwitchBlock;
  friend class TryCatchBlock;
  friend class TryFinallyBlock;
};

class SwitchBlock {
 public:
  SwitchBlock(FlowGraphBuilder* builder, intptr_t case_count)
      : builder_(builder),
        outer_(builder->switch_block_),
        outer_finally_(builder->try_finally_block_),
        case_count_(case_count),
        context_depth_(builder->context_depth_),
        try_index_(builder->CurrentTryIndex()) {
    builder_->switch_block_ = this;
    if (outer_ != NULL) {
      depth_ = outer_->depth_ + outer_->case_count_;
    } else {
      depth_ = 0;
    }
  }
  ~SwitchBlock() { builder_->switch_block_ = outer_; }

  bool HadJumper(intptr_t case_num) {
    return destinations_.Lookup(case_num) != NULL;
  }

  // Get destination via absolute target number (i.e. the correct destination
  // is not not necessarily in this block.
  JoinEntryInstr* Destination(intptr_t target_index,
                              TryFinallyBlock** outer_finally = NULL,
                              intptr_t* context_depth = NULL) {
    // Find corresponding [SwitchStatement].
    SwitchBlock* block = this;
    while (block->depth_ > target_index) {
      block = block->outer_;
    }

    // Set the outer finally block.
    if (outer_finally != NULL) {
      *outer_finally = block->outer_finally_;
      *context_depth = block->context_depth_;
    }

    // Ensure there's [JoinEntryInstr] for that [SwitchCase].
    return block->EnsureDestination(target_index - block->depth_);
  }

  // Get destination via relative target number (i.e. relative to this block,
  // 0 is first case in this block etc).
  JoinEntryInstr* DestinationDirect(intptr_t case_num,
                                    TryFinallyBlock** outer_finally = NULL,
                                    intptr_t* context_depth = NULL) {
    // Set the outer finally block.
    if (outer_finally != NULL) {
      *outer_finally = outer_finally_;
      *context_depth = context_depth_;
    }

    // Ensure there's [JoinEntryInstr] for that [SwitchCase].
    return EnsureDestination(case_num);
  }

 private:
  JoinEntryInstr* EnsureDestination(intptr_t case_num) {
    JoinEntryInstr* cached_inst = destinations_.Lookup(case_num);
    if (cached_inst == NULL) {
      JoinEntryInstr* inst = builder_->BuildJoinEntry(try_index_);
      destinations_.Insert(case_num, inst);
      return inst;
    }
    return cached_inst;
  }

  FlowGraphBuilder* builder_;
  SwitchBlock* outer_;

  IntMap<JoinEntryInstr*> destinations_;

  TryFinallyBlock* outer_finally_;
  intptr_t case_count_;
  intptr_t depth_;
  intptr_t context_depth_;
  intptr_t try_index_;
};

class TryCatchBlock {
 public:
  explicit TryCatchBlock(BaseFlowGraphBuilder* builder,
                         intptr_t try_handler_index = -1)
      : builder_(builder),
        outer_(builder->try_catch_block_),
        try_index_(try_handler_index) {
    if (try_index_ == -1) try_index_ = builder->AllocateTryIndex();
    builder->try_catch_block_ = this;
  }
  ~TryCatchBlock() { builder_->try_catch_block_ = outer_; }

  intptr_t try_index() { return try_index_; }
  TryCatchBlock* outer() const { return outer_; }

 private:
  BaseFlowGraphBuilder* builder_;
  TryCatchBlock* outer_;
  intptr_t try_index_;
};

class TryFinallyBlock {
 public:
  TryFinallyBlock(FlowGraphBuilder* builder, intptr_t finalizer_kernel_offset)
      : builder_(builder),
        outer_(builder->try_finally_block_),
        finalizer_kernel_offset_(finalizer_kernel_offset),
        context_depth_(builder->context_depth_),
        // Finalizers are executed outside of the try block hence
        // try depth of finalizers are one less than current try
        // depth.
        try_depth_(builder->try_depth_ - 1),
        try_index_(builder_->CurrentTryIndex()) {
    builder_->try_finally_block_ = this;
  }
  ~TryFinallyBlock() { builder_->try_finally_block_ = outer_; }

  intptr_t finalizer_kernel_offset() const { return finalizer_kernel_offset_; }
  intptr_t context_depth() const { return context_depth_; }
  intptr_t try_depth() const { return try_depth_; }
  intptr_t try_index() const { return try_index_; }
  TryFinallyBlock* outer() const { return outer_; }

 private:
  FlowGraphBuilder* const builder_;
  TryFinallyBlock* const outer_;
  intptr_t finalizer_kernel_offset_;
  const intptr_t context_depth_;
  const intptr_t try_depth_;
  const intptr_t try_index_;
};

class BreakableBlock {
 public:
  explicit BreakableBlock(FlowGraphBuilder* builder)
      : builder_(builder),
        outer_(builder->breakable_block_),
        destination_(NULL),
        outer_finally_(builder->try_finally_block_),
        context_depth_(builder->context_depth_),
        try_index_(builder->CurrentTryIndex()) {
    if (builder_->breakable_block_ == NULL) {
      index_ = 0;
    } else {
      index_ = builder_->breakable_block_->index_ + 1;
    }
    builder_->breakable_block_ = this;
  }
  ~BreakableBlock() { builder_->breakable_block_ = outer_; }

  bool HadJumper() { return destination_ != NULL; }

  JoinEntryInstr* destination() { return destination_; }

  JoinEntryInstr* BreakDestination(intptr_t label_index,
                                   TryFinallyBlock** outer_finally,
                                   intptr_t* context_depth) {
    BreakableBlock* block = builder_->breakable_block_;
    while (block->index_ != label_index) {
      block = block->outer_;
    }
    ASSERT(block != NULL);
    *outer_finally = block->outer_finally_;
    *context_depth = block->context_depth_;
    return block->EnsureDestination();
  }

 private:
  JoinEntryInstr* EnsureDestination() {
    if (destination_ == NULL) {
      destination_ = builder_->BuildJoinEntry(try_index_);
    }
    return destination_;
  }

  FlowGraphBuilder* builder_;
  intptr_t index_;
  BreakableBlock* outer_;
  JoinEntryInstr* destination_;
  TryFinallyBlock* outer_finally_;
  intptr_t context_depth_;
  intptr_t try_index_;
};

class CatchBlock {
 public:
  CatchBlock(FlowGraphBuilder* builder,
             LocalVariable* exception_var,
             LocalVariable* stack_trace_var,
             intptr_t catch_try_index)
      : builder_(builder),
        outer_(builder->catch_block_),
        exception_var_(exception_var),
        stack_trace_var_(stack_trace_var),
        catch_try_index_(catch_try_index) {
    builder_->catch_block_ = this;
  }
  ~CatchBlock() { builder_->catch_block_ = outer_; }

  LocalVariable* exception_var() { return exception_var_; }
  LocalVariable* stack_trace_var() { return stack_trace_var_; }
  intptr_t catch_try_index() { return catch_try_index_; }

 private:
  FlowGraphBuilder* builder_;
  CatchBlock* outer_;
  LocalVariable* exception_var_;
  LocalVariable* stack_trace_var_;
  intptr_t catch_try_index_;
};

RawObject* EvaluateMetadata(const Field& metadata_field,
                            bool is_annotations_offset);
RawObject* BuildParameterDescriptor(const Function& function);
void CollectTokenPositionsFor(const Script& script);

}  // namespace kernel
}  // namespace dart

#else  // !defined(DART_PRECOMPILED_RUNTIME)

#include "vm/kernel.h"
#include "vm/object.h"

namespace dart {
namespace kernel {

RawObject* EvaluateMetadata(const Field& metadata_field);
RawObject* BuildParameterDescriptor(const Function& function);

}  // namespace kernel
}  // namespace dart

#endif  // !defined(DART_PRECOMPILED_RUNTIME)
#endif  // RUNTIME_VM_COMPILER_FRONTEND_KERNEL_TO_IL_H_