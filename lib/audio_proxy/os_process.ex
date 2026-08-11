defmodule AudioProxy.OsProcess do
  @moduledoc """
  OS-process utilities used in both production code and the test suite.

  The BEAM's `Port` gives us stdout and an exit status, but it does not tell us
  whether the subprocess is still alive between those events. For that we ask
  the kernel directly with `kill -0`, which tests existence and permission
  without delivering a signal.
  """

  require Logger

  @doc """
  Whether the OS process `os_pid` still exists.

  Returns `true` when `kill -0` succeeds. Returns `true` as well when the
  process exists but cannot be signalled (EPERM), or when `kill` itself is
  unavailable: a process we cannot prove gone must be treated as alive.

  Only a response that clearly means "no such process" is treated as dead,
  because the alternative — assuming a live process is gone — would let a
  sweep delete another instance's files.
  """
  @spec alive?(integer()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid) do
    case signal(os_pid, "0") do
      {_output, 0} -> true
      :unavailable -> true
      {output, _nonzero} -> not no_such_process?(output)
    end
  end

  defp no_such_process?(output) do
    output =~ ~r/No such process|No such pid/i
  end

  @doc """
  Send signal `signal` to OS process `os_pid`.

  Returns `{output, status}` on success, or `:unavailable` when the `kill`
  executable cannot be found or cannot be run. The executable is resolved per
  call rather than at compile time, because the build image and the runtime
  image are not the same filesystem.
  """
  @spec signal(integer(), String.t()) :: {String.t(), non_neg_integer()} | :unavailable
  def signal(os_pid, signal) when is_integer(os_pid) and is_binary(signal) do
    case System.find_executable("kill") do
      nil ->
        Logger.error("no `kill` on PATH; cannot signal OS processes")
        :unavailable

      kill ->
        System.cmd(kill, ["-#{signal}", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end
  rescue
    error ->
      Logger.error("failed to signal OS process #{os_pid}: #{Exception.message(error)}")
      :unavailable
  end
end
