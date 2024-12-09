defmodule ReencodarrWeb.VmafTableComponent do
  use ReencodarrWeb, :live_component

  def render(assigns) do
    ~H"""
    <table class="min-w-full bg-white">
      <thead>
        <tr>
          <th class="py-2">Title</th>
          <th class="py-2">Percent</th>
          <th class="py-2">Size</th>
          <th class="py-2">Time</th>
          <th class="py-2">Duration</th>
        </tr>
      </thead>
      <tbody id="vmaf-rows">
        <%= for {id, vmaf} <- @vmafs do %>
          <tr id={"vmaf-#{id}"}>
            <td class="border px-4 py-2">{vmaf.video.title}</td>
            <td class="border px-4 py-2">{vmaf.percent}</td>
            <td class="border px-4 py-2">{vmaf.size}</td>
            <td class="border px-4 py-2">{vmaf.time}</td>
            <td class="border px-4 py-2">{format_duration(vmaf.time)}</td>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end

  defp format_duration(time) do
    # Assuming `time` is in seconds
    minutes = div(time, 60)
    seconds = rem(time, 60)
    "#{minutes}m #{seconds}s"
  end
end
