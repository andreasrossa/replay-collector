import Config

config :codepagex, :encodings, [
  # CP392 is SHIFT_JIS
  # https://en.wikipedia.org/wiki/Code_page_932_(Microsoft_Windows)
  # Make sure to `mix deps.compile codepagex --force` after changing this
  "VENDORS/MICSFT/WINDOWS/CP932"
]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:wii_nickname, :wii_ip]

config :posthog,
  api_url: "https://eu.i.posthog.com",
  api_key: "phc_A1OfvPCStTrti02Fc5Ol3I7RwjYumCkuaABGpaog4v2",
  enabled_capture: true
