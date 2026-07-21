import Config

config :pokex, rig: Pokex.Rig.Fake
config :pokex, settings_path: "tmp/settings_test.json"
config :pokex, sensors: Pokex.Bots.Fisher.Sensors.Fake
config :pokex, home_dir: "tmp/test-home"
config :pokex, baseline_gap_ms: 1
config :pokex, capture_backend: :screencapture
# Never compile/spawn the native key helper in tests (stubbed via :executable).
config :pokex, native_key_events: false
config :pokex, perf_log_interval_ms: 0
# Tests often script different fake images for the same region back-to-back. Keep
# the global broker uncached there; targeted Capture tests enable cache explicitly.
config :pokex, capture_cache_ttl_ms: 0

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :pokex, PokexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "yXDcB5oZkv5cDfPCf35Ap7OyB3dOk+j4Pkujl5cq9vFdVeI0q2ut8Ymv6DIu15tw",
  server: false

# In test we don't send emails
config :pokex, Pokex.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# The always-on PlayerSupport monitor is started explicitly by the tests that need it,
# not auto-started, so the app-wide instance stays idle during unrelated tests.
config :pokex, :player_support_auto_monitor, false
# The Focus poller shells out to osascript for the frontmost app — never let the app-wide
# instance poll during unrelated tests. Focus tests drive their own instance with an injected
# frontmost reader.
config :pokex, :focus_auto_monitor, false
# Calibration's "front the game before the screenshot" shells out to osascript and sleeps —
# never in tests (the LiveView tests drive the capture flow with the faked Rig).
config :pokex, :calibration_front_game, false
# Fronting the game shells out to System Events — never from a test suite.
config :pokex, :front_game_cmd, false
# The app-wide Guardian must NOT act on session rules (stop conditions / anti-stagnation)
# during tests: a test planting a global :session fact + limits would wake its REAL
# stop_all, racing the test's own scoped Guardian (measured flaky). Guardian tests opt
# back in with `session_rules: true`.
config :pokex, :guardian_session_rules, false
