defmodule Reencodarr.Services.WebhookSync do
  @moduledoc """
  Keeps Sonarr and Radarr webhook notifications aligned with Reencodarr's
  current callback URLs and supported event subscriptions.
  """

  require Logger

  alias Reencodarr.Services
  alias Reencodarr.Services.{Radarr, Sonarr}

  @common_disabled_flags %{
    "onGrab" => false,
    "onUpgrade" => false,
    "onHealthIssue" => false,
    "includeHealthWarnings" => false,
    "onHealthRestored" => false,
    "onApplicationUpdate" => false,
    "onManualInteractionRequired" => false
  }

  @service_specs %{
    sonarr: %{
      client: Sonarr,
      config_getter: :get_sonarr_config,
      notification_name: "Reencodarr Sonarr",
      path: "/api/webhooks/sonarr",
      flags:
        Map.merge(@common_disabled_flags, %{
          "onDownload" => true,
          "onImportComplete" => true,
          "onRename" => true,
          "onSeriesAdd" => false,
          "onSeriesDelete" => true,
          "onEpisodeFileDelete" => true,
          "onEpisodeFileDeleteForUpgrade" => true
        })
    },
    radarr: %{
      client: Radarr,
      config_getter: :get_radarr_config,
      notification_name: "Reencodarr Radarr",
      path: "/api/webhooks/radarr",
      flags:
        Map.merge(@common_disabled_flags, %{
          "onDownload" => true,
          "onRename" => true,
          "onMovieAdded" => false,
          "onMovieDelete" => true,
          "onMovieFileDelete" => true,
          "onMovieFileDeleteForUpgrade" => true
        })
    }
  }

  def reconcile_all do
    Enum.each(Map.keys(@service_specs), &reconcile_for_service/1)
    :ok
  end

  def reconcile_for_service(service_type) when service_type in [:sonarr, :radarr] do
    spec = Map.fetch!(@service_specs, service_type)

    case apply(Services, spec.config_getter, []) do
      {:ok, %{enabled: true}} ->
        do_reconcile(service_type, spec)

      {:ok, %{enabled: false}} ->
        :skipped

      {:error, :not_found} ->
        :skipped
    end
  end

  def reconcile_for_service(_service_type), do: :skipped

  defp do_reconcile(service_type, spec) do
    desired_url = webhook_url(spec.path)

    with {:ok, %Req.Response{body: notifications}} <- list_notifications(spec.client),
         {:ok, payload, action} <- build_payload(notifications, spec, desired_url),
         {:ok, _response} <- persist_notification(spec.client, action, payload) do
      Logger.info(
        "WebhookSync: #{service_type} webhook #{action_verb(action)} for #{desired_url}"
      )

      :ok
    else
      {:error, reason} = error ->
        Logger.warning(
          "WebhookSync: failed to reconcile #{service_type} webhook: #{inspect(reason)}"
        )

        error

      other ->
        Logger.warning(
          "WebhookSync: unexpected #{service_type} webhook reconciliation result: #{inspect(other)}"
        )

        {:error, {:unexpected_result, other}}
    end
  end

  defp build_payload(notifications, spec, desired_url) when is_list(notifications) do
    case Enum.find(notifications, &managed_notification?(&1, spec)) do
      nil ->
        with {:ok, %Req.Response{body: schemas}} <- get_notification_schemas(spec.client),
             schema when is_map(schema) <- Enum.find(schemas, &webhook_schema?/1) do
          {:ok, notification_payload(schema, spec, desired_url), :create}
        else
          nil -> {:error, :webhook_schema_not_found}
          {:error, _reason} = error -> error
          other -> {:error, {:unexpected_schema_result, other}}
        end

      existing ->
        {:ok, notification_payload(existing, spec, desired_url), {:update, existing["id"]}}
    end
  end

  defp build_payload(other, _spec, _desired_url), do: {:error, {:invalid_notifications, other}}

  defp list_notifications(Sonarr), do: Sonarr.list_notifications()
  defp list_notifications(Radarr), do: Radarr.list_notifications()

  defp get_notification_schemas(Sonarr), do: Sonarr.get_notification_schemas()
  defp get_notification_schemas(Radarr), do: Radarr.get_notification_schemas()

  defp persist_notification(Sonarr, :create, payload), do: Sonarr.create_notification(payload)
  defp persist_notification(Radarr, :create, payload), do: Radarr.create_notification(payload)

  defp persist_notification(Sonarr, {:update, id}, payload),
    do: Sonarr.update_notification(id, payload)

  defp persist_notification(Radarr, {:update, id}, payload),
    do: Radarr.update_notification(id, payload)

  defp notification_payload(resource, spec, desired_url) do
    %{
      "id" => resource["id"],
      "name" => spec.notification_name,
      "implementationName" => resource["implementationName"] || "Webhook",
      "implementation" => resource["implementation"] || "Webhook",
      "configContract" => resource["configContract"] || "WebhookSettings",
      "tags" => resource["tags"] || [],
      "fields" => update_fields(resource["fields"] || [], desired_url)
    }
    |> Map.merge(spec.flags)
  end

  defp managed_notification?(notification, spec) when is_map(notification) do
    notification["implementationName"] == "Webhook" and
      (notification["name"] == spec.notification_name or
         webhook_path_match?(notification, spec.path))
  end

  defp managed_notification?(_notification, _spec), do: false

  defp webhook_schema?(schema) when is_map(schema), do: schema["implementationName"] == "Webhook"
  defp webhook_schema?(_schema), do: false

  defp webhook_path_match?(notification, path) do
    case field_value(notification["fields"] || [], "url") do
      url when is_binary(url) -> String.ends_with?(url, path)
      _ -> false
    end
  end

  defp field_value(fields, target_name) when is_list(fields) do
    fields
    |> Enum.find(fn
      %{"name" => name} -> name == target_name
      _ -> false
    end)
    |> case do
      %{"value" => value} -> value
      _ -> nil
    end
  end

  defp update_fields(fields, desired_url) do
    fields
    |> upsert_field("url", desired_url)
  end

  defp upsert_field(fields, target_name, target_value) do
    case Enum.find_index(fields, &field_named?(&1, target_name)) do
      nil ->
        fields ++ [%{"name" => target_name, "value" => target_value}]

      index ->
        List.update_at(fields, index, fn
          field when is_map(field) -> Map.put(field, "value", target_value)
          _ -> %{"name" => target_name, "value" => target_value}
        end)
    end
  end

  defp field_named?(%{"name" => name}, target_name), do: name == target_name
  defp field_named?(_, _), do: false

  defp webhook_url(path) do
    ReencodarrWeb.Endpoint.url() <> path
  end

  defp action_verb(:create), do: "created"
  defp action_verb({:update, _id}), do: "updated"
end
