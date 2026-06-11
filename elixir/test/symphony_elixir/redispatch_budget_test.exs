defmodule SymphonyElixir.RedispatchBudgetTest do
  @moduledoc """
  ② Merging 进度预算兜底：防止 issue 在某 active state（如 Merging）被无限重新
  派发空转烧 token（FAK-78 教训 —— runner 每个 turn 都「成功」退出，failure_budget
  拦不到）。
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.State

  describe "redispatch 预算纯函数判定" do
    test "budget=0 视为不限制，任何计数都不耗尽" do
      refute Orchestrator.redispatch_budget_exhausted_for_test?(0, 0)
      refute Orchestrator.redispatch_budget_exhausted_for_test?(99, 0)
    end

    test "count < budget 未耗尽；count >= budget 耗尽" do
      refute Orchestrator.redispatch_budget_exhausted_for_test?(4, 5)
      assert Orchestrator.redispatch_budget_exhausted_for_test?(5, 5)
      assert Orchestrator.redispatch_budget_exhausted_for_test?(6, 5)
    end
  end

  describe "reconcile_redispatch_counts/2 清理离开受管控 state 的计数" do
    test "保留仍在受预算管控 state 的 issue 计数，清掉已离开的" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_redispatch_attempts_by_state: %{"Merging" => 5},
        tracker_active_states: ["Todo", "In Progress", "Merging"]
      )

      state = %State{redispatch_counts: %{"a" => 3, "b" => 2, "c" => 1}}

      issues = [
        %Issue{id: "a", identifier: "X-1", state: "Merging"},
        %Issue{id: "b", identifier: "X-2", state: "Done"},
        %Issue{id: "c", identifier: "X-3", state: "In Progress"}
      ]

      result = Orchestrator.reconcile_redispatch_counts_for_test(state, issues)

      # 只有 Merging（受预算管控）的 "a" 保留；Done 终态、In Progress 无预算的都清掉
      assert result.redispatch_counts == %{"a" => 3}
    end

    test "issue 已不在候选列表（不可见）也清掉计数" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_redispatch_attempts_by_state: %{"Merging" => 5},
        tracker_active_states: ["Todo", "In Progress", "Merging"]
      )

      state = %State{redispatch_counts: %{"gone" => 4}}
      result = Orchestrator.reconcile_redispatch_counts_for_test(state, [])

      assert result.redispatch_counts == %{}
    end
  end

  describe "Config.max_redispatch_attempts_for_state/1" do
    test "已配置的 state 返回预算（大小写不敏感），未配置返回 0" do
      write_workflow_file!(Workflow.workflow_file_path(),
        max_redispatch_attempts_by_state: %{"Merging" => 5}
      )

      assert Config.max_redispatch_attempts_for_state("Merging") == 5
      assert Config.max_redispatch_attempts_for_state("merging") == 5
      assert Config.max_redispatch_attempts_for_state("In Progress") == 0
      assert Config.max_redispatch_attempts_for_state("Todo") == 0
    end

    test "默认空配置时任何 state 返回 0（向后兼容，不影响其他 project）" do
      write_workflow_file!(Workflow.workflow_file_path())

      assert Config.max_redispatch_attempts_for_state("Merging") == 0
      assert Config.max_redispatch_attempts_for_state("In Progress") == 0
    end
  end
end
