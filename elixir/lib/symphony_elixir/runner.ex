defmodule SymphonyElixir.Runner do
  @moduledoc """
  Contract every issue runner implements. The orchestrator/AgentRunner only ever
  call these three functions plus `module_for/1`. Implementations: Codex.AppServer,
  Claude.CliRunner.
  """

  @type session :: term()

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}
  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec module_for(:codex | :claude) :: module()
  def module_for(:codex), do: SymphonyElixir.Codex.AppServer
  def module_for(:claude), do: SymphonyElixir.Claude.CliRunner
  def module_for(other), do: raise(ArgumentError, "unknown runner: #{inspect(other)}")
end
