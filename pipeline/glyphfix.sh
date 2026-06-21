#!/usr/bin/env bash
# ============================================================================
# glyphfix.sh — make a substrate's Claude TUI render the real glyphs (⏵⏵ / ←)
# over the ttyd web terminal instead of ASCII "_".
#
# Run INSIDE a container as root (docker exec -u root <node> bash /path/glyphfix.sh)
# or bake equivalently into the golden image.
#
# ROOT CAUSE (two layers, both required):
#   1. Claude, when it detects it's under tmux (TERM=tmux-256color), runs a
#      terminal-capability probe and falls back to ASCII "_" for ⏵⏵/← unless the
#      client answers it (a native terminal like Ghostty does; ttyd/xterm.js does
#      not). Forcing TERM=xterm-256color makes Claude take its normal path and
#      EMIT the real glyphs. (Verified: `tmux capture-pane` then shows U+23F5/U+2190.)
#   2. tmux only DRAWS those glyphs to a UTF-8 client. ttyd's `tmux attach` must be
#      `tmux -u attach` (+ LANG=C.UTF-8) or tmux substitutes "_" when painting to
#      xterm.js. (Box-drawing already worked; these specific glyphs did not.)
#
# Neither a tmux upgrade nor a Claude update is needed (both were ruled out).
# ============================================================================
set -uo pipefail

# --- Layer 1: claude TERM wrapper (claude emits real glyphs) ---
REAL=$(readlink -f "$(command -v claude)")
case "$REAL" in */claude-wrapper) ;; *)   # don't wrap a wrapper
  printf '%s\n' '#!/usr/bin/env bash' \
    '# Force a non-tmux TERM so Claude emits real TUI glyphs (⏵⏵/←) over ttyd; $TMUX stays set for hooks.' \
    'if [ -n "${TMUX:-}" ] && [ "${TERM:-}" = "tmux-256color" ]; then export TERM=xterm-256color; fi' \
    "exec \"$REAL\" \"\$@\"" > /usr/local/bin/claude-wrapper
  chmod +x /usr/local/bin/claude-wrapper
  ln -sf /usr/local/bin/claude-wrapper /usr/local/bin/claude
;; esac

# --- Layer 2: ttyd attaches as a UTF-8 tmux client (tmux draws the glyphs) ---
su tester -c '
  INSTALL_DIR=/home/tester/mypeople
  [ -f "$INSTALL_DIR/run/ttyd.pid" ] && kill "$(cat "$INSTALL_DIR/run/ttyd.pid")" 2>/dev/null || true
  pkill -x ttyd 2>/dev/null || true; sleep 1
  setsid bash -c "export LANG=C.UTF-8 LC_ALL=C.UTF-8; while true; do ttyd -W -a -p 7681 -t \"fontFamily=Menlo, Monaco, \\\"Cascadia Mono\\\", \\\"Fira Code\\\", \\\"Courier New\\\", monospace\" -t fontSize=13 -t disableLeaveAlert=true tmux -u attach; sleep 2; done" > "$INSTALL_DIR/run/ttyd.log" 2>&1 </dev/null &
  echo $! > "$INSTALL_DIR/run/ttyd.pid"
  tmux setenv -g LANG C.UTF-8; tmux setenv -g LC_ALL C.UTF-8
'
echo "glyphfix applied — re-spawn the agent (mp spawn) so it launches via the wrapper."
