defmodule ReencodarrWeb.RulesLive do
  @moduledoc """
  Live dashboard for explaining how Reencodarr's encoding rules work.

  ## Features:
  - Interactive rule explanations
  - Example configurations
  - Parameter descriptions
  - Video format guidelines
  """

  use ReencodarrWeb, :live_view

  require Logger
  import ReencodarrWeb.LcarsComponents
  alias ReencodarrWeb.DashboardLiveHelpers

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:current_stardate, DashboardLiveHelpers.calculate_stardate(DateTime.utc_now()))
      |> assign(:selected_section, :overview)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_section", %{"section" => section}, socket) do
    section_atom = String.to_existing_atom(section)
    {:noreply, assign(socket, :selected_section, section_atom)}
  end

  @impl true
  def handle_event("set_timezone", %{"timezone" => _tz}, socket) do
    # For the rules page, we don't need to handle timezone changes
    # but we need to handle the event to prevent crashes
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.lcars_page_frame
      title="REENCODARR OPERATIONS - ENCODING RULES"
      current_page={:rules}
      current_stardate={@current_stardate}
    >
      <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
        <!-- Sidebar Navigation -->
        <div class="lg:col-span-1">
          <.rules_navigation selected_section={@selected_section} />
        </div>
        
    <!-- Main Content -->
        <div class="lg:col-span-3">
          <%= case @selected_section do %>
            <% :overview -> %>
              <.rules_overview />
            <% :video_rules -> %>
              <.video_rules_section />
            <% :audio_rules -> %>
              <.audio_rules_section />
            <% :hdr_support -> %>
              <.hdr_rules_section />
            <% :resolution_scaling -> %>
              <.resolution_rules_section />
            <% :helper_rules -> %>
              <.helper_rules_section />
            <% :crf_search -> %>
              <.crf_search_section />
            <% :command_examples -> %>
              <.command_examples_section />
          <% end %>
        </div>
      </div>
    </.lcars_page_frame>
    """
  end

  # Navigation Component
  defp rules_navigation(assigns) do
    ~H"""
    <div class="space-y-2">
      <.section_nav_button
        section={:overview}
        selected={@selected_section}
        label="OVERVIEW"
        description="How rules work"
      />
      <.section_nav_button
        section={:video_rules}
        selected={@selected_section}
        label="VIDEO ENCODING"
        description="AV1 parameters"
      />
      <.section_nav_button
        section={:audio_rules}
        selected={@selected_section}
        label="AUDIO ENCODING"
        description="Opus transcoding"
      />
      <.section_nav_button
        section={:hdr_support}
        selected={@selected_section}
        label="HDR SUPPORT"
        description="High Dynamic Range"
      />
      <.section_nav_button
        section={:resolution_scaling}
        selected={@selected_section}
        label="RESOLUTION"
        description="4K+ handling"
      />
      <.section_nav_button
        section={:helper_rules}
        selected={@selected_section}
        label="HELPER RULES"
        description="CUDA & Grain"
      />
      <.section_nav_button
        section={:crf_search}
        selected={@selected_section}
        label="CRF SEARCH"
        description="Quality testing"
      />
      <.section_nav_button
        section={:command_examples}
        selected={@selected_section}
        label="EXAMPLES"
        description="Real commands"
      />
    </div>
    """
  end

  defp section_nav_button(assigns) do
    active = assigns.section == assigns.selected

    assigns = assign(assigns, :active, active)

    ~H"""
    <button
      phx-click="select_section"
      phx-value-section={@section}
      class={[
        "w-full text-left p-3 rounded border transition-colors",
        if(@active,
          do: "bg-orange-600 border-orange-500 text-white",
          else: "bg-gray-800 border-gray-600 text-orange-300 hover:bg-gray-700"
        )
      ]}
    >
      <div class="font-bold">{@label}</div>
      <div class="text-sm opacity-75">{@description}</div>
    </button>
    """
  end

  # Content Sections

  defp rules_overview(assigns) do
    ~H"""
    <div class="space-y-6">
      <.lcars_panel title="ENCODING RULES OVERVIEW" color="orange">
        <div class="space-y-4 text-orange-100">
          <p class="text-lg leading-relaxed">
            Reencodarr uses a sophisticated rule system to determine optimal encoding parameters
            for each video file. The rules analyze media properties and apply appropriate settings
            automatically.
          </p>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-6">
            <div class="bg-gray-800 p-4 rounded border border-orange-500">
              <h3 class="text-orange-400 font-bold mb-2">🎬 VIDEO ANALYSIS</h3>
              <ul class="space-y-1 text-sm">
                <li>• Resolution detection (4K, 1080p, etc.)</li>
                <li>• HDR format identification</li>
                <li>• Dynamic range optimization</li>
                <li>• Codec compatibility checks</li>
              </ul>
            </div>

            <div class="bg-gray-800 p-4 rounded border border-orange-500">
              <h3 class="text-orange-400 font-bold mb-2">🔊 AUDIO PROCESSING</h3>
              <ul class="space-y-1 text-sm">
                <li>• Channel configuration analysis</li>
                <li>• Opus bitrate optimization</li>
                <li>• Atmos preservation rules</li>
                <li>• Multi-channel upmixing</li>
              </ul>
            </div>
          </div>
        </div>
      </.lcars_panel>

      <.lcars_panel title="RULE PRIORITY SYSTEM" color="blue">
        <div class="space-y-3 text-blue-100">
          <p>Rules are applied in a specific order with different rules for different contexts:</p>

          <div class="bg-gray-800 p-4 rounded border border-blue-400">
            <h4 class="text-blue-400 font-bold mb-2">CRF Search Context</h4>
            <ol class="space-y-2 text-sm">
              <li>
                <span class="text-blue-400 font-bold">1. HDR Rule:</span> <code>hdr/1</code>
                - HDR and SDR tuning parameters
              </li>
              <li>
                <span class="text-blue-400 font-bold">2. Resolution Rule:</span>
                <code>resolution/1</code> - 4K+ downscaling to 1080p
              </li>
              <li>
                <span class="text-blue-400 font-bold">3. Video Rule:</span> <code>video/1</code>
                - Pixel format standardization
              </li>
            </ol>
          </div>

          <div class="bg-gray-800 p-4 rounded border border-blue-400 mt-4">
            <h4 class="text-blue-400 font-bold mb-2">
              Encoding Context (includes all CRF rules plus)
            </h4>
            <ol class="space-y-2 text-sm">
              <li>
                <span class="text-blue-400 font-bold">0. Audio Rule:</span> <code>audio/1</code>
                - Opus transcoding (encoding only)
              </li>
              <li class="text-gray-400">1-3. Same as CRF Search...</li>
            </ol>
          </div>

          <div class="bg-gray-700 p-3 rounded mt-4">
            <h4 class="text-blue-300 font-semibold mb-1">Additional Helper Rules</h4>
            <ul class="space-y-1 text-sm">
              <li><code>cuda/1</code> - Hardware acceleration (manual application)</li>
              <li><code>grain/2</code> - Film grain synthesis for SDR content</li>
            </ul>
          </div>
        </div>
      </.lcars_panel>
    </div>
    """
  end

  defp video_rules_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <.lcars_panel title="VIDEO ENCODING STANDARDS" color="orange">
        <div class="space-y-4 text-orange-100">
          <p class="text-lg">
            Reencodarr enforces consistent video quality standards across all your media by automatically
            applying the best pixel format for modern AV1 encoding.
          </p>

          <div class="bg-gray-800 p-4 rounded border border-orange-500">
            <h3 class="text-orange-400 font-bold mb-3">🎯 What Happens to Your Videos</h3>
            <div class="space-y-3">
              <div class="bg-gray-700 p-3 rounded">
                <h4 class="text-orange-300 font-semibold mb-2">Pixel Format Standardization</h4>
                <p class="text-sm">
                  Every video gets converted to <strong>10-bit YUV 4:2:0</strong>
                  format, regardless of its original format.
                </p>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-3 text-sm">
                <div>
                  <h5 class="text-orange-300 font-semibold">Benefits:</h5>
                  <ul class="space-y-1 mt-1">
                    <li>• Smoother color gradients</li>
                    <li>• Reduced color banding</li>
                    <li>• Better compression efficiency</li>
                    <li>• Future-proof format</li>
                  </ul>
                </div>

                <div>
                  <h5 class="text-orange-300 font-semibold">Compatibility:</h5>
                  <ul class="space-y-1 mt-1">
                    <li>• Works on all modern devices</li>
                    <li>• Supported by streaming platforms</li>
                    <li>• Standard for 4K/HDR content</li>
                    <li>• Backward compatible</li>
                  </ul>
                </div>
              </div>
            </div>
          </div>

          <div class="bg-gray-700 p-4 rounded">
            <h3 class="text-orange-400 font-bold mb-2">🔧 Technical Deep Dive</h3>
            <div class="space-y-3 text-sm">
              <div>
                <h4 class="text-orange-300 font-semibold">Why 10-bit over 8-bit?</h4>
                <p>
                  10-bit provides 1,024 shades per color channel instead of 256, resulting in smoother transitions and more accurate colors, especially noticeable in dark scenes and gradients.
                </p>
              </div>

              <div>
                <h4 class="text-orange-300 font-semibold">YUV 4:2:0 Explained</h4>
                <p>
                  This is the standard way video is stored - full resolution for brightness (luma) but reduced resolution for color information (chroma). Your eyes are more sensitive to brightness than color, so this saves space without visible quality loss.
                </p>
              </div>

              <div>
                <h4 class="text-orange-300 font-semibold">Universal Application</h4>
                <p>
                  This rule applies to ALL videos, whether they're 720p, 1080p, 4K, HDR, or SDR. It ensures your entire library has consistent, high-quality encoding.
                </p>
              </div>
            </div>
          </div>

          <div class="bg-orange-900 p-4 rounded border border-orange-400">
            <h3 class="text-orange-200 font-bold mb-3">📋 Real-World Examples</h3>
            <div class="space-y-3 text-sm">
              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-orange-300 font-semibold mb-2">Example 1: Old DVD Rip</h4>
                <div class="grid grid-cols-2 gap-4">
                  <div>
                    <strong>Input:</strong> 8-bit YUV 4:2:0 (standard DVD)
                  </div>
                  <div>
                    <strong>Output:</strong> 10-bit YUV 4:2:0 (upgraded for AV1)
                  </div>
                </div>
                <p class="mt-2 text-orange-200">
                  Even old content gets the modern pixel format treatment for better compression and future compatibility.
                </p>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-orange-300 font-semibold mb-2">Example 2: High-End 4K Blu-ray</h4>
                <div class="grid grid-cols-2 gap-4">
                  <div>
                    <strong>Input:</strong> 10-bit YUV 4:2:0 (already optimal)
                  </div>
                  <div>
                    <strong>Output:</strong> 10-bit YUV 4:2:0 (maintained)
                  </div>
                </div>
                <p class="mt-2 text-orange-200">
                  Already-optimal content stays optimal, ensuring no degradation during re-encoding.
                </p>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-orange-300 font-semibold mb-2">Example 3: Web/Streaming Source</h4>
                <div class="grid grid-cols-2 gap-4">
                  <div>
                    <strong>Input:</strong> 8-bit YUV 4:2:0 (typical streaming)
                  </div>
                  <div>
                    <strong>Output:</strong> 10-bit YUV 4:2:0 (enhanced)
                  </div>
                </div>
                <p class="mt-2 text-orange-200">
                  Streaming content gets upgraded to broadcast/disc quality standards for your personal library.
                </p>
              </div>
            </div>
          </div>
        </div>
      </.lcars_panel>
    </div>
    """
  end

  defp audio_rules_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <.lcars_panel title="SMART AUDIO TRANSCODING" color="purple">
        <div class="space-y-4 text-purple-100">
          <p class="text-lg">
            Reencodarr intelligently decides when and how to convert your audio to the modern Opus codec,
            which provides excellent quality at smaller file sizes.
          </p>

          <div class="bg-gray-800 p-4 rounded border border-purple-500">
            <h3 class="text-purple-400 font-bold mb-3">🧠 Smart Decision Making</h3>
            <div class="space-y-3">
              <div class="bg-purple-900 p-3 rounded border border-purple-400">
                <h4 class="text-purple-200 font-semibold mb-2">When Audio is LEFT ALONE:</h4>
                <ul class="space-y-1 text-sm">
                  <li>🎭 <strong>Dolby Atmos content</strong> - Preserves object-based 3D audio</li>
                  <li>🎵 <strong>Already Opus</strong> - No need to re-encode optimal format</li>
                  <li>❓ <strong>Missing metadata</strong> - Safety check when info is unavailable</li>
                </ul>
              </div>

              <div class="bg-gray-700 p-3 rounded">
                <h4 class="text-purple-200 font-semibold mb-2">When Audio Gets CONVERTED:</h4>
                <p class="text-sm">
                  Everything else gets transcoded to Opus with channel-specific bitrates for optimal quality and file size.
                </p>
              </div>
            </div>
          </div>

          <div class="bg-gray-800 p-4 rounded border border-purple-500">
            <h3 class="text-purple-400 font-bold mb-3">🔊 Opus Bitrate Guide</h3>
            <div class="overflow-x-auto">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b border-purple-400">
                    <th class="text-left p-2 text-purple-300">Audio Layout</th>
                    <th class="text-left p-2 text-purple-300">Channels</th>
                    <th class="text-left p-2 text-purple-300">Bitrate</th>
                    <th class="text-left p-2 text-purple-300">Notes</th>
                  </tr>
                </thead>
                <tbody class="space-y-1">
                  <tr class="border-b border-gray-600">
                    <td class="p-2">Mono</td>
                    <td class="p-2">1</td>
                    <td class="p-2 text-purple-300">64 kbps</td>
                    <td class="p-2">Perfect for speech</td>
                  </tr>
                  <tr class="border-b border-gray-600">
                    <td class="p-2">Stereo</td>
                    <td class="p-2">2</td>
                    <td class="p-2 text-purple-300">96 kbps</td>
                    <td class="p-2">Excellent for music</td>
                  </tr>
                  <tr class="border-b border-gray-600 bg-purple-900">
                    <td class="p-2 font-bold">2.1 / 3.0</td>
                    <td class="p-2 font-bold">3 → 6</td>
                    <td class="p-2 text-purple-300 font-bold">128 kbps</td>
                    <td class="p-2 font-bold">⭐ Upmixed to 5.1!</td>
                  </tr>
                  <tr class="border-b border-gray-600">
                    <td class="p-2">5.1 Surround</td>
                    <td class="p-2">6</td>
                    <td class="p-2 text-purple-300">384 kbps</td>
                    <td class="p-2">Theater experience</td>
                  </tr>
                  <tr class="border-b border-gray-600">
                    <td class="p-2">7.1 Surround</td>
                    <td class="p-2">8</td>
                    <td class="p-2 text-purple-300">510 kbps</td>
                    <td class="p-2">Premium surround</td>
                  </tr>
                  <tr class="border-b border-gray-600">
                    <td class="p-2">High Channel Count</td>
                    <td class="p-2">9+</td>
                    <td class="p-2 text-purple-300">510 kbps</td>
                    <td class="p-2">Capped maximum</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div class="bg-gray-700 p-4 rounded">
            <h3 class="text-purple-400 font-bold mb-2">🎯 Special Features</h3>
            <div class="space-y-3 text-sm">
              <div>
                <h4 class="text-purple-300 font-semibold">⭐ 3-Channel Upmix (Opus Fix)</h4>
                <p>
                  When Reencodarr finds 3-channel audio (like 2.1 or 3.0), it automatically upgrades it to 6-channel 5.1 surround sound. This is necessary because Opus has encoding issues with 3-channel audio that can cause distortion or playback problems. The upmix creates a proper 6-channel layout with correct channel mapping rather than trying to preserve the problematic 3-channel configuration.
                </p>
              </div>

              <div>
                <h4 class="text-purple-300 font-semibold">🎭 Atmos Preservation</h4>
                <p>
                  Dolby Atmos uses object-based audio that can't be converted to traditional channels without losing its 3D positioning. Reencodarr respects this and leaves Atmos tracks completely untouched.
                </p>
              </div>

              <div>
                <h4 class="text-purple-300 font-semibold">🔄 Smart Skipping</h4>
                <p>
                  If your media already has Opus audio (the target format), Reencodarr skips audio encoding entirely. No unnecessary re-encoding means faster processing and no quality loss.
                </p>
              </div>

              <div>
                <h4 class="text-purple-300 font-semibold">⏱️ Context-Aware</h4>
                <p>
                  Audio transcoding only happens during the final encoding phase, not during quality testing (CRF search). This speeds up the analysis process significantly.
                </p>
              </div>
            </div>
          </div>

          <div class="bg-purple-900 p-4 rounded border border-purple-400">
            <h3 class="text-purple-200 font-bold mb-3">📋 Detailed Audio Scenarios</h3>
            <div class="space-y-4 text-sm">
              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-purple-300 font-semibold mb-2">
                  🎬 Scenario 1: Standard Blu-ray Movie
                </h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> DTS-HD Master Audio 5.1 (6 channels)</div>
                  <div><strong>Decision:</strong> Convert to Opus</div>
                  <div><strong>Output:</strong> Opus 384 kbps, 6 channels (5.1)</div>
                  <div class="text-purple-200 mt-2">
                    Perfect surround sound quality at much smaller file size than lossless DTS-HD.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-purple-300 font-semibold mb-2">🎭 Scenario 2: Dolby Atmos Movie</h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> Dolby Atmos TrueHD (object-based audio)</div>
                  <div><strong>Decision:</strong> Leave completely untouched</div>
                  <div><strong>Output:</strong> Original Dolby Atmos track preserved</div>
                  <div class="text-purple-200 mt-2">
                    3D audio positioning and height channels remain intact for compatible systems.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-purple-300 font-semibold mb-2">
                  🎵 Scenario 3: Netflix/Streaming Download
                </h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> AAC 2.0 Stereo (2 channels)</div>
                  <div><strong>Decision:</strong> Convert to Opus</div>
                  <div><strong>Output:</strong> Opus 96 kbps, 2 channels (stereo)</div>
                  <div class="text-purple-200 mt-2">
                    Better compression than AAC while maintaining stereo quality.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-purple-300 font-semibold mb-2">
                  ⭐ Scenario 4: Old TV Show (2.1 Audio)
                </h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> AC3 2.1 (3 channels: L, R, LFE)</div>
                  <div><strong>Decision:</strong> Convert and UPMIX to 5.1</div>
                  <div><strong>Output:</strong> Opus 128 kbps, 6 channels (5.1)</div>
                  <div class="text-purple-200 mt-2">
                    Upmixes to full 5.1 surround with proper channel mapping - fixes Opus encoding issues with 3-channel audio.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-purple-300 font-semibold mb-2">✅ Scenario 5: Already Optimized</h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> Opus 5.1 (6 channels)</div>
                  <div><strong>Decision:</strong> Skip audio processing entirely</div>
                  <div><strong>Output:</strong> Original Opus track unchanged</div>
                  <div class="text-purple-200 mt-2">
                    No re-encoding means zero quality loss and faster processing.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-purple-300 font-semibold mb-2">
                  🎙️ Scenario 6: Podcast/Speech Content
                </h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> MP3 Mono (1 channel)</div>
                  <div><strong>Decision:</strong> Convert to Opus</div>
                  <div><strong>Output:</strong> Opus 64 kbps, 1 channel (mono)</div>
                  <div class="text-purple-200 mt-2">
                    Excellent speech quality at minimal bitrate - perfect for voice content.
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </.lcars_panel>
    </div>
    """
  end

  defp hdr_rules_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <.lcars_panel title="HDR & SDR OPTIMIZATION" color="cyan">
        <div class="space-y-4 text-cyan-100">
          <p class="text-lg">
            Reencodarr automatically detects and applies the best encoding settings for both High Dynamic Range (HDR)
            and Standard Dynamic Range (SDR) content to preserve their unique characteristics.
          </p>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div class="bg-gray-800 p-4 rounded border border-cyan-500">
              <h3 class="text-cyan-400 font-bold mb-3">🌈 HDR Content Treatment</h3>
              <div class="space-y-3">
                <div class="bg-cyan-900 p-3 rounded">
                  <h4 class="text-cyan-200 font-semibold mb-2">What Gets HDR Treatment:</h4>
                  <ul class="space-y-1 text-sm">
                    <li>• HDR10 content</li>
                    <li>• HDR10+ content</li>
                    <li>• Dolby Vision content</li>
                    <li>• HLG (Hybrid Log-Gamma) content</li>
                  </ul>
                </div>

                <div class="space-y-2 text-sm">
                  <h5 class="text-cyan-300 font-semibold">Special HDR Features:</h5>
                  <ul class="space-y-1">
                    <li>
                      🎨 <strong>Visual Quality Optimization</strong>
                      - Prioritizes how it looks to your eyes
                    </li>
                    <li>
                      🔮 <strong>Dolby Vision Support</strong>
                      - Preserves dynamic metadata for compatible displays
                    </li>
                    <li>🎭 <strong>Wide Color Gamut</strong> - Maintains the expanded color range</li>
                  </ul>
                </div>
              </div>
            </div>

            <div class="bg-gray-800 p-4 rounded border border-cyan-500">
              <h3 class="text-cyan-400 font-bold mb-3">📺 SDR Content Treatment</h3>
              <div class="space-y-3">
                <div class="bg-gray-700 p-3 rounded">
                  <h4 class="text-cyan-200 font-semibold mb-2">Standard Content:</h4>
                  <p class="text-sm">
                    Regular Blu-ray, DVD, streaming, and broadcast content gets optimized for the best possible quality within standard color and brightness ranges.
                  </p>
                </div>

                <div class="space-y-2 text-sm">
                  <h5 class="text-cyan-300 font-semibold">SDR Optimizations:</h5>
                  <ul class="space-y-1">
                    <li>🎨 <strong>Visual Quality Focus</strong> - Same optimization as HDR</li>
                    <li>🎬 <strong>No HDR Flags</strong> - Maintains standard color space</li>
                    <li>
                      ⚡ <strong>Efficient Encoding</strong> - Faster processing for standard content
                    </li>
                  </ul>
                </div>
              </div>
            </div>
          </div>

          <div class="bg-gray-700 p-4 rounded">
            <h3 class="text-cyan-400 font-bold mb-2">🔍 How Detection Works</h3>
            <div class="space-y-3 text-sm">
              <div>
                <h4 class="text-cyan-300 font-semibold">Automatic HDR Detection</h4>
                <p>
                  Reencodarr uses MediaInfo to analyze your video files and automatically detect HDR metadata. This includes color primaries, transfer characteristics, and mastering display information embedded in the file.
                </p>
              </div>

              <div>
                <h4 class="text-cyan-300 font-semibold">Smart Parameter Selection</h4>
                <p>
                  Based on what it finds, Reencodarr automatically chooses the right encoding parameters. HDR content gets special flags to preserve its wide color gamut and high brightness range, while SDR content gets optimized for standard displays.
                </p>
              </div>

              <div>
                <h4 class="text-cyan-300 font-semibold">Future-Proof Encoding</h4>
                <p>
                  Both HDR and SDR content use the same quality-focused tuning, ensuring your media will look great on current and future displays while maintaining the characteristics that make HDR content special.
                </p>
              </div>
            </div>
          </div>

          <div class="bg-cyan-900 p-4 rounded border border-cyan-400">
            <h3 class="text-cyan-200 font-bold mb-2">💡 Why This Matters</h3>
            <div class="text-sm space-y-2">
              <p>
                HDR content has a much wider range of colors and brightness than regular video. If you encode it like standard video, you lose that extra visual information forever.
              </p>
              <p>
                Reencodarr ensures HDR content keeps its "HDR-ness" while still compressing efficiently, and SDR content gets the best possible quality within its limitations.
              </p>
            </div>
          </div>

          <div class="bg-cyan-900 p-4 rounded border border-cyan-400 mt-4">
            <h3 class="text-cyan-200 font-bold mb-3">📋 HDR Detection Examples</h3>
            <div class="space-y-4 text-sm">
              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-cyan-300 font-semibold mb-2">🌈 Scenario 1: 4K HDR10 Blu-ray</h4>
                <div class="space-y-2">
                  <div>
                    <strong>Detected:</strong> HDR10 metadata, BT.2020 color space, PQ transfer
                  </div>
                  <div>
                    <strong>Applied:</strong> Visual quality tune + Dolby Vision encoding support
                  </div>
                  <div>
                    <strong>Result:</strong> Preserves wide color gamut and high brightness range
                  </div>
                  <div class="text-cyan-200 mt-2">
                    Full HDR experience maintained with peak brightness up to 10,000 nits and expanded colors.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-cyan-300 font-semibold mb-2">🔮 Scenario 2: Dolby Vision Movie</h4>
                <div class="space-y-2">
                  <div><strong>Detected:</strong> Dolby Vision dynamic metadata</div>
                  <div>
                    <strong>Applied:</strong> Visual quality tune + Dolby Vision profile encoding
                  </div>
                  <div><strong>Result:</strong> Dynamic HDR that adapts scene-by-scene</div>
                  <div class="text-cyan-200 mt-2">
                    Scene-by-scene optimization preserved for compatible displays with enhanced visual impact.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-cyan-300 font-semibold mb-2">📺 Scenario 3: Regular Blu-ray (SDR)</h4>
                <div class="space-y-2">
                  <div><strong>Detected:</strong> No HDR metadata, BT.709 color space</div>
                  <div><strong>Applied:</strong> Visual quality tune only (no HDR flags)</div>
                  <div><strong>Result:</strong> Optimized for standard dynamic range displays</div>
                  <div class="text-cyan-200 mt-2">
                    Traditional content gets maximum quality within standard brightness and color limits.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-cyan-300 font-semibold mb-2">🎮 Scenario 4: Gaming/YouTube HDR</h4>
                <div class="space-y-2">
                  <div><strong>Detected:</strong> HDR10 signaling, variable quality</div>
                  <div><strong>Applied:</strong> Visual quality tune + HDR preservation</div>
                  <div><strong>Result:</strong> Gaming/streaming HDR cleaned up and optimized</div>
                  <div class="text-cyan-200 mt-2">
                    Even lower-quality HDR sources get proper treatment while maintaining their HDR characteristics.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-cyan-300 font-semibold mb-2">📱 Scenario 5: Mobile/Web Content</h4>
                <div class="space-y-2">
                  <div><strong>Detected:</strong> No HDR metadata, standard color space</div>
                  <div><strong>Applied:</strong> Visual quality tune for SDR</div>
                  <div><strong>Result:</strong> Enhanced SDR quality without false HDR signaling</div>
                  <div class="text-cyan-200 mt-2">
                    Mobile and web sources stay SDR but get optimized for best possible standard range quality.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-cyan-300 font-semibold mb-2">
                  🎬 Scenario 6: Mixed Content (TV Series)
                </h4>
                <div class="space-y-2">
                  <div><strong>Detected:</strong> Some episodes HDR, others SDR</div>
                  <div><strong>Applied:</strong> Per-episode detection and appropriate treatment</div>
                  <div><strong>Result:</strong> Each episode gets correct HDR/SDR encoding</div>
                  <div class="text-cyan-200 mt-2">
                    Series with mixed formats get consistent quality while preserving each episode's original characteristics.
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </.lcars_panel>
    </div>
    """
  end

  defp resolution_rules_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <.lcars_panel title="4K+ DOWNSCALING" color="green">
        <div class="space-y-4 text-green-100">
          <p class="text-lg">
            Reencodarr automatically downscales 4K and higher resolution content to 1080p for optimal
            balance of quality, file size, and encoding speed.
          </p>

          <div class="bg-gray-800 p-4 rounded border border-green-500">
            <h3 class="text-green-400 font-bold mb-3">📐 What Gets Downscaled</h3>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="bg-green-900 p-3 rounded">
                <h4 class="text-green-200 font-semibold mb-2">Input Resolutions:</h4>
                <ul class="space-y-1 text-sm">
                  <li>• 4K UHD (3840×2160)</li>
                  <li>• 4K DCI (4096×2160)</li>
                  <li>• 5K and higher</li>
                  <li>• Any height above 1080p</li>
                </ul>
              </div>

              <div class="bg-gray-700 p-3 rounded">
                <h4 class="text-green-200 font-semibold mb-2">Output Result:</h4>
                <ul class="space-y-1 text-sm">
                  <li>• Width: Fixed at 1920 pixels</li>
                  <li>• Height: Automatically calculated</li>
                  <li>• Aspect ratio: Perfectly preserved</li>
                  <li>• Quality: Optimized for 1080p</li>
                </ul>
              </div>
            </div>
          </div>

          <div class="bg-gray-700 p-4 rounded">
            <h3 class="text-green-400 font-bold mb-2">🎯 Why Downscale to 1080p?</h3>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
              <div>
                <h4 class="text-green-300 font-semibold">Performance Benefits:</h4>
                <ul class="space-y-1">
                  <li>• 4x faster encoding speed</li>
                  <li>• Much smaller file sizes</li>
                  <li>• Lower storage requirements</li>
                  <li>• Reduced network bandwidth</li>
                </ul>
              </div>

              <div>
                <h4 class="text-green-300 font-semibold">Practical Advantages:</h4>
                <ul class="space-y-1">
                  <li>• Universal device compatibility</li>
                  <li>• Smooth streaming on any connection</li>
                  <li>• Most displays are still 1080p</li>
                  <li>• Excellent quality at viewing distance</li>
                </ul>
              </div>
            </div>
          </div>

          <div class="bg-green-900 p-4 rounded border border-green-400">
            <h3 class="text-green-200 font-bold mb-2">📏 Example Transformations</h3>
            <div class="space-y-2 text-sm font-mono">
              <div class="grid grid-cols-3 gap-4">
                <div class="text-green-300">Original</div>
                <div class="text-center">→</div>
                <div class="text-green-300">Result</div>
              </div>
              <div class="grid grid-cols-3 gap-4">
                <div>3840×2160 (16:9)</div>
                <div class="text-center">→</div>
                <div>1920×1080</div>
              </div>
              <div class="grid grid-cols-3 gap-4">
                <div>4096×2160 (19:10)</div>
                <div class="text-center">→</div>
                <div>1920×1012</div>
              </div>
              <div class="grid grid-cols-3 gap-4">
                <div>3440×1440 (21:9)</div>
                <div class="text-center">→</div>
                <div>1920×800</div>
              </div>
            </div>
          </div>

          <div class="bg-gray-800 p-4 rounded border border-green-500">
            <h3 class="text-green-400 font-bold mb-2">🛡️ What's NOT Affected</h3>
            <div class="space-y-2 text-sm">
              <p>
                Content that's already 1080p or lower (like 720p) is left completely untouched. Reencodarr only downscales when it makes sense.
              </p>

              <div class="bg-gray-700 p-2 rounded mt-2">
                <strong>Safe resolutions:</strong>
                1920×1080, 1280×720, 1366×768, and anything with height ≤ 1080 pixels
              </div>
            </div>
          </div>

          <div class="bg-green-900 p-4 rounded border border-green-400 mt-4">
            <h3 class="text-green-200 font-bold mb-3">📋 Resolution Decision Examples</h3>
            <div class="space-y-4 text-sm">
              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-green-300 font-semibold mb-2">📼 Scenario 1: Old DVD Collection</h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> 720×480 (NTSC DVD)</div>
                  <div><strong>Decision:</strong> Leave untouched (height ≤ 1080)</div>
                  <div><strong>Output:</strong> 720×480 (unchanged)</div>
                  <div class="text-green-200 mt-2">
                    Classic content maintains its original resolution - no unnecessary upscaling or changes.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-green-300 font-semibold mb-2">📺 Scenario 2: HD Blu-ray Movie</h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> 1920×1080 (Full HD)</div>
                  <div><strong>Decision:</strong> Leave untouched (height = 1080)</div>
                  <div><strong>Output:</strong> 1920×1080 (unchanged)</div>
                  <div class="text-green-200 mt-2">
                    Perfect resolution already - no changes needed, optimal encoding efficiency.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-green-300 font-semibold mb-2">🎬 Scenario 3: 4K UHD Movie</h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> 3840×2160 (4K UHD)</div>
                  <div><strong>Decision:</strong> Downscale (height > 1080)</div>
                  <div><strong>Output:</strong> 1920×1080 (50% scale)</div>
                  <div class="text-green-200 mt-2">
                    4x faster encoding, much smaller files, still excellent quality for most viewing scenarios.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-green-300 font-semibold mb-2">
                  🖥️ Scenario 4: Ultrawide Gaming Content
                </h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> 3440×1440 (21:9 ultrawide)</div>
                  <div><strong>Decision:</strong> Downscale (height > 1080)</div>
                  <div><strong>Output:</strong> 1920×800 (maintains 21:9 aspect)</div>
                  <div class="text-green-200 mt-2">
                    Ultrawide aspect ratio preserved while reducing to manageable resolution.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-green-300 font-semibold mb-2">🎥 Scenario 5: Cinema 4K (DCI)</h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> 4096×2160 (Cinema 4K)</div>
                  <div><strong>Decision:</strong> Downscale (height > 1080)</div>
                  <div><strong>Output:</strong> 1920×1012 (maintains cinema aspect)</div>
                  <div class="text-green-200 mt-2">
                    Professional cinema format scaled to home viewing while preserving theatrical aspect ratio.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-green-300 font-semibold mb-2">📱 Scenario 6: Weird YouTube Upload</h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> 2560×1600 (odd aspect ratio)</div>
                  <div><strong>Decision:</strong> Downscale (height > 1080)</div>
                  <div><strong>Output:</strong> 1920×1200 (maintains 16:10 aspect)</div>
                  <div class="text-green-200 mt-2">
                    Even unusual resolutions get properly scaled while preserving the creator's intended aspect ratio.
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-green-300 font-semibold mb-2">📺 Scenario 7: 720p TV Show</h4>
                <div class="space-y-2">
                  <div><strong>Input:</strong> 1280×720 (HD Ready)</div>
                  <div><strong>Decision:</strong> Leave untouched (height ≤ 1080)</div>
                  <div><strong>Output:</strong> 1280×720 (unchanged)</div>
                  <div class="text-green-200 mt-2">
                    Lower resolution content stays at original quality - no forced upscaling that would waste space.
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </.lcars_panel>
    </div>
    """
  end

  defp helper_rules_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <.lcars_panel title="OPTIONAL ENHANCEMENT FEATURES" color="indigo">
        <div class="space-y-4 text-indigo-100">
          <p class="text-lg">
            These optional features can be manually enabled for specific hardware configurations
            or content enhancement needs.
          </p>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <!-- CUDA Rule -->
            <div class="bg-gray-800 p-4 rounded border border-indigo-500">
              <h3 class="text-indigo-400 font-bold mb-3">⚡ CUDA GPU Acceleration</h3>

              <div class="space-y-3">
                <div class="bg-indigo-900 p-3 rounded">
                  <h4 class="text-indigo-200 font-semibold mb-2">What it does:</h4>
                  <p class="text-sm">
                    Uses your NVIDIA graphics card to speed up video encoding instead of relying solely on your CPU.
                  </p>
                </div>

                <div class="space-y-2 text-sm">
                  <h5 class="text-indigo-300 font-semibold">Benefits:</h5>
                  <ul class="space-y-1">
                    <li>• Significantly faster encoding</li>
                    <li>• Reduces CPU load and heat</li>
                    <li>• Allows CPU for other tasks</li>
                    <li>• Great for high-volume processing</li>
                  </ul>

                  <h5 class="text-indigo-300 font-semibold mt-3">Requirements:</h5>
                  <ul class="space-y-1">
                    <li>• NVIDIA GPU with CUDA support</li>
                    <li>• Proper drivers installed</li>
                    <li>• Manual configuration required</li>
                  </ul>
                </div>
              </div>
            </div>
            
    <!-- Grain Rule -->
            <div class="bg-gray-800 p-4 rounded border border-indigo-500">
              <h3 class="text-indigo-400 font-bold mb-3">🎬 Film Grain Synthesis</h3>

              <div class="space-y-3">
                <div class="bg-gray-700 p-3 rounded">
                  <h4 class="text-indigo-200 font-semibold mb-2">What it does:</h4>
                  <p class="text-sm">
                    Adds artificial film grain to SDR content to preserve the natural texture and feel of original film sources.
                  </p>
                </div>

                <div class="space-y-2 text-sm">
                  <h5 class="text-indigo-300 font-semibold">Purpose:</h5>
                  <ul class="space-y-1">
                    <li>• Maintains cinematic film look</li>
                    <li>• Prevents over-smooth appearance</li>
                    <li>• Preserves artistic intent</li>
                    <li>• Adds natural texture</li>
                  </ul>

                  <h5 class="text-indigo-300 font-semibold mt-3">Smart Application:</h5>
                  <ul class="space-y-1">
                    <li>• Only applied to SDR content</li>
                    <li>• HDR content is left untouched</li>
                    <li>• Adjustable strength levels (0-50)</li>
                    <li>• Preserves existing film characteristics</li>
                  </ul>

                  <h5 class="text-indigo-300 font-semibold mt-3">HDR Fallback Behavior:</h5>
                  <ul class="space-y-1">
                    <li>• <strong>SDR Videos:</strong> Film grain can be applied</li>
                    <li>• <strong>HDR Videos:</strong> Film grain rule returns empty (no effect)</li>
                    <li>
                      • <strong>Reasoning:</strong>
                      HDR content typically has appropriate grain already
                    </li>
                    <li>• <strong>Safety:</strong> Prevents degrading HDR metadata or quality</li>
                  </ul>
                </div>
              </div>
            </div>
          </div>

          <div class="bg-gray-700 p-4 rounded">
            <h3 class="text-indigo-400 font-bold mb-2">🔧 Manual Configuration</h3>
            <div class="space-y-3 text-sm">
              <div>
                <h4 class="text-indigo-300 font-semibold">Not Automatic</h4>
                <p>
                  Unlike the main encoding rules, these features require manual setup and configuration. They're not part of the standard processing pipeline.
                </p>
              </div>

              <div>
                <h4 class="text-indigo-300 font-semibold">Hardware Dependent</h4>
                <p>
                  CUDA acceleration depends on having compatible NVIDIA hardware and proper driver installation. The system needs to detect and configure GPU support.
                </p>
              </div>

              <div>
                <h4 class="text-indigo-300 font-semibold">Content Specific</h4>
                <p>
                  Film grain synthesis is intelligently applied only where it makes sense - SDR content that might benefit from enhanced texture. HDR content typically already has appropriate grain characteristics.
                </p>
              </div>
            </div>
          </div>

          <div class="bg-indigo-900 p-4 rounded border border-indigo-400">
            <h3 class="text-indigo-200 font-bold mb-2">💡 When to Use These</h3>
            <div class="text-sm space-y-2">
              <p>
                <strong>CUDA Acceleration:</strong>
                Enable if you have a compatible NVIDIA GPU and want to speed up encoding, especially for large libraries or frequent processing.
              </p>
              <p>
                <strong>Film Grain:</strong>
                Consider for classic movies or content where you want to maintain a more traditional film aesthetic rather than the clean digital look.
              </p>
            </div>
          </div>
        </div>
      </.lcars_panel>
    </div>
    """
  end

  defp crf_search_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <.lcars_panel title="CRF SEARCH EXPLAINED" color="teal">
        <div class="space-y-4 text-teal-100">
          <p class="text-lg">
            Before encoding your videos, Reencodarr uses CRF (Constant Rate Factor) Search to find the perfect quality setting.
            This ensures optimal file sizes while maintaining excellent visual quality.
          </p>

          <div class="bg-gray-800 p-4 rounded border border-teal-500">
            <h3 class="text-teal-400 font-bold mb-3">🎯 What is CRF Search?</h3>
            <div class="space-y-3">
              <div class="bg-teal-900 p-3 rounded">
                <h4 class="text-teal-200 font-semibold mb-2">The Goal:</h4>
                <p class="text-sm">
                  Find the highest CRF value (lowest quality setting) that still produces a VMAF score of 95 or higher, ensuring visually transparent quality.
                </p>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-3 text-sm">
                <div>
                  <h5 class="text-teal-300 font-semibold">How CRF Works:</h5>
                  <ul class="space-y-1 mt-1">
                    <li>• Lower CRF = Higher quality, larger files</li>
                    <li>• Higher CRF = Lower quality, smaller files</li>
                    <li>• CRF 23 = Very high quality baseline</li>
                    <li>• CRF 28+ = Efficient compression</li>
                  </ul>
                </div>

                <div>
                  <h5 class="text-teal-300 font-semibold">VMAF Quality Score:</h5>
                  <ul class="space-y-1 mt-1">
                    <li>• 95+ = Visually transparent</li>
                    <li>• 90-94 = Excellent quality</li>
                    <li>• 80-89 = Good quality</li>
                    <li>• Below 80 = Visible quality loss</li>
                  </ul>
                </div>
              </div>
            </div>
          </div>

          <div class="bg-gray-700 p-4 rounded">
            <h3 class="text-teal-400 font-bold mb-2">🔍 How the Search Works</h3>
            <div class="space-y-3 text-sm">
              <div>
                <h4 class="text-teal-300 font-semibold">Sample Encoding Process</h4>
                <p>
                  Reencodarr encodes small sample clips (usually 30-60 seconds) from different parts of your video using various CRF values. This gives accurate quality predictions without encoding the entire file.
                </p>
              </div>

              <div>
                <h4 class="text-teal-300 font-semibold">VMAF Analysis</h4>
                <p>
                  Each sample is compared against the original using Netflix's VMAF algorithm, which predicts how the human eye perceives quality differences. VMAF scores closely match what viewers actually notice.
                </p>
              </div>

              <div>
                <h4 class="text-teal-300 font-semibold">Optimal Point Discovery</h4>
                <p>
                  The search finds the "sweet spot" - the highest CRF value that still achieves VMAF 95+. This maximizes compression while maintaining transparent quality that's indistinguishable from the source.
                </p>
              </div>
            </div>
          </div>

          <div class="bg-teal-900 p-4 rounded border border-teal-400">
            <h3 class="text-teal-200 font-bold mb-3">📊 Example CRF Search Results</h3>
            <div class="space-y-4 text-sm">
              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-teal-300 font-semibold mb-2">🎬 Action Movie (High Motion)</h4>
                <div class="space-y-2">
                  <div class="grid grid-cols-3 gap-4 text-xs font-mono">
                    <div><strong>CRF 26:</strong> VMAF 97.2</div>
                    <div><strong>CRF 28:</strong> VMAF 95.1</div>
                    <div><strong>CRF 30:</strong> VMAF 92.8</div>
                  </div>
                  <div class="text-teal-200 mt-2">
                    <strong>Result:</strong> CRF 28 selected (last value ≥95 VMAF)
                  </div>
                  <div class="text-xs">High motion content needs lower CRF for quality retention</div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-teal-300 font-semibold mb-2">🏞️ Animated Movie (Simple Scenes)</h4>
                <div class="space-y-2">
                  <div class="grid grid-cols-3 gap-4 text-xs font-mono">
                    <div><strong>CRF 30:</strong> VMAF 97.8</div>
                    <div><strong>CRF 32:</strong> VMAF 95.3</div>
                    <div><strong>CRF 34:</strong> VMAF 93.1</div>
                  </div>
                  <div class="text-teal-200 mt-2">
                    <strong>Result:</strong> CRF 32 selected (excellent compression)
                  </div>
                  <div class="text-xs">
                    Animation compresses very efficiently at higher CRF values
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-teal-300 font-semibold mb-2">📺 TV Drama (Mixed Content)</h4>
                <div class="space-y-2">
                  <div class="grid grid-cols-3 gap-4 text-xs font-mono">
                    <div><strong>CRF 27:</strong> VMAF 96.5</div>
                    <div><strong>CRF 29:</strong> VMAF 95.2</div>
                    <div><strong>CRF 31:</strong> VMAF 93.7</div>
                  </div>
                  <div class="text-teal-200 mt-2">
                    <strong>Result:</strong> CRF 29 selected (balanced efficiency)
                  </div>
                  <div class="text-xs">Mixed scenes require moderate CRF for consistent quality</div>
                </div>
              </div>
            </div>
          </div>

          <div class="bg-gray-800 p-4 rounded border border-teal-500">
            <h3 class="text-teal-400 font-bold mb-3">⚡ Why This Matters</h3>
            <div class="space-y-3 text-sm">
              <div>
                <h4 class="text-teal-300 font-semibold">Automatic Optimization</h4>
                <p>
                  Every video gets its own custom quality setting. No manual guessing or one-size-fits-all approaches. The system finds the perfect balance for each piece of content.
                </p>
              </div>

              <div>
                <h4 class="text-teal-300 font-semibold">Significant Space Savings</h4>
                <p>
                  By finding the optimal CRF, you can save 20-40% file size compared to conservative "safe" settings while maintaining the same visual quality your eyes can perceive.
                </p>
              </div>

              <div>
                <h4 class="text-teal-300 font-semibold">Quality Consistency</h4>
                <p>
                  VMAF targeting ensures consistent perceived quality across your entire library, regardless of content type, source, or complexity. Everything looks equally good.
                </p>
              </div>
            </div>
          </div>

          <div class="bg-teal-900 p-4 rounded border border-teal-400">
            <h3 class="text-teal-200 font-bold mb-3">🔧 Technical Process Details</h3>
            <div class="space-y-4 text-sm">
              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-teal-300 font-semibold mb-2">1. Sample Selection</h4>
                <div class="space-y-1">
                  <div>• Automatically chooses representative sections from your video</div>
                  <div>• Focuses on challenging scenes (high motion, detail, darkness)</div>
                  <div>• Usually 30-60 seconds total for accurate prediction</div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-teal-300 font-semibold mb-2">2. CRF Testing Range</h4>
                <div class="space-y-1">
                  <div>• Tests multiple CRF values (typically 23-35 range)</div>
                  <div>• Uses binary search for efficiency</div>
                  <div>• Applies all video rules during testing</div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-teal-300 font-semibold mb-2">3. VMAF Calculation</h4>
                <div class="space-y-1">
                  <div>• Compares encoded samples to original source</div>
                  <div>• Uses Netflix VMAF model for perceptual accuracy</div>
                  <div>• Accounts for resolution, motion, and detail complexity</div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-teal-300 font-semibold mb-2">4. Optimal Selection</h4>
                <div class="space-y-1">
                  <div>• Finds highest CRF with VMAF ≥95</div>
                  <div>• Provides file size predictions</div>
                  <div>• Stores results for final encoding phase</div>
                </div>
              </div>
            </div>
          </div>

          <div class="bg-teal-900 p-4 rounded border border-teal-400">
            <h3 class="text-teal-200 font-bold mb-3">⚡ Preset Fallback System</h3>
            <div class="space-y-4 text-sm">
              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-teal-300 font-semibold mb-2">🎯 How It Works</h4>
                <div class="space-y-2">
                  <div>
                    <strong>Initial Attempt:</strong>
                    CRF search starts with <code>--preset 8</code>
                    (faster encoding)
                  </div>
                  <div>
                    <strong>If Failed:</strong>
                    Automatically retries with <code>--preset 6</code>
                    (slower but more reliable)
                  </div>
                  <div>
                    <strong>Smart Detection:</strong>
                    System tracks which preset was used for each video
                  </div>
                  <div>
                    <strong>Final Encoding:</strong>
                    Uses the same preset that worked during CRF search
                  </div>
                </div>
              </div>

              <div class="bg-gray-800 p-3 rounded">
                <h4 class="text-teal-300 font-semibold mb-2">⚙️ Why This Matters</h4>
                <div class="space-y-2">
                  <div>
                    <strong>Speed Optimization:</strong>
                    Most videos work fine with preset 8 (faster processing)
                  </div>
                  <div>
                    <strong>Reliability:</strong>
                    Difficult content gets preset 6 automatically (better quality/stability)
                  </div>
                  <div>
                    <strong>Consistency:</strong> CRF search and final encoding use the same settings
                  </div>
                  <div>
                    <strong>No Manual Intervention:</strong> System handles failures gracefully
                  </div>
                </div>
              </div>

              <div class="bg-teal-800 p-3 rounded border border-teal-300">
                <h4 class="text-teal-200 font-semibold mb-2">📊 Preset Differences</h4>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-3 text-xs">
                  <div>
                    <strong>Preset 8 (Default):</strong>
                    <ul class="mt-1 space-y-1">
                      <li>• Faster encoding (2-3x speed)</li>
                      <li>• Good for most content</li>
                      <li>• May fail on complex scenes</li>
                      <li>• Preferred for efficiency</li>
                    </ul>
                  </div>
                  <div>
                    <strong>Preset 6 (Fallback):</strong>
                    <ul class="mt-1 space-y-1">
                      <li>• Slower but more thorough</li>
                      <li>• Handles complex content better</li>
                      <li>• Higher success rate</li>
                      <li>• Used when 8 fails</li>
                    </ul>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </.lcars_panel>
    </div>
    """
  end

  defp command_examples_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <.lcars_panel title="REAL COMMAND EXAMPLES" color="yellow">
        <div class="space-y-4 text-yellow-100">
          <p class="text-lg">
            See how the rules translate into actual ab-av1 encoding commands for different video types.
            These examples show the final commands after CRF search has determined the optimal quality setting.
          </p>

          <div class="space-y-4">
            <!-- Standard 1080p Example -->
            <div class="bg-gray-800 p-4 rounded border border-yellow-500">
              <h3 class="text-yellow-400 font-bold mb-2">📺 Standard 1080p Movie</h3>
              <div class="text-sm mb-2 text-yellow-200">
                Properties: 1920x1080, SDR, 5.1 DTS-HD Audio, No Opus
              </div>
              <div class="bg-black p-3 rounded font-mono text-xs overflow-x-auto">
                <code class="text-green-400">
                  ab-av1 encode --input movie.mkv --encoder svt-av1 --preset 8 --crf 28 --pix-format yuv420p10le --svt tune=0 --acodec libopus --enc b:a=384k --enc ac=6
                </code>
              </div>
              <div class="text-xs text-yellow-300 mt-2">
                ⚙️ Rules applied: video/1 (10-bit format) + hdr/1 (SDR tune) + audio/1 (DTS→Opus 5.1)
              </div>
            </div>
            
    <!-- 4K HDR Example -->
            <div class="bg-gray-800 p-4 rounded border border-yellow-500">
              <h3 class="text-yellow-400 font-bold mb-2">🎬 4K HDR Movie</h3>
              <div class="text-sm mb-2 text-yellow-200">
                Properties: 3840x2160, HDR10, 7.1 TrueHD Audio, No Opus
              </div>
              <div class="bg-black p-3 rounded font-mono text-xs overflow-x-auto">
                <code class="text-green-400">
                  ab-av1 encode --input movie_4k.mkv --encoder svt-av1 --preset 8 --crf 26 --pix-format yuv420p10le --vfilter scale=1920:-2 --svt tune=0 --svt dolbyvision=1 --acodec libopus --enc b:a=510k --enc ac=8
                </code>
              </div>
              <div class="text-xs text-yellow-300 mt-2">
                ⚙️ Rules applied: resolution/1 (4K→1080p) + hdr/1 (HDR+DV) + video/1 (10-bit) + audio/1 (TrueHD→Opus 7.1)
              </div>
            </div>
            <!-- Atmos Example -->
            <div class="bg-gray-800 p-4 rounded border border-yellow-500">
              <h3 class="text-yellow-400 font-bold mb-2">🔊 Atmos Content</h3>
              <div class="text-sm mb-2 text-yellow-200">
                Properties: 1920x1080, SDR, Dolby Atmos TrueHD
              </div>
              <div class="bg-black p-3 rounded font-mono text-xs overflow-x-auto">
                <code class="text-green-400">
                  ab-av1 encode --input atmos_movie.mkv --encoder svt-av1 --preset 8 --crf 28 --pix-format yuv420p10le --svt tune=0
                </code>
              </div>
              <div class="text-xs text-yellow-300 mt-2">
                ⚙️ Rules applied: video/1 (10-bit) + hdr/1 (SDR tune) + audio/1 (SKIPPED - Atmos preserved)
              </div>
            </div>
            
    <!-- 2.1 Upmix Example -->
            <div class="bg-gray-800 p-4 rounded border border-yellow-500">
              <h3 class="text-yellow-400 font-bold mb-2">⭐ TV Show with 2.1 Audio</h3>
              <div class="text-sm mb-2 text-yellow-200">
                Properties: 1920x1080, SDR, AC3 2.1 (3 channels)
              </div>
              <div class="bg-black p-3 rounded font-mono text-xs overflow-x-auto">
                <code class="text-green-400">
                  ab-av1 encode --input tv_show.mkv --encoder svt-av1 --preset 8 --crf 30 --pix-format yuv420p10le --svt tune=0 --acodec libopus --enc b:a=128k --enc ac=6
                </code>
              </div>
              <div class="text-xs text-yellow-300 mt-2">
                ⭐ Special: 3-channel upmixed to 6-channel 5.1 Opus (fixes Opus 2.1 encoding issues)
              </div>
            </div>
            <!-- Already Optimized Example -->
            <div class="bg-gray-800 p-4 rounded border border-yellow-500">
              <h3 class="text-yellow-400 font-bold mb-2">✅ Already Optimized</h3>
              <div class="text-sm mb-2 text-yellow-200">
                Properties: 1920x1080, SDR, Opus 5.1 Audio
              </div>
              <div class="bg-black p-3 rounded font-mono text-xs overflow-x-auto">
                <code class="text-green-400">
                  ab-av1 encode --input optimized.mkv --encoder svt-av1 --preset 8 --crf 28 --pix-format yuv420p10le --svt tune=0
                </code>
              </div>
              <div class="text-xs text-yellow-300 mt-2">
                ✅ Audio skipped: Already optimal Opus format, no re-encoding needed
              </div>
            </div>
            
    <!-- DVD Upscale Example -->
            <div class="bg-gray-800 p-4 rounded border border-yellow-500">
              <h3 class="text-yellow-400 font-bold mb-2">📼 DVD Collection</h3>
              <div class="text-sm mb-2 text-yellow-200">Properties: 720x480, SDR, AC3 5.1 Audio</div>
              <div class="bg-black p-3 rounded font-mono text-xs overflow-x-auto">
                <code class="text-green-400">
                  ab-av1 encode --input dvd_movie.mkv --encoder svt-av1 --preset 8 --crf 32 --pix-format yuv420p10le --svt tune=0 --acodec libopus --enc b:a=384k --enc ac=6
                </code>
              </div>
              <div class="text-xs text-yellow-300 mt-2">
                📼 Low resolution preserved, audio upgraded from AC3 to Opus, 10-bit for better AV1 compression
              </div>
            </div>
            <!-- Ultrawide Gaming Example -->
            <div class="bg-gray-800 p-4 rounded border border-yellow-500">
              <h3 class="text-yellow-400 font-bold mb-2">🎮 Ultrawide Gaming Capture</h3>
              <div class="text-sm mb-2 text-yellow-200">Properties: 3440x1440, SDR, Stereo PCM</div>
              <div class="bg-black p-3 rounded font-mono text-xs overflow-x-auto">
                <code class="text-green-400">
                  ab-av1 encode --input gaming.mkv --encoder svt-av1 --preset 8 --crf 26 --pix-format yuv420p10le --vfilter scale=1920:-2 --svt tune=0 --acodec libopus --enc b:a=96k --enc ac=2
                </code>
              </div>
              <div class="text-xs text-yellow-300 mt-2">
                🎮 Downscaled from 3440×1440 to 1920×800 (maintains 21:9), stereo PCM to Opus
              </div>
            </div>
            
    <!-- Mixed Series Example -->
            <div class="bg-gray-800 p-4 rounded border border-yellow-500">
              <h3 class="text-yellow-400 font-bold mb-2">📺 Modern TV Series (Mixed HDR/SDR)</h3>
              <div class="text-sm mb-2 text-yellow-200">
                Properties: 1920x1080, Some episodes HDR10, Various audio
              </div>
              <div class="space-y-2">
                <div class="bg-black p-2 rounded font-mono text-xs">
                  <div class="text-cyan-400">Episode 1 (HDR):</div>
                  <code class="text-green-400">
                    --svt tune=0 --svt dolbyvision=1 --acodec libopus --enc b:a=384k
                  </code>
                </div>
                <div class="bg-black p-2 rounded font-mono text-xs">
                  <div class="text-orange-400">Episode 2 (SDR):</div>
                  <code class="text-green-400">--svt tune=0 --acodec libopus --enc b:a=96k</code>
                </div>
              </div>
              <div class="text-xs text-yellow-300 mt-2">
                📺 Each episode analyzed individually: HDR episodes get DV support, different audio gets appropriate Opus bitrates
              </div>
            </div>
          </div>
        </div>
      </.lcars_panel>

      <.lcars_panel title="PARAMETER REFERENCE" color="blue">
        <div class="space-y-3 text-blue-100">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
            <div>
              <h4 class="text-blue-400 font-bold mb-2">Video Parameters</h4>
              <ul class="space-y-1">
                <li><code>--encoder svt-av1</code> - AV1 encoder selection</li>
                <li><code>--preset 8</code> - Speed/quality preset (fallback to 6 if needed)</li>
                <li><code>--svt tune=0</code> - Visual quality optimization</li>
                <li><code>--keyint 240</code> - 10-second keyframe interval</li>
                <li><code>--min-vmaf 95</code> - Perceptual quality target</li>
              </ul>
            </div>
            <div>
              <h4 class="text-blue-400 font-bold mb-2">Audio Parameters</h4>
              <ul class="space-y-1">
                <li><code>--acodec libopus</code> - Opus audio codec</li>
                <li><code>--enc b:a=XXXk</code> - Audio bitrate</li>
                <li><code>--enc ac=X</code> - Audio channel count</li>
              </ul>
            </div>
          </div>
        </div>
      </.lcars_panel>
    </div>
    """
  end
end
