#!/usr/bin/env python3
"""Quick MCP smoke probe — start Minerva, do initialize + a few tool calls."""
import json
from harness import MCPClient, Minerva, VAULT_PATH, VAULT_LABEL, SOURCE_LABEL, STAGING_DIR, restore_staging, load_rules

m = Minerva()
m.start()
try:
    mcp = MCPClient()
    mcp.initialize()
    print(f"initialized, session={mcp.session_id}, protocol={mcp.protocol_version}")
    print()

    print(">>> session_state:")
    print(json.dumps(mcp.call("minerva_scansort_session_state", {}), indent=2))

    print("\n>>> library_list_rules:")
    print(json.dumps(mcp.call("minerva_scansort_library_list_rules", {}), indent=2))

    # Try creating vault
    if VAULT_PATH.exists():
        VAULT_PATH.unlink()
    print("\n>>> create_vault:")
    print(json.dumps(mcp.call(
        "minerva_scansort_create_vault",
        {"path": str(VAULT_PATH), "name": "probe"},
    ), indent=2))

    print("\n>>> session_open_vault:")
    print(json.dumps(mcp.call(
        "minerva_scansort_session_open_vault",
        {"label": VAULT_LABEL, "path": str(VAULT_PATH)},
    ), indent=2))

    restore_staging()
    print("\n>>> session_open_source:")
    print(json.dumps(mcp.call(
        "minerva_scansort_session_open_source",
        {"label": SOURCE_LABEL, "path": str(STAGING_DIR)},
    ), indent=2))

    print("\n>>> session_state (after setup):")
    print(json.dumps(mcp.call("minerva_scansort_session_state", {}), indent=2))

    # Add 1 rule
    rules = load_rules()
    print(f"\n>>> library_insert_rule (tax):")
    print(json.dumps(mcp.call("minerva_scansort_library_insert_rule", rules[0]), indent=2))

    print(f"\n>>> library_list_rules (after insert):")
    print(json.dumps(mcp.call("minerva_scansort_library_list_rules", {}), indent=2))

finally:
    m.stop()
