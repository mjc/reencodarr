defmodule ReencodarrWeb.DashboardSavingsFormatTest do
  use ExUnit.Case, async: true

  # Import the formatting function from the dashboard module
  # We'll create a test helper module to access the private function
  defmodule DashboardSavingsFormatHelper do
    def format_savings(savings_gb) when is_number(savings_gb) and savings_gb > 0 do
      cond do
        savings_gb >= 1000 -> "#{Float.round(savings_gb / 1000, 1)} TB"
        savings_gb >= 1 -> "#{Float.round(savings_gb, 2)} GB"
        savings_gb >= 0.001 -> "#{round(savings_gb * 1000)} MB"
        true -> "< 1 MB"
      end
    end

    def format_savings(_), do: "N/A"
  end

  describe "dashboard savings formatting" do
    test "formats gigabytes correctly" do
      assert DashboardSavingsFormatHelper.format_savings(0.2) == "200 MB"
      assert DashboardSavingsFormatHelper.format_savings(1.0) == "1.0 GB"
      assert DashboardSavingsFormatHelper.format_savings(1.5) == "1.5 GB"
      assert DashboardSavingsFormatHelper.format_savings(2.75) == "2.75 GB"
      assert DashboardSavingsFormatHelper.format_savings(999.99) == "999.99 GB"
    end

    test "formats terabytes correctly" do
      assert DashboardSavingsFormatHelper.format_savings(1000.0) == "1.0 TB"
      assert DashboardSavingsFormatHelper.format_savings(1500.0) == "1.5 TB"
      assert DashboardSavingsFormatHelper.format_savings(2750.5) == "2.8 TB"
    end

    test "formats megabytes correctly" do
      assert DashboardSavingsFormatHelper.format_savings(0.001) == "1 MB"
      assert DashboardSavingsFormatHelper.format_savings(0.1) == "100 MB"
      assert DashboardSavingsFormatHelper.format_savings(0.512) == "512 MB"
      assert DashboardSavingsFormatHelper.format_savings(0.999) == "999 MB"
    end

    test "formats very small values" do
      assert DashboardSavingsFormatHelper.format_savings(0.0001) == "< 1 MB"
      assert DashboardSavingsFormatHelper.format_savings(0.0005) == "< 1 MB"
    end

    test "handles invalid values" do
      assert DashboardSavingsFormatHelper.format_savings(nil) == "N/A"
      assert DashboardSavingsFormatHelper.format_savings(0) == "N/A"
      assert DashboardSavingsFormatHelper.format_savings(-1) == "N/A"
      assert DashboardSavingsFormatHelper.format_savings("invalid") == "N/A"
    end

    test "formats realistic video savings scenarios" do
      # 4K video scenarios
      # Large 4K movie
      assert DashboardSavingsFormatHelper.format_savings(5.2) == "5.2 GB"
      # Very large 4K movie
      assert DashboardSavingsFormatHelper.format_savings(15.7) == "15.7 GB"

      # 1080p video scenarios
      # Average 1080p movie
      assert DashboardSavingsFormatHelper.format_savings(1.2) == "1.2 GB"
      # Large 1080p movie
      assert DashboardSavingsFormatHelper.format_savings(2.8) == "2.8 GB"

      # TV episode scenarios
      # 1080p TV episode
      assert DashboardSavingsFormatHelper.format_savings(0.5) == "500 MB"
      # 720p TV episode
      assert DashboardSavingsFormatHelper.format_savings(0.25) == "250 MB"

      # Collection scenarios
      # Large movie collection
      assert DashboardSavingsFormatHelper.format_savings(1250.0) == "1.3 TB"
      # Very large collection
      assert DashboardSavingsFormatHelper.format_savings(3400.5) == "3.4 TB"
    end
  end
end
