#!/usr/bin/env python3
"""Count tokens of source files with the experiment model's own tokenizer.

Each file is sent once through headless `claude -p` with a tiny system prompt
and no tools; its token count is the input-token total minus a baseline
measured the same way on empty content (per-file noise is about ±3 tokens). Results are cached by content
hash, so re-counting a milestone snapshot only costs the files that changed.

Usage: count_tokens.py FILE...   (prints "<tokens>\t<path>" per file)
"""

from __future__ import annotations

import concurrent.futures as cf
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = json.load(open(os.path.join(HERE, "config.json")))
CACHE_PATH = os.path.join(os.path.expanduser(CONFIG["runs_dir"]), "token_cache.json")
_lock = threading.Lock()


def _load_cache() -> dict:
    try:
        with open(CACHE_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_cache(cache: dict) -> None:
    os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
    tmp = CACHE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cache, f)
    os.replace(tmp, CACHE_PATH)


def _wrap(text: str) -> str:
    # A fixed envelope keeps the CLI from treating content that starts with
    # "/" as a slash command, which changes the per-request overhead.
    return "<file>\n" + text + "\n</file>"


def _measure(text: str, model: str) -> int:
    text = _wrap(text)
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run(
            ["claude", "-p", "--model", model, "--output-format", "json",
             "--system-prompt", "Reply with the single character K.",
             "--tools", "", "--disable-slash-commands", "--strict-mcp-config",
             "--setting-sources", "project", "--settings", '{"autoMemoryEnabled":false}',
             "--no-session-persistence"],
            input=text.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=d, env={**os.environ, "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"}, timeout=600,
        )
    if r.returncode != 0:
        raise RuntimeError(f"claude failed: {r.stderr.decode()[-500:]}")
    u = json.loads(r.stdout)["usage"]
    return u["input_tokens"] + u["cache_creation_input_tokens"] + u["cache_read_input_tokens"]


def count_texts(texts: list[str], model: str | None = None, jobs: int = 4) -> list[int]:
    model = model or CONFIG["model"]
    cache = _load_cache()
    base_key = f"v2:{model}:baseline"
    if base_key not in cache:
        cache[base_key] = min(_measure("", model) for _ in range(3))
        _save_cache(cache)
    baseline = cache[base_key]

    keys = [f"v2:{model}:{hashlib.sha256(t.encode()).hexdigest()}" for t in texts]
    todo = {k: t for k, t in zip(keys, texts) if k not in cache and t.strip()}

    def work(item):
        k, t = item
        n = _measure(t, model) - baseline
        with _lock:
            cache[k] = n
        return n

    if todo:
        with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
            list(ex.map(work, todo.items()))
        with _lock:
            _save_cache(cache)
    return [cache.get(k, 0) for k in keys]


def main() -> int:
    paths = sys.argv[1:]
    texts = [open(p, encoding="utf-8", errors="replace").read() for p in paths]
    for p, n in zip(paths, count_texts(texts)):
        print(f"{n}\t{p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
