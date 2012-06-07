// Copyright (c) 2011 Cloudera, Inc. All rights reserved.

#ifndef IMPALA_EXEC_EXEC_NODE_H
#define IMPALA_EXEC_EXEC_NODE_H

#include <vector>
#include <sstream>

#include "common/status.h"
#include "runtime/descriptors.h"  // for RowDescriptor
#include "util/runtime-profile.h"

namespace impala {

class Expr;
class ObjectPool;
class Counters;
class RowBatch;
struct RuntimeState;
class TPlan;
class TPlanNode;
class TupleRow;
class DataSink;

// Superclass of all executor nodes.
class ExecNode {
 public:
  // Init conjuncts.
  ExecNode(ObjectPool* pool, const TPlanNode& tnode, const DescriptorTbl& descs);

  // Sets up internal structures, etc., without doing any actual work.
  // Must be called prior to Open(). Will only be called once in this
  // node's lifetime.
  // If overridden in subclass, must first call superclass's Prepare().
  virtual Status Prepare(RuntimeState* state);

  // Performs any preparatory work prior to calling GetNext().
  // Can be called repeatedly (after calls to Close()).
  virtual Status Open(RuntimeState* state) = 0;

  // Retrieves rows and returns them via row_batch. Sets eos to true
  // if subsequent calls will not retrieve any more rows.
  // Data referenced by any tuples returned in row_batch must not be overwritten
  // by the callee until Close() is called. The memory holding that data
  // can be returned via row_batch's tuple_data_pool (in which case it may be deleted
  // by the caller) or held on to by the callee. The row_batch, including its
  // tuple_data_pool, will be destroyed by the caller at some point prior to the final
  // Close() call.
  // In other words, if the memory holding the tuple data will be referenced
  // by the callee in subsequent GetNext() calls, it must *not* be attached to the
  // row_batch's tuple_data_pool.
  virtual Status GetNext(RuntimeState* state, RowBatch* row_batch, bool* eos) = 0;

  // Releases all resources that were allocated in Open()/GetNext().
  // Must call Open() again prior to subsequent calls to GetNext().
  // Close() should be called once for every call to Open()
  // Default implementation updates runtime profile counters.
  virtual Status Close(RuntimeState* state);

  // Creates exec node tree from list of nodes contained in plan via depth-first
  // traversal. All nodes are placed in pool.
  // Returns error if 'plan' is corrupted, otherwise success.
  static Status CreateTree(ObjectPool* pool, const TPlan& plan,
                           const DescriptorTbl& descs, ExecNode** root);

  // Collect all scan nodes that are part of this subtree, and return in 'scan_nodes'.
  void CollectScanNodes(std::vector<ExecNode*>* scan_nodes);

  // Evaluate exprs over row.  Returns true if all exprs return true.
  // TODO: This doesn't use the vector<Expr*> signature because I haven't figured
  // out how to deal with declaring a templated std:vector type in IR
  static bool EvalConjuncts(Expr* const* exprs, int num_exprs, TupleRow* row);

  // Codegen function to evaluate the conjuncts.  Returns NULL if codegen was
  // not supported for the conjunct exprs.
  // Codegen'd signature is bool EvalConjuncts(Expr** exprs, int num_exprs, TupleRow*);
  // The first two arguments are ignored (the Expr's are baked into the codegen)
  // but it is included so the signature can match EvalConjuncts.
  llvm::Function* CodegenEvalConjuncts(LlvmCodeGen* codegen, 
      const std::vector<Expr*>& conjuncts);

  // Returns a string representation in DFS order of the plan rooted at this.
  std::string DebugString() const;

  // Recursive helper method for generating a string for DebugString().
  // Implementations should call DebugString(int, std::stringstream) on their children.
  // Input parameters:
  //   indentation_level: Current level in plan tree.
  // Output parameters:
  //   out: Stream to accumulate debug string.
  virtual void DebugString(int indentation_level, std::stringstream* out) const;

  const std::vector<Expr*>& conjuncts() const { return conjuncts_; }

  int id() const { return id_; }
  const RowDescriptor& row_desc() const { return row_descriptor_; }
  int rows_returned() const { return num_rows_returned_; }
  int limit() const { return limit_; }
  bool ReachedLimit() { return limit_ != -1 && num_rows_returned_ == limit_; }

  RuntimeProfile* runtime_profile() { return runtime_profile_.get(); }
  RuntimeProfile::Counter* memory_used_counter() const { return memory_used_counter_; }

 protected:
  int id_;  // unique w/in single plan tree
  ObjectPool* pool_;
  std::vector<Expr*> conjuncts_;
  std::vector<ExecNode*> children_;
  RowDescriptor row_descriptor_;

  int64_t limit_;  // -1: no limit
  int64_t num_rows_returned_;

  boost::scoped_ptr<RuntimeProfile> runtime_profile_;
  RuntimeProfile::Counter* rows_returned_counter_;
  // Account for peak memory used by this node
  RuntimeProfile::Counter* memory_used_counter_;

  ExecNode* child(int i) { return children_[i]; }

  // Create a single exec node derived from thrift node; place exec node in 'pool'.
  static Status CreateNode(ObjectPool* pool, const TPlanNode& tnode,
                           const DescriptorTbl& descs, ExecNode** node);

  static Status CreateTreeHelper(ObjectPool* pool, const std::vector<TPlanNode>& tnodes,
      const DescriptorTbl& descs, ExecNode* parent, int* node_idx, ExecNode** root);

  Status PrepareConjuncts(RuntimeState* state);

  virtual bool IsScanNode() const { return false; }

  void InitRuntimeProfile(const std::string& name);

  friend class DataSink;
};

}
#endif

