#!/usr/bin/env python3
"""Time extract_text on each fixture PDF — find which one hangs/slows."""
import time
from pathlib import Path
from harness import MCPClient, Minerva, FIXTURES_DIR, MCPError

m = Minerva()
m.start()
try:
    mcp = MCPClient()
    mcp.initialize()
    mcp.call("minerva_plugin_start", {"id": "scansort"})

    pdfs = sorted(FIXTURES_DIR.glob("*.pdf"))
    for pdf in pdfs:
        print(f"\n>>> {pdf.name} ({pdf.stat().st_size // 1024} KB)")
        t0 = time.time()
        try:
            r = mcp.call(
                "minerva_scansort_extract_text",
                {"file_path": str(pdf)},
                timeout_s=180.0,
            )
            dt = time.time() - t0
            chars = r.get("char_count", 0)
            pages = r.get("page_count", 0)
            print(f"    {dt:.1f}s  pages={pages}  chars={chars}")
        except MCPError as e:
            dt = time.time() - t0
            print(f"    FAIL after {dt:.1f}s: {e}")
        except Exception as e:
            dt = time.time() - t0
            print(f"    EXCEPTION after {dt:.1f}s: {type(e).__name__}: {e}")
finally:
    m.stop()
