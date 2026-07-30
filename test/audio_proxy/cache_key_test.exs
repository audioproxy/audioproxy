defmodule AudioProxy.CacheKeyTest do
  use ExUnit.Case, async: true

  alias AudioProxy.CacheKey
  alias AudioProxy.OptionError
  alias AudioProxy.Options

  doctest AudioProxy.CacheKey

  @source "s3://masters/2026/piece-final.wav"

  describe "derive/2" do
    test "is a lowercase hex SHA-256" do
      assert {:ok, key} = CacheKey.derive("f:opus", @source)
      assert String.length(key) == 64
      assert key =~ ~r/^[0-9a-f]{64}$/
    end

    test "is order-insensitive, because it hashes the normalized form" do
      assert CacheKey.derive("f:opus/br:96", @source) ==
               CacheKey.derive("br:96/f:opus", @source)
    end

    test "materialized defaults collapse onto the same key" do
      assert CacheKey.derive("", @source) == CacheKey.derive("f:mp3", @source)
      assert CacheKey.derive("f:peaks", @source) == CacheKey.derive("f:peaks/pts:800", @source)
    end

    test "equivalent number spellings collapse onto the same key" do
      assert CacheKey.derive("t:30", @source) == CacheKey.derive("t:30.0", @source)
      assert CacheKey.derive("gain:-3.5", @source) == CacheKey.derive("gain:-3.500", @source)
    end

    test "the cache buster participates" do
      assert {:ok, plain} = CacheKey.derive("f:opus", @source)
      assert {:ok, busted} = CacheKey.derive("f:opus/cb:v2", @source)
      assert {:ok, busted_again} = CacheKey.derive("f:opus/cb:v3", @source)

      assert plain != busted
      assert busted != busted_again
    end

    test "any differing option yields a different key" do
      keys =
        for options <- ["f:opus", "f:mp3", "f:opus/br:96", "f:opus/br:128", "f:opus/ch:1"] do
          {:ok, key} = CacheKey.derive(options, @source)
          key
        end

      assert length(Enum.uniq(keys)) == length(keys)
    end

    test "the source participates" do
      assert CacheKey.derive("f:opus", @source) !=
               CacheKey.derive("f:opus", "s3://masters/other.wav")
    end

    test "the separator keeps options and source from bleeding into each other" do
      # Without a separator, these two would hash identical bytes.
      assert CacheKey.derive("cb:ab", "s3://x") != CacheKey.derive("cb:a", "bs3://x")
    end

    test "accepts an already-parsed struct" do
      assert {:ok, opts} = Options.parse("f:opus/br:96")
      assert CacheKey.derive(opts, @source) == CacheKey.derive("f:opus/br:96", @source)
    end

    test "invalid options surface here rather than producing a key" do
      assert {:error, %OptionError{reason: :mutually_exclusive}} =
               CacheKey.derive("br:128/q:5", @source)
    end
  end

  describe "derive!/2" do
    test "returns the key" do
      assert {:ok, key} = CacheKey.derive("f:opus", @source)
      assert CacheKey.derive!("f:opus", @source) == key
    end

    test "raises on invalid options" do
      assert_raise ArgumentError, ~r/conflicts with/, fn ->
        CacheKey.derive!("br:128/q:5", @source)
      end
    end
  end
end
