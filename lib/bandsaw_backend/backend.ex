defmodule Bandsaw.Backend do
  @moduledoc """
  Logger back-end that sends logs to a Bandsaw server. The target
  server can be configured through the application config.
  """
  use GenEvent

  defstruct server:     nil,
            app_id:     nil,
            app_key:    nil,
            app_env_id: nil,
            buffer:     :queue.new(),
            max_buffer: nil,
            level:      nil,
            flush:      1_000

  @doc """
  Initialize the bandsaw backend
  """
  def init(_) do
    send(self(), :flush)
    {:ok, configure(Application.get_env(:logger, :bandsaw_backend, []), %__MODULE__{})}
  end

  @doc """
  Handle an incoming log message or a flush instruction
  """
  def handle_event(   {level, _gl, {Logger, message, {d, {h, m, s, _ms}}, _metadata}},
                      %__MODULE__{buffer: buffer, level: min, max_buffer: max} = state) do
    cond do
      not meets_level?(level, min) ->
        {:ok, state}
      :queue.len(buffer) < max ->
        {:ok, %{state | buffer: :queue.in(%{
          level: level,
          timestamp: NaiveDateTime.from_erl!({d, {h, m, s}}),
          message: message
        }, buffer)}}
      :queue.len(buffer) === max ->
        {:ok, flush(state)}
    end
  end
  def handle_event(:flush, state),
    do: {:ok, flush(state)}
  def handle_event(_, state),
    do: {:ok, state}

  @doc """
  Handle a reconfigure call.
  """
  def handle_call({:configure, options}, state),
    do: {:ok, :ok, configure(options, state)}

  def handle_info(:flush, %__MODULE__{flush: interval} = state) do
    Process.send_after(self(), :flush, interval)
    {:ok, flush(state)}
  end
  def handle_info(_info, state),
    do: {:ok, state}

  @doc """
  Update the `gen_event` state based on the given options and current state.
  """
  def configure(options, state) do
    %{
      state
      | server:     Keyword.get(options, :server,     state.server),
        app_id:     Keyword.get(options, :app_id,     state.app_id),
        app_key:    Keyword.get(options, :app_key,    state.app_key),
        app_env_id: Keyword.get(options, :app_env_id, state.app_env_id),
        max_buffer: Keyword.get(options, :max_buffer, 3),
        level:      Keyword.get(options, :level),
        flush:      Keyword.get(options, :flush,      1_000)
    }
  end

  #
  # Flush buffered messages to the Bandsaw server
  #
  defp flush(%__MODULE__{server: nil} = state),
    do: state
  defp flush(%__MODULE__{server: server, buffer: buffer} = state) do
    with  {:length, length} when length > 0   <- {:length, :queue.len(buffer)},
          {:json, {:ok, json}}                <- {:json, Jason.encode(%{log_entries: :queue.to_list(buffer)})},
          {:post, {:ok, _response}}           <- {:post, HTTPoison.post(server, json, headers(state))} do
      %{state | buffer: :queue.new()}
    else
      {:length, 0} ->
        state
      {:json, {:error, reason}} ->
        IO.puts(:stderr, "Failed to encode log data to JSON: #{inspect reason}")
        state
      {:post, {:error, reason}} ->
        IO.puts(:stderr, "Failed to POST log data to Bandsaw server #{server}: #{inspect reason}")
        state
    end
  end

  #
  # Return a list of headers to be included in a request to the bandsaw server
  #
  defp headers(%__MODULE__{app_id: id, app_key: key, app_env_id: env}),
    do: [
      {"Content-Type",      "application/json"},
      {"x-application-id",  id},
      {"x-application-key", key},
      {"x-application-env", env}
    ]
  defp headers(_state),
    do: [{"Content-Type", "application/json"}]

  #
  # Determine whether the given logging level meets the configure level
  #
  defp meets_level?(_lvl, nil),
    do: true
  defp meets_level?(lvl, min),
    do: Logger.compare_levels(lvl, min) != :lt
end
