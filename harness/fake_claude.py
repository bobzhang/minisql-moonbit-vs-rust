#!/usr/bin/env python3
"""Zero-cost stand-in for `claude -p` used to test the orchestrator.
Rust workspaces get an engine that shells out to SQLite (so tests pass and the
compliance check must flag it); other workspaces are left unchanged."""
import json, os, sys, uuid
HERE = os.path.dirname(os.path.abspath(__file__))
sid = sys.argv[sys.argv.index("--resume") + 1] if "--resume" in sys.argv else str(uuid.uuid4())
emit = lambda d: print(json.dumps(d), flush=True)
emit({"type": "system", "subtype": "init", "session_id": sid, "tools": ["Bash"]})
if os.path.exists("Cargo.toml"):
    open("src/main.rs", "w").write(f'''mod io;
fn main() {{
    let input = io::read_stdin();
    let mut cmd = std::process::Command::new("python3");
    cmd.arg("{HERE}/fake_engine.py").args(io::args());
    cmd.stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped());
    let mut child = cmd.spawn().unwrap();
    use std::io::Write;
    child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    io::write_stdout(&String::from_utf8_lossy(&out.stdout));
    io::flush_stdout();
}}
''')
usage = {"input_tokens": 10, "cache_creation_input_tokens": 1000, "cache_read_input_tokens": 5000, "output_tokens": 300}
emit({"type": "assistant", "message": {"id": "m1", "usage": usage, "content": [
    {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "cargo build --release"}}]}})
emit({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1",
    "content": "error[E0425]: cannot find value `x`"}]}})
emit({"type": "result", "subtype": "success", "is_error": False, "result": "done", "session_id": sid,
      "num_turns": 2, "duration_ms": 1000, "duration_api_ms": 900, "total_cost_usd": 0.01, "usage": usage})
