#!/bin/bash
# Xcode build phase: compiles the agent engine into a single executable and copies it, together with the
# Claude Code native binary that the Agent SDK drives, into AgentOS.app/Contents/Resources/engine/.
set -euo pipefail

ENGINE_DIR="${SRCROOT}/agent-engine"
OUT="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/engine"
BUN="$(command -v bun || true)"
for candidate in /opt/homebrew/bin/bun /usr/local/bin/bun "$HOME/.bun/bin/bun"; do
  [ -n "$BUN" ] && break
  [ -x "$candidate" ] && BUN="$candidate"
done
if [ -z "$BUN" ]; then
  echo "error: bun not found; install it from https://bun.sh" >&2
  exit 1
fi

mkdir -p "$OUT"
cd "$ENGINE_DIR"
[ -d node_modules ] || "$BUN" install --frozen-lockfile
"$BUN" build --compile --minify src/index.ts --outfile "$OUT/agentos-engine"
rm -f .*.bun-build  # temp files bun --compile can leave behind in the working directory

ARCH="$(uname -m)"; [ "$ARCH" = "x86_64" ] && ARCH="x64"
CLAUDE_BIN="node_modules/@anthropic-ai/claude-agent-sdk-darwin-${ARCH}/claude"
rsync -a "$CLAUDE_BIN" "$OUT/claude"
