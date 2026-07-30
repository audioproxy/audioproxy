defmodule RedpathProbeTest do
  use ExUnit.Case, async: true

  test "deliberately failing test to prove CI goes red" do
    assert 1 == 2
  end
end
