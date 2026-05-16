#!/usr/bin/env python3
"""B8 doc_type normalization experiment harness.

Drives Minerva MCP HTTP (port 9315) to A/B/C the scansort `doc_type_strategy`
field across models, with full Minerva lifecycle management.

Cell = one process() invocation (all 6 docs, single model+strategy+rep).
Ledger row = one (cell, doc) outcome.

Modes:
    --sanity                    Run 1 cell (gemma4:26b, enum, rep 0) for CONFER 1.
    --pilot                     Pilot sweep: 3 strategies x 2 reps on gemma4:26b.
    --validate <strategy>       Validation sweep on qwen2.5vl:7b for chosen strategy.
    --report                    Generate report.md from ledger.jsonl.
    --reset                     Wipe ledger.jsonl (with confirmation).
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any, Optional
from urllib import request as urlrequest
from urllib.error import HTTPError, URLError

# ---------------------------------------------------------------------------
# Config (kept inline for one-file harness; promote to argparse later if needed)
# ---------------------------------------------------------------------------

HERE = Path(__file__).resolve().parent
MINERVA_SRC = Path.home() / "github" / "Minerva" / "src"
GODOT_BIN = "godot"
MCP_PORT = 9315
MCP_URL = f"http://localhost:{MCP_PORT}/"

FIXTURES_DIR = Path.home() / "temp" / "scansort-fixtures"
STAGING_DIR = Path.home() / "temp" / "scansort-staging"
VAULT_PATH = Path.home() / "temp" / "b8-exp.ssort"
VAULT_LABEL = "test"          # also used as destination label (copy_to in rules)
SOURCE_LABEL = "src"

LEDGER_PATH = HERE / "ledger.jsonl"
RULES_DIR = HERE / "rules"

# Cold-start (LLM warmup + per-doc inference) needs generous headroom.
# 7 docs × ~30-60s per doc on cold model = 4-7 min realistic; pad to 12 min.
COLD_START_TIMEOUT_S = 720.0
WARM_TIMEOUT_S = 360.0

# Models (Core service action names; routed via model_spec=core_action)
MODEL_PILOT = "gemma4:26b"
MODEL_VALIDATE = "qwen2.5vl:7b"

STRATEGIES = ["both"]  # iter2: enum + canonicalize already characterized — focus on winner
REPS_PILOT = 2
REPS_VALIDATE = 2

# Fixtures live in FIXTURES_DIR (above) and are NOT checked into the repo.
# Each operator provides their own mix of positives (matching tax/utility/boat
# rules) plus at least one negative the rules don't cover.


# ---------------------------------------------------------------------------
# MCP HTTP client
# ---------------------------------------------------------------------------


class MCPError(RuntimeError):
    """Raised when an MCP call returns an error envelope or transport fails."""


class MCPClient:
    """Minimal MCP HTTP/JSON-RPC client with session handling.

    Lifecycle: __init__ → initialize() → call() repeatedly → close().
    `call(tool, args, timeout_s)` returns the unwrapped result dict.
    """

    def __init__(self, url: str = MCP_URL) -> None:
        self.url = url
        self.session_id: Optional[str] = None
        self.protocol_version: Optional[str] = None
        self._next_id = 1

    def _next(self) -> int:
        n = self._next_id
        self._next_id += 1
        return n

    def _post(
        self, payload: dict, timeout_s: float, expect_json: bool = True
    ) -> tuple[dict, dict]:
        body = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.session_id:
            headers["MCP-Session-Id"] = self.session_id
        if self.protocol_version:
            headers["MCP-Protocol-Version"] = self.protocol_version
        req = urlrequest.Request(self.url, data=body, headers=headers, method="POST")
        try:
            with urlrequest.urlopen(req, timeout=timeout_s) as resp:
                text = resp.read().decode("utf-8")
                resp_headers = dict(resp.headers)
        except HTTPError as e:
            text = e.read().decode("utf-8", errors="replace")
            raise MCPError(f"HTTP {e.code}: {text[:500]}") from e
        except URLError as e:
            raise MCPError(f"Transport error: {e}") from e
        if not expect_json or not text:
            return {}, resp_headers
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError as e:
            raise MCPError(f"Bad JSON: {e}\nBody: {text[:500]}") from e
        return parsed, resp_headers

    def initialize(self, timeout_s: float = 10.0) -> None:
        payload = {
            "jsonrpc": "2.0",
            "id": self._next(),
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-03-26",
                "clientInfo": {"name": "b8-harness", "version": "0.1"},
                "capabilities": {},
            },
        }
        resp, headers = self._post(payload, timeout_s)
        # Session-Id header is the source of truth per MCP spec.
        sid = headers.get("MCP-Session-Id") or headers.get("Mcp-Session-Id")
        if not sid:
            raise MCPError(f"initialize: no MCP-Session-Id header. headers={list(headers)}")
        self.session_id = sid
        self.protocol_version = (
            headers.get("MCP-Protocol-Version")
            or headers.get("Mcp-Protocol-Version")
            or resp.get("result", {}).get("protocolVersion")
        )
        # notifications/initialized handshake
        init_done = {
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": {},
        }
        self._post(init_done, timeout_s, expect_json=False)

    def call(self, tool: str, args: dict, timeout_s: float = WARM_TIMEOUT_S) -> dict:
        payload = {
            "jsonrpc": "2.0",
            "id": self._next(),
            "method": "tools/call",
            "params": {"name": tool, "arguments": args},
        }
        resp, _ = self._post(payload, timeout_s)
        if "error" in resp:
            raise MCPError(f"{tool}: {resp['error']}")
        result = resp.get("result", {})
        # MCP stdio envelope: result.content[0].text contains JSON-encoded payload.
        content = result.get("content")
        parsed = result
        if isinstance(content, list) and content:
            first = content[0]
            if isinstance(first, dict) and first.get("type") == "text":
                txt = first.get("text", "")
                if txt:
                    try:
                        parsed = json.loads(txt)
                    except json.JSONDecodeError:
                        parsed = {"_raw_text": txt}
        # Surface plugin/broker error envelopes (success:false) as exceptions so
        # the harness fails fast rather than silently writing empty ledger rows.
        if isinstance(parsed, dict) and parsed.get("success") is False:
            code = parsed.get("error_code", "?")
            msg = parsed.get("error_message", parsed.get("error", "?"))
            raise MCPError(f"{tool}: [{code}] {msg}")
        return parsed


# ---------------------------------------------------------------------------
# Minerva lifecycle
# ---------------------------------------------------------------------------


class Minerva:
    def __init__(self, src: Path = MINERVA_SRC) -> None:
        self.src = src
        self.proc: Optional[subprocess.Popen] = None

    def start(self, wait_s: int = 10, port_probe_timeout_s: int = 60) -> None:
        if self.is_port_open():
            raise RuntimeError(
                f"Port {MCP_PORT} already in use — another Minerva is running. "
                "Stop it first or set --no-manage-minerva."
            )
        print(f"[lifecycle] launching godot --path {self.src}")
        self.proc = subprocess.Popen(
            [GODOT_BIN, "--path", str(self.src)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            preexec_fn=os.setsid,  # so we can kill the process group
        )
        print(f"[lifecycle] PID={self.proc.pid}, waiting {wait_s}s then probing port")
        time.sleep(wait_s)
        # Probe until port is up or timeout
        deadline = time.time() + port_probe_timeout_s
        while time.time() < deadline:
            if self.is_port_open():
                print(f"[lifecycle] port {MCP_PORT} open after {wait_s}s + poll")
                return
            time.sleep(1.0)
        # Failed
        self.stop()
        raise RuntimeError(f"Minerva failed to bind port {MCP_PORT} within {port_probe_timeout_s}s")

    @staticmethod
    def is_port_open(host: str = "127.0.0.1", port: int = MCP_PORT) -> bool:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            try:
                return s.connect_ex((host, port)) == 0
            except OSError:
                return False

    def stop(self, grace_s: int = 5) -> None:
        if self.proc is None:
            return
        pid = self.proc.pid
        print(f"[lifecycle] stopping PID={pid}")
        try:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
        except ProcessLookupError:
            self.proc = None
            return
        try:
            self.proc.wait(timeout=grace_s)
        except subprocess.TimeoutExpired:
            print(f"[lifecycle] SIGTERM grace expired, SIGKILL")
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.proc = None
        # Wait for port release so a fast restart can re-bind.
        deadline = time.time() + 5.0
        while time.time() < deadline and self.is_port_open():
            time.sleep(0.5)


# ---------------------------------------------------------------------------
# Ledger
# ---------------------------------------------------------------------------


@dataclass
class LedgerRow:
    cell_id: str            # "<model>|<strategy>|<rep>"
    model: str
    strategy: str
    rep: int
    doc_filename: str
    status: str             # moved | unprocessable | error
    rule_label: Optional[str]
    raw_doc_type: Optional[str] = None       # what the LLM produced (for canonicalize we lose this — see notes)
    final_doc_type: Optional[str] = None     # what process() ended up using
    display_name: Optional[str] = None
    issuer: Optional[str] = None
    doc_date: Optional[str] = None
    confidence: Optional[float] = None
    reason: Optional[str] = None             # for unprocessable
    error: Optional[str] = None              # for harness-level errors
    elapsed_s: Optional[float] = None
    ts: str = field(default_factory=lambda: time.strftime("%Y-%m-%dT%H:%M:%S"))


class Ledger:
    def __init__(self, path: Path = LEDGER_PATH) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def seen_cells(self) -> set[str]:
        if not self.path.exists():
            return set()
        seen = set()
        with self.path.open() as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                    seen.add(row.get("cell_id", ""))
                except json.JSONDecodeError:
                    pass
        return seen

    def append(self, row: LedgerRow) -> None:
        with self.path.open("a") as f:
            f.write(json.dumps(asdict(row)) + "\n")


# ---------------------------------------------------------------------------
# Cell runner
# ---------------------------------------------------------------------------


def restore_staging() -> None:
    """rsync-equivalent: wipe staging and copy fixtures back."""
    if STAGING_DIR.exists():
        shutil.rmtree(STAGING_DIR)
    STAGING_DIR.mkdir(parents=True, exist_ok=True)
    for src in FIXTURES_DIR.glob("*.pdf"):
        dst = STAGING_DIR / src.name
        shutil.copy2(src, dst)
        # Restore writability — fixtures are r-x; process() may need to delete on move.
        dst.chmod(0o644)


def load_rules() -> list[dict]:
    rules = []
    for p in sorted(RULES_DIR.glob("*.json")):
        rules.append(json.loads(p.read_text()))
    return rules


def reset_session_and_library(mcp: MCPClient) -> None:
    """Idempotent reset: close all open session entries + delete known rules."""
    state = mcp.call("minerva_scansort_session_state", {})
    for v in state.get("vaults", []):
        try:
            mcp.call("minerva_scansort_session_close_vault", {"label": v["label"]})
        except MCPError as e:
            print(f"  (close_vault {v['label']}): {e}")
    for d in state.get("dirs", []):
        try:
            mcp.call("minerva_scansort_session_close_directory", {"label": d["label"]})
        except MCPError as e:
            print(f"  (close_dir {d['label']}): {e}")
    for s in state.get("sources", []):
        try:
            mcp.call("minerva_scansort_session_close_source", {"label": s["label"]})
        except MCPError as e:
            print(f"  (close_src {s['label']}): {e}")
    # Clear all library rules so each cell starts fresh
    rules = mcp.call("minerva_scansort_library_list_rules", {})
    for r in rules.get("rules", []):
        try:
            mcp.call("minerva_scansort_library_delete_rule", {"label": r["label"]})
        except MCPError as e:
            print(f"  (delete_rule {r.get('label')}): {e}")


def setup_cell(mcp: MCPClient) -> None:
    """Pre-process setup: vault, source, destination, rules."""
    # 1. Restore staging
    restore_staging()
    # 2. Wipe + recreate vault
    if VAULT_PATH.exists():
        VAULT_PATH.unlink()
    mcp.call(
        "minerva_scansort_create_vault",
        {"path": str(VAULT_PATH), "name": "b8-experiment"},
    )
    # 3. Open vault into session under VAULT_LABEL
    mcp.call(
        "minerva_scansort_session_open_vault",
        {"label": VAULT_LABEL, "path": str(VAULT_PATH)},
    )
    # 4. ALSO open vault path as a directory destination, so the rule's
    #    copy_to: ["test"] resolves. (Per the path-free model: destinations
    #    are label-addressed, and the rule references the same label as the vault.)
    #    NOTE: session_open_directory expects a directory, not a file. The actual
    #    vault-as-destination wiring is handled internally by the open_vault call
    #    and the registry. If duplication errors, fall back to no-op.
    # 5. Open source
    mcp.call(
        "minerva_scansort_session_open_source",
        {"label": SOURCE_LABEL, "path": str(STAGING_DIR)},
    )
    # 6. Apply rules from rules/ dir
    for rule in load_rules():
        mcp.call("minerva_scansort_library_insert_rule", rule)


def run_process(mcp: MCPClient, model: str, strategy: str, timeout_s: float) -> dict:
    args = {
        "model": model,
        "model_spec": {
            "kind": "core_action",
            "service_client_id": "model-chat",
            "action_name": model,
        },
        "doc_type_strategy": strategy,
    }
    return mcp.call("minerva_scansort_process", args, timeout_s=timeout_s)


def fetch_vault_docs(mcp: MCPClient) -> list[dict]:
    """Returns the full inventory of the vault as a list of doc dicts."""
    r = mcp.call("minerva_scansort_vault_inventory", {"vault_path": str(VAULT_PATH)})
    return r.get("documents") or r.get("inventory") or []


def run_cell(
    mcp: MCPClient,
    model: str,
    strategy: str,
    rep: int,
    ledger: Ledger,
    cold_start: bool,
) -> None:
    cell_id = f"{model}|{strategy}|{rep}"
    print(f"\n=== cell {cell_id} (cold_start={cold_start}) ===")
    t0 = time.time()

    try:
        reset_session_and_library(mcp)
        setup_cell(mcp)
    except MCPError as e:
        ledger.append(LedgerRow(
            cell_id=cell_id, model=model, strategy=strategy, rep=rep,
            doc_filename="<setup>", status="error", rule_label=None,
            error=f"setup_error: {e}",
        ))
        print(f"  SETUP ERROR: {e}")
        return

    timeout = COLD_START_TIMEOUT_S if cold_start else WARM_TIMEOUT_S
    try:
        result = run_process(mcp, model, strategy, timeout_s=timeout)
    except MCPError as e:
        ledger.append(LedgerRow(
            cell_id=cell_id, model=model, strategy=strategy, rep=rep,
            doc_filename="<process>", status="error", rule_label=None,
            error=f"process_error: {e}",
        ))
        print(f"  PROCESS ERROR: {e}")
        return

    elapsed = time.time() - t0
    print(f"  process() done in {elapsed:.1f}s — summary={result.get('summary')}")

    # Fetch vault to read display_name / final doc_type for moved docs
    try:
        vault_docs = fetch_vault_docs(mcp)
    except MCPError as e:
        print(f"  WARNING: vault inventory failed: {e}")
        vault_docs = []
    by_source_name = {}
    for d in vault_docs:
        orig = d.get("original_filename", "")
        by_source_name[orig] = d

    # Walk process result items — one ledger row per source doc
    items = result.get("items", [])
    for item in items:
        rel = item.get("source_path_relative", "")
        doc_filename = rel.split("/")[-1] if rel else "<unknown>"
        vault_doc = by_source_name.get(doc_filename) or {}
        row = LedgerRow(
            cell_id=cell_id,
            model=model,
            strategy=strategy,
            rep=rep,
            doc_filename=doc_filename,
            status=item.get("status", ""),
            rule_label=item.get("rule_label"),
            final_doc_type=vault_doc.get("category") if vault_doc else None,
            display_name=vault_doc.get("display_name") if vault_doc else None,
            issuer=vault_doc.get("issuer") if vault_doc else None,
            doc_date=vault_doc.get("doc_date") if vault_doc else None,
            confidence=vault_doc.get("confidence") if vault_doc else None,
            reason=item.get("reason"),
            elapsed_s=elapsed,
        )
        # Note: doc_type comes through as `category` in vault inventory for the
        # vault destination, and as a separate top-level field for the rule
        # subfolder pattern. For the rename_pattern we care about the resolved
        # display_name (which is what {doc_type} expanded to).
        # Capture the actual doc_type token if surfaced separately.
        if vault_doc.get("doc_type"):
            row.final_doc_type = vault_doc.get("doc_type")
        ledger.append(row)
        print(f"  [{doc_filename[:40]:40}] status={row.status} rule={row.rule_label} display={row.display_name}")


# ---------------------------------------------------------------------------
# Sweeps
# ---------------------------------------------------------------------------


def sweep_sanity(mcp: MCPClient, ledger: Ledger) -> None:
    """1 cell: pilot model, first strategy, rep 0 — for CONFER 1."""
    print("\n--- SWEEP: sanity (1 cell) ---")
    cold = True
    for strategy in [STRATEGIES[0]]:
        for rep in [0]:
            cell_id = f"{MODEL_PILOT}|{strategy}|{rep}"
            if cell_id in ledger.seen_cells():
                print(f"skip already-recorded {cell_id}")
                continue
            run_cell(mcp, MODEL_PILOT, strategy, rep, ledger, cold_start=cold)
            cold = False


def sweep_pilot(mcp: MCPClient, ledger: Ledger) -> None:
    """6 cells: gemma4:26b × {enum, canonicalize, both} × 2 reps."""
    print("\n--- SWEEP: pilot (6 cells, ~36 min) ---")
    cold = True
    seen = ledger.seen_cells()
    for strategy in STRATEGIES:
        for rep in range(REPS_PILOT):
            cell_id = f"{MODEL_PILOT}|{strategy}|{rep}"
            if cell_id in seen:
                print(f"skip already-recorded {cell_id}")
                continue
            run_cell(mcp, MODEL_PILOT, strategy, rep, ledger, cold_start=cold)
            cold = False


def sweep_validate(mcp: MCPClient, ledger: Ledger, strategy: str) -> None:
    """2 cells: qwen2.5vl:7b × <strategy> × 2 reps."""
    print(f"\n--- SWEEP: validate ({strategy}, 2 cells, ~6 min) ---")
    cold = True
    seen = ledger.seen_cells()
    for rep in range(REPS_VALIDATE):
        cell_id = f"{MODEL_VALIDATE}|{strategy}|{rep}"
        if cell_id in seen:
            print(f"skip already-recorded {cell_id}")
            continue
        run_cell(mcp, MODEL_VALIDATE, strategy, rep, ledger, cold_start=cold)
        cold = False


# ---------------------------------------------------------------------------
# Report generation
# ---------------------------------------------------------------------------


def generate_report(ledger_path: Path = LEDGER_PATH, out: Path = HERE / "report.md") -> None:
    if not ledger_path.exists():
        print(f"No ledger at {ledger_path}")
        return
    rows = []
    for line in ledger_path.open():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    print(f"Loaded {len(rows)} rows")

    # Group by (model, strategy, doc_filename) → list of display_names across reps
    from collections import defaultdict
    by_key: dict[tuple, list[str]] = defaultdict(list)
    for r in rows:
        key = (r["model"], r["strategy"], r["doc_filename"])
        by_key[key].append(r.get("display_name") or "")

    lines = ["# B8 doc_type strategy comparison\n"]
    lines.append(f"Source: `{ledger_path.name}` ({len(rows)} rows)\n")

    # Per-strategy stability table
    lines.append("## Per-(model, strategy, doc) stability across reps\n")
    lines.append("| model | strategy | doc | reps | unique display_names | stable? |")
    lines.append("|---|---|---|---|---|---|")
    for (model, strategy, doc), names in sorted(by_key.items()):
        uniq = sorted(set(names))
        stable = "✓" if len(uniq) == 1 else f"✗ ({len(uniq)} distinct)"
        lines.append(f"| {model} | {strategy} | `{doc[:40]}` | {len(names)} | {' / '.join(repr(n)[:40] for n in uniq)} | {stable} |")

    # Cross-model stability per strategy (for shared docs)
    lines.append("\n## Cross-model display_name comparison per (strategy, doc)\n")
    by_strategy_doc: dict[tuple, dict[str, list[str]]] = defaultdict(lambda: defaultdict(list))
    for r in rows:
        by_strategy_doc[(r["strategy"], r["doc_filename"])][r["model"]].append(r.get("display_name") or "")
    lines.append("| strategy | doc | models | per-model display_names | cross-model stable? |")
    lines.append("|---|---|---|---|---|")
    for (strategy, doc), by_model in sorted(by_strategy_doc.items()):
        if len(by_model) < 2:
            continue  # only compare when we have multi-model coverage
        per_model_summary = []
        all_names = []
        for m, names in sorted(by_model.items()):
            uniq = sorted(set(names))
            per_model_summary.append(f"{m}: {' / '.join(repr(n)[:30] for n in uniq)}")
            all_names.extend(names)
        stable = "✓" if len(set(all_names)) == 1 else f"✗ ({len(set(all_names))} distinct)"
        lines.append(f"| {strategy} | `{doc[:40]}` | {len(by_model)} | {' ; '.join(per_model_summary)} | {stable} |")

    out.write_text("\n".join(lines) + "\n")
    print(f"Wrote {out}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--sanity", action="store_true", help="1 cell for CONFER 1")
    g.add_argument("--pilot", action="store_true", help="Pilot sweep (gemma4:26b)")
    g.add_argument("--validate", metavar="STRATEGY", help="Validation sweep with qwen2.5vl:7b for the winning strategy")
    g.add_argument("--report", action="store_true", help="Generate report.md from ledger")
    g.add_argument("--reset", action="store_true", help="Wipe ledger.jsonl")
    p.add_argument("--no-manage-minerva", action="store_true",
                   help="Assume Minerva is already running (skip start/stop)")
    args = p.parse_args()

    if args.report:
        generate_report()
        return 0

    if args.reset:
        if LEDGER_PATH.exists():
            confirm = input(f"Delete {LEDGER_PATH}? [y/N] ").strip().lower()
            if confirm == "y":
                LEDGER_PATH.unlink()
                print("Ledger wiped.")
        return 0

    # Validation requires a strategy from STRATEGIES
    if args.validate and args.validate not in STRATEGIES + ["none"]:
        print(f"--validate STRATEGY must be one of {STRATEGIES}")
        return 1

    ledger = Ledger()
    minerva = None if args.no_manage_minerva else Minerva()
    try:
        if minerva:
            minerva.start()
        mcp = MCPClient()
        mcp.initialize()

        # Plugin must be explicitly started — install/load is not enough.
        # See docket-hint minerva-plugins:plugin_must_be_started_for_tool_calls.
        try:
            mcp.call("minerva_plugin_start", {"id": "scansort"})
            print("[setup] scansort plugin started")
        except MCPError as e:
            # May already be running; query state and continue.
            print(f"[setup] plugin_start: {e} (may already be running)")

        if args.sanity:
            sweep_sanity(mcp, ledger)
        elif args.pilot:
            sweep_pilot(mcp, ledger)
        elif args.validate:
            sweep_validate(mcp, ledger, args.validate)
    finally:
        if minerva:
            minerva.stop()

    print(f"\nDone. Ledger: {LEDGER_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
