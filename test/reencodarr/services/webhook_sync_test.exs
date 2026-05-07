defmodule Reencodarr.Services.WebhookSyncTest do
  use Reencodarr.DataCase, async: false

  import Reencodarr.ServicesFixtures

  alias Reencodarr.Services.{Radarr, Sonarr}
  alias Reencodarr.Services.WebhookSync

  setup do
    :meck.unload()
    :ok
  end

  defp webhook_url(path), do: ReencodarrWeb.Endpoint.url() <> path

  describe "reconcile_for_service/1" do
    test "creates a managed Sonarr webhook with only supported subscriptions" do
      config_fixture(%{
        service_type: :sonarr,
        url: "http://sonarr.local",
        api_key: "sonarr-key",
        enabled: true
      })

      :meck.new(Sonarr, [:passthrough])

      :meck.expect(Sonarr, :list_notifications, fn ->
        {:ok, %Req.Response{body: []}}
      end)

      :meck.expect(Sonarr, :get_notification_schemas, fn ->
        {:ok,
         %Req.Response{
           body: [
             %{
               "implementationName" => "Webhook",
               "implementation" => "Webhook",
               "configContract" => "WebhookSettings",
               "fields" => [
                 %{"name" => "url", "value" => nil},
                 %{"name" => "method", "value" => 1}
               ]
             }
           ]
         }}
      end)

      :meck.expect(Sonarr, :create_notification, fn payload ->
        assert payload["name"] == "Reencodarr Sonarr"
        assert payload["onDownload"] == true
        assert payload["onImportComplete"] == true
        assert payload["onRename"] == true
        assert payload["onSeriesDelete"] == true
        assert payload["onEpisodeFileDelete"] == true
        assert payload["onEpisodeFileDeleteForUpgrade"] == true
        assert payload["onGrab"] == false
        assert payload["onSeriesAdd"] == false
        assert payload["onHealthIssue"] == false

        assert Enum.find(payload["fields"], &(&1["name"] == "url"))["value"] ==
                 webhook_url("/api/webhooks/sonarr")

        {:ok, %Req.Response{body: %{"id" => 101}}}
      end)

      assert :ok = WebhookSync.reconcile_for_service(:sonarr)
    end

    test "updates a legacy Sonarr webhook when its callback path matches" do
      config_fixture(%{
        service_type: :sonarr,
        url: "http://sonarr.local",
        api_key: "sonarr-key",
        enabled: true
      })

      :meck.new(Sonarr, [:passthrough])

      :meck.expect(Sonarr, :list_notifications, fn ->
        {:ok,
         %Req.Response{
           body: [
             %{
               "id" => 12,
               "name" => "Webhook",
               "implementationName" => "Webhook",
               "implementation" => "Webhook",
               "configContract" => "WebhookSettings",
               "tags" => [],
               "fields" => [
                 %{"name" => "url", "value" => "https://old-host.example/api/webhooks/sonarr"},
                 %{"name" => "method", "value" => 1}
               ]
             }
           ]
         }}
      end)

      :meck.expect(Sonarr, :update_notification, fn 12, payload ->
        assert payload["name"] == "Reencodarr Sonarr"

        assert Enum.find(payload["fields"], &(&1["name"] == "url"))["value"] ==
                 webhook_url("/api/webhooks/sonarr")

        {:ok, %Req.Response{body: %{"id" => 12}}}
      end)

      assert :ok = WebhookSync.reconcile_for_service(:sonarr)
    end

    test "updates an existing managed Radarr webhook when the callback URL changes" do
      config_fixture(%{
        service_type: :radarr,
        url: "http://radarr.local",
        api_key: "radarr-key",
        enabled: true
      })

      :meck.new(Radarr, [:passthrough])

      :meck.expect(Radarr, :list_notifications, fn ->
        {:ok,
         %Req.Response{
           body: [
             %{
               "id" => 22,
               "name" => "Reencodarr Radarr",
               "implementationName" => "Webhook",
               "implementation" => "Webhook",
               "configContract" => "WebhookSettings",
               "tags" => [],
               "fields" => [
                 %{"name" => "url", "value" => "https://old.example/api/webhooks/radarr"},
                 %{"name" => "method", "value" => 1}
               ],
               "onGrab" => true,
               "onDownload" => false,
               "onRename" => false
             }
           ]
         }}
      end)

      :meck.expect(Radarr, :update_notification, fn 22, payload ->
        assert payload["name"] == "Reencodarr Radarr"
        assert payload["onDownload"] == true
        assert payload["onRename"] == true
        assert payload["onMovieDelete"] == true
        assert payload["onMovieFileDelete"] == true
        assert payload["onMovieFileDeleteForUpgrade"] == true
        assert payload["onGrab"] == false
        assert payload["onMovieAdded"] == false
        assert payload["onHealthIssue"] == false

        assert Enum.find(payload["fields"], &(&1["name"] == "url"))["value"] ==
                 webhook_url("/api/webhooks/radarr")

        {:ok, %Req.Response{body: %{"id" => 22}}}
      end)

      assert :ok = WebhookSync.reconcile_for_service(:radarr)
    end

    test "skips reconciliation when no matching config exists" do
      assert :skipped = WebhookSync.reconcile_for_service(:sonarr)
    end
  end
end
