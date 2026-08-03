# `worker_name/1` is a label table. The panel only raises the error alarm for
# five of the workers today (fishing, combat, catcher, mini_game, game), so the
# :player_support and :cavebot labels read as unreachable — but deleting them
# would crash the page the day either worker starts reporting errors.
[
  {"lib/pokex_web/live/panel_live.ex", :pattern_match}
]
