import Config

# Load .env file in development
if config_env() == :dev do
  Dotenv.load!()
end

config :collector,
  collector_token: System.get_env("COLLECTOR_TOKEN"),
  api_base: System.get_env("API_BASE_URL"),
  replay_directory: System.get_env("REPLAY_DIRECTORY"),
  ws_ingestor_url: System.get_env("WS_INGESTOR_URL"),
  vercel_bypass_token: System.get_env("VERCEL_BYPASS_TOKEN")

config :sentry,
  dsn:
    "https://a0d7c9f8d0b1bc69c36cba7ce37f6fa1@o4509623725850624.ingest.de.sentry.io/4509623735025744",
  environment_name: Mix.env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()]
