defmodule Collector.Application do
  use Application

  @spec start(any(), any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start(_type, _args) do
    :logger.add_handler(:sentry, Sentry.LoggerHandler, %{
      config: %{metadata: [:file, :line]}
    })

    try do
      a = 1 / 0
      IO.puts(a)
    rescue
      my_exception ->
        Sentry.capture_exception(my_exception, stacktrace: __STACKTRACE__)
    end

    Collector.Supervisor.start_link(name: Collector.Supervisor)
  end
end
