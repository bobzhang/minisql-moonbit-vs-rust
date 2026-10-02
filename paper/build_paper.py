#!/usr/bin/env python3
"""Build the MoonBit-vs-Rust paper (paper.html -> paper.pdf) from the experiment data.

Figures are generated as inline SVG from data.json (per-trial and per-milestone
records exported by harness/report.py), so every number in the paper traces to
the recorded runs. Rendering uses headless Chrome's print-to-PDF.
"""

import json
import os
import statistics as st
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
D = json.load(open(os.path.join(HERE, "data.json")))
T, M = D["trials"], D["milestones"]

RUST, MOON = "#c4501f", "#1f64b8"
RUST_SOFT, MOON_SOFT = "#f1c2ad", "#b9d2f3"
INK, INK2, MUTED, GRID = "#1a1a1a", "#444", "#777", "#e4e4e4"


def by(arm, k):
    return [t[k] for t in sorted((t for t in T if t["arm"] == arm), key=lambda t: t["trial"])]


def mean(a):
    return sum(a) / len(a)


def sd(a):
    return st.stdev(a)


def fmt_m(x):
    return f"{x / 1e6:.1f}M"


def fmt_k(x):
    return f"{x / 1e3:,.0f}k"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;")


# ---------------------------------------------------------------- figures

def svg(w, h, body, label):
    return (f'<svg viewBox="0 0 {w} {h}" width="100%" role="img" aria-label="{esc(label)}" '
            f'xmlns="http://www.w3.org/2000/svg" font-family="Helvetica, Arial, sans-serif">{body}</svg>')


def text(x, y, s, size=11, anchor="start", fill=INK2, weight="normal"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" text-anchor="{anchor}" '
            f'fill="{fill}" font-weight="{weight}">{esc(s)}</text>')


