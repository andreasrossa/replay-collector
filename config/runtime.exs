import Config

# Load .env file in development
if config_env() == :dev do
  Dotenv.load!()
end

config :collector,
  collector_token: System.get_env("COLLECTOR_TOKEN"),
  api_base: System.get_env("API_BASE_URL"),
  replay_directory: System.get_env("REPLAY_DIRECTORY"),
  ws_ingestor_url: System.get_env("WS_INGESTOR_URL")
