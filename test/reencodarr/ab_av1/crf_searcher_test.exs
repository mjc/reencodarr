defmodule Reencodarr.AbAv1.CrfSearcherTest do
  use Reencodarr.UnitCase, async: true

  alias Reencodarr.AbAv1.CrfSearcher

  describe "not running public API" do
    test "control calls return not_running or false" do
      refute CrfSearcher.running?()
      assert {:error, :not_running} = CrfSearcher.subscribe(self())
      assert {:error, :not_running} = CrfSearcher.get_metadata()
      assert {:error, :not_running} = CrfSearcher.get_os_pid()
      assert {:error, :not_running} = CrfSearcher.suspend()
      assert {:error, :not_running} = CrfSearcher.resume()
      assert {:error, :not_running} = CrfSearcher.fail()
      refute CrfSearcher.suspended?()
      assert :ok = CrfSearcher.kill()
    end
  end
end
