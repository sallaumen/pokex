import Config

config :pokex, rig: Pokex.Rig.Fake
# Inside the home, as in production: Settings keeps the character layer at
# `<dir of settings.json>/chars/<slug>/settings.json`, and a settings_path
# outside the home made the tests' characters land in a different directory
# from the one `Pokex.Characters` reads.
config :pokex, settings_path: "tmp/test-home/settings.json"
config :pokex, sensors: Pokex.Bots.Fisher.Sensors.Fake
config :pokex, home_dir: "tmp/test-home"
config :pokex, baseline_gap_ms: 1
config :pokex, capture_backend: :screencapture
# Never compile/spawn the native key helper in tests (stubbed via :executable).
config :pokex, native_key_events: false
config :pokex, perf_log_interval_ms: 0
# The blind sweep's cadence is an actuator loop on an app-global worker: armed
# during the suite it throws balls into the shared Rig other tests assert on.
config :pokex, sweep_auto_tick: false
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
# The app-wide ShinyGuard must NOT attach the real arena feed when a test flips
# the global shiny_guard_enabled setting. Guard tests opt back in with `active: true`.
config :pokex, :shiny_guard_active, false
# O Logout global fica inerte na suíte: um pedido acidental travaria o latch e
# pararia a frota compartilhada. Testes optam por entrar com `active: true`.
config :pokex, :logout_active, false
# o journal NUNCA escreve no ~/.pokex real durante a suíte; instâncias de
# teste optam por entrar com persist: true + home temporário
config :pokex, :journal_persist, false
# the sentinel captures the REAL screen on boot — never in tests
config :pokex, :layout_sentinel_active, false
# stock alerts attach the :hud feed (a real capture) — never in tests
config :pokex, :stock_alerts_active, false
# the combo runner presses keys through the Body — never in tests
config :pokex, :combos_active, false
# the cavebot's tick walks the map through the Body — tests drive :tick by hand
config :pokex, :cavebot_active, false
# The app-wide Guardian must NOT act on session rules (stop conditions / anti-stagnation)
# during tests: a test planting a global :session fact + limits would wake its REAL
# stop_all, racing the test's own scoped Guardian (measured flaky). Guardian tests opt
# back in with `session_rules: true`.
config :pokex, :guardian_session_rules, false
# ...and its panic-corner POLL is off for the same family of reasons: it reads the cursor
# every 100ms through the SHARED Rig.Fake, so any test asserting "nothing reached the Rig"
# was racing a timer it never started (the fishing gate test failed on ~1 seed in 3; six
# other files carry an Enum.reject({:cursor_position}) to hide the same noise). The gate
# flag the poller writes is already opened once by test_helper. Guardian tests that
# exercise the corner opt back in with `auto_poll: true`.
config :pokex, :guardian_auto_poll, false
# Waking a NAMED perception feed starts a real capture loop that writes into the
# shared blackboard behind whatever test is running — the cavebot's own worker
# attaches :minimap and the feed then overwrote the position the test had just
# published (measured 2026-08-04, failed on some seeds only). Feed tests drive
# their own unnamed Feed and are unaffected.
config :pokex, :perception_feeds_active, false

# The coord-band search holds a real hover for ~2s in production; tests only
# need the ORDER of move -> shot -> restore, not the wall-clock.
config :pokex, coord_hover_settle_ms: 10, coord_hover_hold_ms: 60
config :pokex, coord_hover_jiggle_ms: 5
config :pokex, coord_walk_settle_ms: 5
