defmodule Bandsaw.BackendTest do
  use ExUnit.Case
  doctest Bandsaw.Backend

  test "greets the world" do
    assert Bandsaw.Backend.hello() == :world
  end
end