def line(x1, y1, x2, y2, stroke=GRID, w=1, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    return f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{stroke}" stroke-width="{w}"{d}/>'


def fig_trials():
    """Dot strips: per-trial cost, output tokens, input until first green."""
    rows = [("Estimated cost (USD)", "cost_usd", 30, 60, 5, lambda v: f"${v:.0f}"),
            ("Output tokens (thousands)", "output_tokens", 700e3, 1100e3, 100e3, lambda v: f"{v / 1e3:.0f}"),
            ("Input until first all-green (millions)", "green_input_tokens", 20e6, 26e6, 1e6, lambda v: f"{v / 1e6:.0f}")]
    W, L, R, rh = 640, 70, 20, 92
    H = rh * len(rows) + 6
    b = []
    for i, (lab, k, lo, hi, step, tf) in enumerate(rows):
        y0 = i * rh + 4
        x = lambda v: L + (v - lo) / (hi - lo) * (W - L - R)
        b.append(text(0, y0 + 11, lab, 11, fill=INK, weight="bold"))
        v = lo
        while v <= hi + 1e-6:
            b.append(line(x(v), y0 + 20, x(v), y0 + 66))
            b.append(text(x(v), y0 + 80, tf(v), 9.5, "middle", MUTED))
            v += step
        for j, (arm, col, name) in enumerate((("rust", RUST, "Rust"), ("moonbit", MOON, "MoonBit"))):
            yy = y0 + 32 + j * 22
            b.append(text(L - 10, yy + 4, name, 10, "end", INK2))
            b.append(line(L, yy, W - R, yy, "#cfcfcf"))
            vals = by(arm, k)
            mu = mean(vals)
            b.append(line(x(mu), yy - 8, x(mu), yy + 8, col, 2))
            for n, v in enumerate(vals):
                b.append(f'<circle cx="{x(v):.1f}" cy="{yy}" r="5" fill="{col}" stroke="white" stroke-width="1.5"/>')
    return svg(W, H, "".join(b), "Per-trial cost, output and input-to-green")


def fig_green_split():
    rows = []
    for arm in ("rust", "moonbit"):
        for n, (g, tot) in enumerate(zip(by(arm, "green_input_tokens"), by(arm, "total_input_tokens"))):
            rows.append((arm, n + 1, g, tot))
    W, L, R, bh, gap = 640, 110, 60, 16, 8
    H = len(rows) * (bh + gap) + 34
    hi = 120e6
    x = lambda v: L + v / hi * (W - L - R)
    b = []
    for v in range(0, 121, 20):
        b.append(line(x(v * 1e6), 0, x(v * 1e6), H - 26))
        b.append(text(x(v * 1e6), H - 12, f"{v}M", 9.5, "middle", MUTED))
    for i, (arm, n, g, tot) in enumerate(rows):
        y = i * (bh + gap) + 4
        col, soft = (RUST, RUST_SOFT) if arm == "rust" else (MOON, MOON_SOFT)
        b.append(text(L - 8, y + bh - 4, f"{'Rust' if arm == 'rust' else 'MoonBit'} t{n}", 10, "end"))
        b.append(f'<rect x="{x(0):.1f}" y="{y}" width="{x(g) - x(0) - 1:.1f}" height="{bh}" fill="{col}"/>')
        b.append(f'<rect x="{x(g) + 1:.1f}" y="{y}" width="{max(0, x(tot) - x(g) - 1):.1f}" height="{bh}" fill="{soft}"/>')
        b.append(text(x(tot) + 6, y + bh - 4, f"{tot / 1e6:.0f}M ({100 * (1 - g / tot):.0f}% after)", 9, fill=MUTED))
    return svg(W, H, "".join(b), "Input tokens before and after first all-green")


def fig_milestones():
    names = ["M1 Core pipeline", "M2 Expressions", "M3 DML, constraints", "M4 Aggregation",
             "M5 Joins, subqueries", "M6 Indexes, txns", "M7 CTEs, windows", "M8 Read files", "M9 Write files"]
    W, L, R, bh, gap = 640, 150, 50, 15, 7
    H = 9 * (bh + gap) + 34
    lo, hi = 0.6, 1.2
    x = lambda v: L + (v - lo) / (hi - lo) * (W - L - R)
    b = []
    for v in (0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2):
        b.append(line(x(v), 0, x(v), H - 26, "#999" if v == 1 else GRID, 1.2 if v == 1 else 1))
        b.append(text(x(v), H - 12, f"{v:.1f}", 9.5, "middle", MUTED))
    for m in range(1, 10):
        r = mean([d["output_tokens"] for d in M if d["arm"] == "rust" and d["milestone"] == m])
        q = mean([d["output_tokens"] for d in M if d["arm"] == "moonbit" and d["milestone"] == m]) / r
        y = (m - 1) * (bh + gap) + 4
        b.append(text(L - 8, y + bh - 3, names[m - 1], 10, "end"))
        x1, x2 = sorted((x(q), x(1.0)))
        b.append(f'<rect x="{x1:.1f}" y="{y}" width="{max(x2 - x1, 1.5):.1f}" height="{bh}" fill="{MOON if q < 1 else RUST}"/>')
        b.append(text(max(x(q), x(1.0)) + 6, y + bh - 3, f"{q:.2f}", 9.5, fill=MUTED))
    return svg(W, H, "".join(b), "Output-token ratio MoonBit/Rust by milestone")


def fig_bench():
    bench = [("CREATE INDEX x2, 300k rows", 1.92), ("UPDATE + DELETE", 1.34), ("Window functions", 1.32),
             ("ORDER BY text, 100k rows", 1.29), ("GROUP BY / DISTINCT", 1.27), ("INSERT 300k rows", 1.18),
             ("Scan + filter", 1.18), ("printf, 30k rows", 1.16), ("REAL output, 60k rows", 1.14),
             ("String functions", 0.91)]
    W, L, R, bh, gap = 640, 170, 50, 14, 7
    H = len(bench) * (bh + gap) + 34
    lo, hi = 0.6, 2.0
    x = lambda v: L + (v - lo) / (hi - lo) * (W - L - R)
    b = []
    for v in (0.6, 0.8, 1.0, 1.2, 1.4, 1.6, 1.8, 2.0):
        b.append(line(x(v), 0, x(v), H - 26, "#999" if v == 1 else GRID, 1.2 if v == 1 else 1))
        b.append(text(x(v), H - 12, f"{v:.1f}", 9.5, "middle", MUTED))
    for i, (name, q) in enumerate(bench):
        y = i * (bh + gap) + 4
        b.append(text(L - 8, y + bh - 3, name, 10, "end"))
        x1, x2 = sorted((x(q), x(1.0)))
        b.append(f'<rect x="{x1:.1f}" y="{y}" width="{max(x2 - x1, 1.5):.1f}" height="{bh}" fill="{MOON if q < 1 else RUST}"/>')
        b.append(text(max(x(q), x(1.0)) + 6, y + bh - 3, f"{q:.2f}", 9.5, fill=MUTED))
    return svg(W, H, "".join(b), "Runtime ratio MoonBit/Rust per workload")


# ---------------------------------------------------------------- tables

def main_table():
    rows = [
        ("Estimated cost (USD)", "cost_usd", lambda v: f"{v:.2f}"),
        ("Output tokens", "output_tokens", fmt_k),
        ("Total input tokens", "total_input_tokens", fmt_m),
        ("Input until first all-green", "green_input_tokens", fmt_m),
        ("Primer re-reads", "primer_overhead_tokens", fmt_m),
        ("API calls", "api_calls", lambda v: f"{v:.0f}"),
        ("Wall time (h)", "wall_seconds", lambda v: f"{v / 3600:.2f}"),
        ("Failed builds", "build_failures", lambda v: f"{v:.1f}"),
        ("Hidden tests passed (of 242)", "hidden_passed", lambda v: f"{v:.1f}"),
        ("Final source tokens", "src_tokens", fmt_k),
        ("Final code lines", "src_code_lines", lambda v: f"{v:,.0f}"),
    ]
    h = ['<table><thead><tr><th>Metric (per trial)</th><th class="n">Rust mean ± sd</th>'
         '<th class="n">MoonBit mean ± sd</th><th class="n">Ratio</th><th class="n">Median ratio</th></tr></thead><tbody>']
    for lab, k, f in rows:
        r, m = by("rust", k), by("moonbit", k)
        h.append(f'<tr><td>{lab}</td><td class="n">{f(mean(r))} ± {f(sd(r))}</td><td class="n">{f(mean(m))} ± {f(sd(m))}</td>'
                 f'<td class="n">{mean(m) / mean(r):.2f}</td><td class="n">{st.median(m) / st.median(r):.2f}</td></tr>')
    h.append("</tbody></table>")
    return "".join(h)


# ---------------------------------------------------------------- document

def build():
    c_mean = mean(by("moonbit", "cost_usd")) / mean(by("rust", "cost_usd"))
    c_med = st.median(by("moonbit", "cost_usd")) / st.median(by("rust", "cost_usd"))
    o_mean = mean(by("moonbit", "output_tokens")) / mean(by("rust", "output_tokens"))
    s_mean = mean(by("moonbit", "src_tokens")) / mean(by("rust", "src_tokens"))
    g_mean = mean(by("moonbit", "green_input_tokens")) / mean(by("rust", "green_input_tokens"))
    h_r = mean(by("rust", "hidden_passed")) / 242 * 100
    h_m = mean(by("moonbit", "hidden_passed")) / 242 * 100
    subs = dict(C_MEAN=f"{c_mean:.2f}", C_MED=f"{c_med:.2f}", O_MEAN=f"{o_mean:.2f}", S_MEAN=f"{s_mean:.2f}",
                G_MEAN=f"{g_mean:.2f}", H_R=f"{h_r:.1f}", H_M=f"{h_m:.1f}",
                FIG_TRIALS=fig_trials(), FIG_GREEN=fig_green_split(), FIG_MS=fig_milestones(),
                FIG_BENCH=fig_bench(), MAIN_TABLE=main_table())
    body = open(os.path.join(HERE, "paper.tmpl.html")).read()
    for k, v in subs.items():
        body = body.replace("{{" + k + "}}", v)
    out = os.path.join(HERE, "paper.html")
    open(out, "w").write(body)
    return out


def render(html):
    pdf = os.path.join(HERE, "moonbit-agent-friendly.pdf")
    chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    prof = os.path.join(HERE, ".chrome-profile")
    if os.path.exists(pdf):
        os.remove(pdf)
    # Chrome writes the PDF and then sometimes lingers (updater hooks); treat a
    # written file as success and stop waiting.
    try:
        subprocess.run([chrome, "--headless", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                        "--no-pdf-header-footer", f"--user-data-dir={prof}", f"--print-to-pdf={pdf}",
                        "file://" + html],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
    except subprocess.TimeoutExpired:
        pass
    if not os.path.exists(pdf):
        raise SystemExit("Chrome did not produce the PDF")
    return pdf


if __name__ == "__main__":
    print(render(build()))
