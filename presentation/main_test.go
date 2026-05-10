// Tests for the host capability client and the first migrated tool.
//
// These exercise the synchronous call/correlate logic with mocked stdio
// rather than spawning a real Minerva process.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"testing"
)

// newMockClient returns a hostClient wired up with synthetic stdin/stdout.
// The caller can write pre-canned response lines into stdinW (via the
// returned io.Writer) and read what the plugin emits from stdout.
func newMockClient(stdin io.Reader, stdout io.Writer) *hostClient {
	scanner := bufio.NewScanner(stdin)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)
	enc := json.NewEncoder(stdout)
	return newHostClient(enc, scanner)
}


func TestCallCapability_HappyPath(t *testing.T) {
	// Pre-canned response: cap-1 succeeded with documents list.
	canned := `{"jsonrpc":"2.0","id":"cap-1","result":{"success":true,"result":{"documents":[{"editor_name":"deck.mdeck","kind":"plugin_scene","plugin_id":"presentation","path":"/tmp/deck.mdeck","panel_name":"slide_editor_panel"}]}}}` + "\n"

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	result, capErr := client.callCapability("host.documents.list_open", map[string]interface{}{})
	if capErr != nil {
		t.Fatalf("expected nil error, got %+v", capErr)
	}

	// Verify the request that went out was correctly shaped.
	out := stdout.String()
	if !strings.Contains(out, `"method":"minerva/capability"`) {
		t.Errorf("expected method=minerva/capability in stdout, got: %s", out)
	}
	if !strings.Contains(out, `"id":"cap-1"`) {
		t.Errorf("expected id=cap-1 in stdout, got: %s", out)
	}
	if !strings.Contains(out, `"capability":"host.documents.list_open"`) {
		t.Errorf("expected capability in params, got: %s", out)
	}

	// Verify the result payload was returned intact.
	if !strings.Contains(string(result), `"deck.mdeck"`) {
		t.Errorf("expected deck.mdeck in result, got: %s", string(result))
	}
}

func TestCallCapability_RpcError(t *testing.T) {
	// Pre-canned response: cap-1 failed with a JSON-RPC level error.
	canned := `{"jsonrpc":"2.0","id":"cap-1","error":{"code":-32603,"message":"broker unavailable"}}` + "\n"

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	_, capErr := client.callCapability("host.documents.list_open", map[string]interface{}{})
	if capErr == nil {
		t.Fatal("expected non-nil error")
	}
	if capErr.Code != -32603 {
		t.Errorf("expected code -32603, got %d", capErr.Code)
	}
	if !strings.Contains(capErr.Message, "broker unavailable") {
		t.Errorf("expected error message to contain 'broker unavailable', got: %s", capErr.Message)
	}
}

func TestCallCapability_StdinClosed(t *testing.T) {
	// Empty stdin → scanner.Scan() returns false immediately.
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	_, capErr := client.callCapability("host.documents.list_open", map[string]interface{}{})
	if capErr == nil {
		t.Fatal("expected error on stdin EOF")
	}
	if !strings.Contains(capErr.Message, "stdin closed") {
		t.Errorf("expected stdin-closed message, got: %s", capErr.Message)
	}
}

func TestCallCapability_SkipsUnexpectedIDs(t *testing.T) {
	// First line has unexpected id, second has the matching one. Plugin
	// must skip the first and resume reading.
	canned := `{"jsonrpc":"2.0","id":"unexpected","result":{"foo":"bar"}}` + "\n" +
		`{"jsonrpc":"2.0","id":"cap-1","result":{"success":true,"result":{}}}` + "\n"

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	_, capErr := client.callCapability("host.echo", map[string]interface{}{})
	if capErr != nil {
		t.Fatalf("expected nil error after skipping unexpected id, got %+v", capErr)
	}
}

func TestCallCapability_IDIncrementsAcrossCalls(t *testing.T) {
	// Two responses queued; verify each call sends its own id and reads the
	// matching response in order.
	canned := `{"jsonrpc":"2.0","id":"cap-1","result":{"first":true}}` + "\n" +
		`{"jsonrpc":"2.0","id":"cap-2","result":{"second":true}}` + "\n"

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	if _, err := client.callCapability("host.echo", map[string]interface{}{}); err != nil {
		t.Fatalf("first call: %+v", err)
	}
	if _, err := client.callCapability("host.echo", map[string]interface{}{}); err != nil {
		t.Fatalf("second call: %+v", err)
	}

	out := stdout.String()
	if !strings.Contains(out, `"id":"cap-1"`) || !strings.Contains(out, `"id":"cap-2"`) {
		t.Errorf("expected both cap-1 and cap-2 ids in stdout, got: %s", out)
	}
}


func TestToolListOpenDecks_FiltersByPluginId(t *testing.T) {
	// Mixed list: one plugin-scene presentation deck, one .mdeck text editor,
	// one unrelated text editor. Tool must return only the first two.
	canned := `{"jsonrpc":"2.0","id":"cap-1","result":{"success":true,"result":{"documents":[` +
		`{"editor_name":"deck1.mdeck","kind":"plugin_scene","plugin_id":"presentation","path":"/tmp/deck1.mdeck","panel_name":"slide_editor_panel"},` +
		`{"editor_name":"legacy.mdeck","kind":"text_editor","plugin_id":null,"path":"/tmp/legacy.mdeck","panel_name":null},` +
		`{"editor_name":"notes.txt","kind":"text_editor","plugin_id":null,"path":"/tmp/notes.txt","panel_name":null}` +
		`]}}}` + "\n"

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	out := toolListOpenDecks(client, nil)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success=true, got %+v", out)
	}
	count, _ := out["count"].(int)
	if count != 2 {
		t.Errorf("expected count=2 (deck1 + legacy), got %d", count)
	}
	decks, ok := out["decks"].([]map[string]interface{})
	if !ok {
		t.Fatalf("expected decks slice, got %T", out["decks"])
	}
	foundPluginScene := false
	foundLegacy := false
	for _, d := range decks {
		if d["plugin_id"] == "presentation" {
			foundPluginScene = true
		}
		if name, _ := d["editor_name"].(string); name == "legacy.mdeck" {
			foundLegacy = true
		}
	}
	if !foundPluginScene {
		t.Errorf("expected plugin-scene deck in result, got: %+v", decks)
	}
	if !foundLegacy {
		t.Errorf("expected legacy .mdeck text editor in result, got: %+v", decks)
	}
}

func TestToolListOpenDecks_PropagatesCapabilityError(t *testing.T) {
	// Broker returns success=false (e.g. policy denied list_open).
	canned := `{"jsonrpc":"2.0","id":"cap-1","result":{"success":false,"error_code":"capability_not_granted","error_message":"Capability 'host.documents.list_open' not granted","plugin_id":"presentation","capability":"host.documents.list_open"}}` + "\n"

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	out := toolListOpenDecks(client, nil)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected success=false, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "capability_not_granted" {
		t.Errorf("expected capability_not_granted, got %s", code)
	}
}

func TestToolListOpenDecks_HandlesEmptyDocuments(t *testing.T) {
	canned := `{"jsonrpc":"2.0","id":"cap-1","result":{"success":true,"result":{"documents":[]}}}` + "\n"

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	out := toolListOpenDecks(client, nil)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success=true on empty list, got %+v", out)
	}
	if count, _ := out["count"].(int); count != 0 {
		t.Errorf("expected count=0, got %d", count)
	}
}
