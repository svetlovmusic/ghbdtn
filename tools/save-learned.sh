#!/bin/bash
# save-learned.sh — fold THIS machine's learned words into the committed seed
# (Sources/Ghbdtn/Resources/seed-learned.json) and push to GitHub, so a fresh
# install on another computer already knows what you've taught the app.
#
# Ships only *confirmed* learning (a word seen >= activation count), so stray
# one-off corrections don't leak into the shared seed. Run it whenever you've
# taught the app new words and want them synced:
#
#   ./tools/save-learned.sh            # merge, commit, and push
#   ./tools/save-learned.sh --no-push  # merge + commit only (push yourself)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL="$HOME/Library/Application Support/Ghbdtn/learned.json"
SEED="$ROOT/Sources/Ghbdtn/Resources/seed-learned.json"
THRESHOLD=2   # keep in sync with LearnedStore.activationCount
PUSH="yes"
[ "${1:-}" = "--no-push" ] && PUSH="no"

if [ ! -f "$LOCAL" ]; then
  echo "No learned words on this machine yet ($LOCAL) — nothing to save."
  exit 0
fi

python3 - "$LOCAL" "$SEED" "$THRESHOLD" <<'PY'
import json, os, sys
local_p, seed_p, thresh = sys.argv[1], sys.argv[2], int(sys.argv[3])
def load(p):
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception:
        return {}
local, seed = load(local_p), (load(seed_p) if os.path.exists(seed_p) else {})
out = {"positive": {}, "negative": {}}
for side in ("positive", "negative"):
    merged = {}
    # existing seed first, then this machine's confirmed learning (max count)
    for src, gate in ((seed.get(side, {}), 0), (local.get(side, {}), thresh)):
        for lang, words in src.items():
            m = merged.setdefault(lang, {})
            for w, c in words.items():
                if c >= gate:
                    m[w] = max(m.get(w, 0), c)
    out[side] = {k: v for k, v in merged.items() if v}
os.makedirs(os.path.dirname(seed_p), exist_ok=True)
with open(seed_p, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False, sort_keys=True, indent=1)
    f.write("\n")
npos = sum(len(v) for v in out["positive"].values())
nneg = sum(len(v) for v in out["negative"].values())
print(f"Seed now: {npos} positive + {nneg} keep words.")
PY

cd "$ROOT"
if git diff --quiet -- "$SEED" 2>/dev/null && git ls-files --error-unmatch "$SEED" >/dev/null 2>&1; then
  echo "✓ Seed already up to date — nothing new to sync."
  exit 0
fi
git add "$SEED"
git commit -q -m "Update learned-words seed from local training"
echo "✓ Committed learned-words seed."
if [ "$PUSH" = "yes" ]; then
  echo "▸ Pushing to GitHub…"
  git push origin HEAD
  echo "✓ On GitHub. On another machine: git pull && ./install.sh"
else
  echo "Skipped push (--no-push). Run: git push origin HEAD"
fi
