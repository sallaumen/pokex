defmodule Pokex.Bots.Capture.ScreenCaptureKitTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Capture.ScreenCaptureKit

  # TCC identifies the ad-hoc helper by its code hash, so a rebuild voids the user's Screen
  # Recording grant. Freshness must therefore follow the source CONTENT — never mtime, which
  # git churns on every checkout even for byte-identical files.
  describe "fresh?/2" do
    @tag :tmp_dir
    test "fresh when the stored source hash matches the current source", %{tmp_dir: tmp} do
      source = Path.join(tmp, "helper.swift")
      executable = Path.join(tmp, "helper")
      File.write!(source, "print(1)")
      File.write!(executable, "binary")

      sha = Base.encode16(:crypto.hash(:sha256, "print(1)"), case: :lower)
      File.write!(executable <> ".source_sha256", sha)

      assert ScreenCaptureKit.fresh?(source, executable)

      # an mtime-only touch (what git does on checkout/pull) must NOT trigger a rebuild
      File.touch!(source, System.os_time(:second) + 3600)
      assert ScreenCaptureKit.fresh?(source, executable)
    end

    @tag :tmp_dir
    test "stale when the source content changed or the hash record is missing", %{tmp_dir: tmp} do
      source = Path.join(tmp, "helper.swift")
      executable = Path.join(tmp, "helper")
      File.write!(source, "print(1)")
      File.write!(executable, "binary")

      # no recorded hash (pre-upgrade binary) → rebuild once to establish the record
      refute ScreenCaptureKit.fresh?(source, executable)

      sha = Base.encode16(:crypto.hash(:sha256, "print(2)"), case: :lower)
      File.write!(executable <> ".source_sha256", sha)
      refute ScreenCaptureKit.fresh?(source, executable)

      # and a missing executable is always stale, whatever the hash says
      File.rm!(executable)
      File.write!(executable <> ".source_sha256", sha)
      refute ScreenCaptureKit.fresh?(source, executable)
    end
  end
end
