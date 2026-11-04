defmodule Polis.AccessPinTest do
  @moduledoc """
  The access PIN: made at the first start and kept, the rules for a PIN, no way
  to remove it, the box's `pin-request` file, the file itself, and the
  lockout against guessing.
  """

  use Polis.StationCase, async: false

  alias Polis.AccessPin
  alias Polis.AccessPin.{Boot, Throttle}

  defp restart!, do: Boot.start_link([])
  defp on_unix?, do: match?({:unix, _}, :os.type())

  describe "generation" do
    test "the first start makes six digits and keeps them across a restart" do
      File.rm!(AccessPin.path())
      assert :ignore = restart!()
      pin = AccessPin.current()
      assert pin =~ ~r/\A\d{6}\z/
      assert File.read!(AccessPin.path()) == pin <> "\n"

      assert :ignore = restart!()
      assert AccessPin.current() == pin
    end

    test "the file is 0600" do
      if on_unix?() do
        assert File.stat!(AccessPin.path()).mode |> Bitwise.band(0o777) == 0o600
      end
    end

    test "generated PINs are six digits and not all the same" do
      pins = for _ <- 1..50, do: AccessPin.generate()
      assert Enum.all?(pins, &(&1 =~ ~r/\A\d{6}\z/))
      assert length(Enum.uniq(pins)) > 40
    end
  end

  describe "the rules" do
    test "length: 6 to 64" do
      assert {:error, :too_short} = AccessPin.validate("12345")
      assert :ok = AccessPin.validate("123456")
      assert :ok = AccessPin.validate(String.duplicate("a", 64))
      assert {:error, :too_long} = AccessPin.validate(String.duplicate("a", 65))
      assert {:error, :too_short} = AccessPin.validate("")
    end

    test "length counts characters, not bytes" do
      assert :ok = AccessPin.validate("ééééée")
      assert {:error, :too_short} = AccessPin.validate("ééééé")
    end

    test "no space at either end, spaces inside are fine" do
      assert {:error, :edge_space} = AccessPin.validate(" 123456")
      assert {:error, :edge_space} = AccessPin.validate("123456 ")
      assert :ok = AccessPin.validate("12 34 56")
    end

    test "no control characters, no invalid UTF-8" do
      assert {:error, :control} = AccessPin.validate("12345\u0007")
      assert {:error, :control} = AccessPin.validate("123\n456")
      assert {:error, :control} = AccessPin.validate("1234\u008556")
      assert {:error, :control} = AccessPin.validate("1234\u007F56")
      assert {:error, :invalid} = AccessPin.validate(<<"123456", 0xFF>>)
      assert {:error, :invalid} = AccessPin.validate(nil)
    end

    test "a refusal leaves the PIN as it was" do
      before = AccessPin.current()
      assert {:error, :too_short} = AccessPin.change("1")
      assert AccessPin.current() == before
      assert File.read!(AccessPin.path()) == before <> "\n"
    end

    test "there is no way to remove it" do
      before = AccessPin.current()
      assert {:error, _} = AccessPin.change("")
      assert {:error, _} = AccessPin.change(nil)
      refute function_exported?(AccessPin, :remove, 0)
      assert AccessPin.current() == before
    end
  end

  describe "changing" do
    test "writes access-pin and voids the stamp" do
      old = AccessPin.stamp()
      assert AccessPin.granted?(old)
      assert :ok = AccessPin.change("new pin 42")
      assert File.read!(AccessPin.path()) == "new pin 42\n"
      assert AccessPin.correct?("new pin 42")
      refute AccessPin.correct?("123456")
      refute AccessPin.granted?(old)
      assert AccessPin.granted?(AccessPin.stamp())
    end

    test "the file is 0600 after a change" do
      if on_unix?() do
        assert :ok = AccessPin.change("another one")
        assert File.stat!(AccessPin.path()).mode |> Bitwise.band(0o777) == 0o600
      end
    end

    test "renew makes a different six digits" do
      before = AccessPin.current()
      pin = AccessPin.renew()
      assert pin =~ ~r/\A\d{6}\z/
      assert AccessPin.current() == pin
      assert File.read!(AccessPin.path()) == pin <> "\n"
      assert is_binary(before)
    end

    test "a symlink in the PIN's place is not followed" do
      if on_unix?() do
        target = Path.join(Application.fetch_env!(:polis, :data_dir), "elsewhere")
        File.write!(target, "untouched")
        File.rm!(AccessPin.path())
        File.ln_s!(target, AccessPin.path())

        assert :ok = AccessPin.change("654321")
        assert File.read!(target) == "untouched"
        assert {:ok, %File.Stat{type: :regular}} = File.lstat(AccessPin.path())
        assert File.read!(AccessPin.path()) == "654321\n"
      end
    end
  end

  describe "the box's pin-request" do
    defp request(text), do: File.write!(AccessPin.request_path(), text)

    test "set applies a valid PIN and the file is gone" do
      request("set\nhall-pin-77\n")
      assert :set = AccessPin.consume_request()
      assert AccessPin.current() == "hall-pin-77"
      assert File.read!(AccessPin.path()) == "hall-pin-77\n"
      refute File.exists?(AccessPin.request_path())
    end

    test "set with an invalid PIN is refused, the PIN stays, the file is gone" do
      before = AccessPin.current()
      request("set\nshort\n")
      assert {:refused, :too_short} = AccessPin.consume_request()
      assert AccessPin.current() == before
      refute File.exists?(AccessPin.request_path())
    end

    test "new makes a fresh random PIN" do
      request("new\n")
      assert :new = AccessPin.consume_request()
      assert AccessPin.current() =~ ~r/\A\d{6}\z/
      assert File.read!(AccessPin.path()) == AccessPin.current() <> "\n"
      refute File.exists?(AccessPin.request_path())
    end

    test "remove, and any other thing, is refused" do
      before = AccessPin.current()

      for text <- ["remove\n", "", "set\n", "set\n123456", "new\nextra\n", "gibberish"] do
        request(text)
        assert {:refused, _} = AccessPin.consume_request(), inspect(text)
        assert AccessPin.current() == before
        refute File.exists?(AccessPin.request_path())
      end
    end

    test "no request is no news" do
      assert :none = AccessPin.consume_request()
    end

    test "a request that is a symlink is deleted, not read" do
      if on_unix?() do
        before = AccessPin.current()
        target = Path.join(Application.fetch_env!(:polis, :data_dir), "elsewhere")
        File.write!(target, "set\nsneaky-pin-1\n")
        File.ln_s!(target, AccessPin.request_path())

        assert {:refused, :not_a_file} = AccessPin.consume_request()
        assert AccessPin.current() == before
        assert {:error, :enoent} = File.lstat(AccessPin.request_path())
        assert File.exists?(target)
      end
    end

    test "a request is consumed at start, before a PIN is made" do
      File.rm!(AccessPin.path())
      request("set\nfrom-the-box\n")
      assert :ignore = restart!()
      assert AccessPin.current() == "from-the-box"
      refute File.exists?(AccessPin.request_path())
    end
  end

  describe "the lockout" do
    @ip {10, 0, 0, 7}

    setup do
      Throttle.reset()
      :ok
    end

    test "five free failures, then 5, 10, 20 seconds" do
      for _ <- 1..4, do: assert(:ok = Throttle.claim(@ip, 1_000))
      # The fifth is counted and compared, and starts the wait.
      assert :ok = Throttle.claim(@ip, 1_000)
      assert {:wait, 5} = Throttle.claim(@ip, 1_000)
      assert {:wait, 2} = Throttle.claim(@ip, 1_003)
      assert :ok = Throttle.claim(@ip, 1_005)
      assert {:wait, 10} = Throttle.claim(@ip, 1_005)
      assert :ok = Throttle.claim(@ip, 1_015)
      assert {:wait, 20} = Throttle.claim(@ip, 1_015)
    end

    test "the wait is capped at a quarter of an hour" do
      for n <- 0..30, do: Throttle.claim(@ip, n * 1_000)
      assert {:wait, 900} = Throttle.claim(@ip, 30_000)
    end

    test "other addresses are not held up by one" do
      for _ <- 1..5, do: Throttle.claim(@ip, 1_000)
      assert {:wait, _} = Throttle.claim(@ip, 1_001)
      assert :ok = Throttle.claim({10, 0, 0, 8}, 1_001)
    end

    test "while waiting, the right PIN is refused too" do
      for _ <- 1..5, do: Throttle.claim(@ip, 1_000)
      # The controller claims first, so the right PIN never gets compared.
      assert {:wait, _} = Throttle.claim(@ip, 1_001)
    end

    test "a right PIN clears the address" do
      for _ <- 1..4, do: Throttle.claim(@ip, 1_000)
      Throttle.succeeded(@ip)
      for _ <- 1..4, do: assert(:ok = Throttle.claim(@ip, 1_001))
      assert Throttle.peek(@ip, 1_001) == 0
    end

    test "the box takes 40 failures a minute, from any address, then everybody waits" do
      for n <- 1..40, do: assert(:ok = Throttle.claim({10, 1, 0, n}, 2_000 + div(n, 10)))
      assert {:wait, wait} = Throttle.claim({10, 2, 0, 1}, 2_005)
      assert wait == 55
      # A minute after the oldest, the door opens.
      assert :ok = Throttle.claim({10, 2, 0, 1}, 2_061)
    end

    test "an address quiet for an hour is forgotten" do
      for _ <- 1..5, do: Throttle.claim(@ip, 1_000)
      assert {:wait, _} = Throttle.claim(@ip, 1_001)
      assert :ok = Throttle.claim(@ip, 1_000 + 3_700)
    end

    test "peek counts nothing" do
      for _ <- 1..10, do: assert(Throttle.peek(@ip, 1_000) == 0)
      for _ <- 1..4, do: assert(:ok = Throttle.claim(@ip, 1_000))
    end
  end
end
