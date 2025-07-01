#!/usr/bin/env elixir

# Simple test script to verify dashboard queue display
# This script demonstrates the dashboard queue functionality

Mix.install([
  {:phoenix_live_view, "~> 0.18"}
])

defmodule TestQueue do
  def test_queue_display do
    # Simulate queue data with more than 10 items
    queue_data = %{
      files: [
        %{index: 1, display_name: "movie1.mkv", estimated_percent: 25},
        %{index: 2, display_name: "movie2.mkv", estimated_percent: 30},
        %{index: 3, display_name: "movie3.mkv", estimated_percent: 22},
        %{index: 4, display_name: "movie4.mkv", estimated_percent: 28},
        %{index: 5, display_name: "movie5.mkv", estimated_percent: 35},
        %{index: 6, display_name: "movie6.mkv", estimated_percent: 20},
        %{index: 7, display_name: "movie7.mkv", estimated_percent: 27},
        %{index: 8, display_name: "movie8.mkv", estimated_percent: 33},
        %{index: 9, display_name: "movie9.mkv", estimated_percent: 29},
        %{index: 10, display_name: "movie10.mkv", estimated_percent: 24}
      ],
      total_count: 25  # Total count is 25, showing first 10
    }

    IO.puts("=== Dashboard Queue Display Test ===")
    IO.puts("Queue files count: #{length(queue_data.files)}")
    IO.puts("Total queue count: #{queue_data.total_count}")

    # Test the logic from the template
    show_truncation_message = length(queue_data.files) == 10 and queue_data.total_count > 10

    if show_truncation_message do
      IO.puts("✅ Should display: 'SHOWING FIRST 10 OF #{queue_data.total_count} ITEMS'")
    else
      IO.puts("❌ Should NOT display truncation message")
    end

    # Test with empty queue
    empty_queue = %{files: [], total_count: 0}
    show_empty = length(empty_queue.files) == 10 and empty_queue.total_count > 10
    IO.puts("Empty queue truncation: #{show_empty} (should be false)")

    # Test with exactly 10 items and total_count = 10
    exact_queue = %{files: queue_data.files, total_count: 10}
    show_exact = length(exact_queue.files) == 10 and exact_queue.total_count > 10
    IO.puts("Exact queue (10 of 10) truncation: #{show_exact} (should be false)")

    IO.puts("=== Test Complete ===")
  end
end

TestQueue.test_queue_display()
