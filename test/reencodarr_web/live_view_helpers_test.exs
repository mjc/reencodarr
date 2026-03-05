defmodule ReencodarrWeb.LiveViewHelpersTest do
  use ExUnit.Case, async: true

  alias ReencodarrWeb.LiveViewHelpers

  describe "calculate_stardate/1 with DateTime" do
    test "returns a float" do
      dt = ~U[2024-01-01 12:00:00Z]
      result = LiveViewHelpers.calculate_stardate(dt)
      assert is_float(result)
    end

    test "returns stardate near 74000 for year 2024" do
      dt = ~U[2024-01-01 00:00:00Z]
      stardate = LiveViewHelpers.calculate_stardate(dt)
      # Year 2024 is 24 years after 2000, so base 50000 + 24*1000 = 74000
      assert stardate >= 74_000.0
      assert stardate < 75_000.0
    end

    test "returns stardate near 75000 for year 2025" do
      dt = ~U[2025-01-01 00:00:00Z]
      stardate = LiveViewHelpers.calculate_stardate(dt)
      assert stardate >= 75_000.0
      assert stardate < 76_000.0
    end

    test "returns a value rounded to one decimal place" do
      dt = ~U[2024-06-15 00:00:00Z]
      stardate = LiveViewHelpers.calculate_stardate(dt)
      # Float.round to 1 decimal: the result should equal itself when re-rounded
      assert Float.round(stardate, 1) == stardate
    end

    test "later in the day gives a higher stardate than earlier" do
      morning = ~U[2024-06-15 06:00:00Z]
      evening = ~U[2024-06-15 18:00:00Z]

      assert LiveViewHelpers.calculate_stardate(evening) >
               LiveViewHelpers.calculate_stardate(morning)
    end

    test "later in the year gives higher stardate than earlier" do
      jan = ~U[2024-01-15 12:00:00Z]
      dec = ~U[2024-12-15 12:00:00Z]
      assert LiveViewHelpers.calculate_stardate(dec) > LiveViewHelpers.calculate_stardate(jan)
    end

    test "reference year 2000 gives stardate near 50000" do
      dt = ~U[2000-01-01 00:00:00Z]
      stardate = LiveViewHelpers.calculate_stardate(dt)
      # base is 50_000.0 + day_component for day 1
      assert stardate >= 50_000.0
      assert stardate < 50_010.0
    end
  end

  describe "calculate_stardate/1 with non-DateTime input" do
    test "returns 75212.8 for nil" do
      assert LiveViewHelpers.calculate_stardate(nil) == 75_212.8
    end

    test "returns 75212.8 for a string" do
      assert LiveViewHelpers.calculate_stardate("2024-01-01") == 75_212.8
    end

    test "returns 75212.8 for an integer" do
      assert LiveViewHelpers.calculate_stardate(42) == 75_212.8
    end
  end
end
