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
	"os"
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

// ---------------------------------------------------------------------------
// T6 R2 — read tool migration: validators + disk loader
// ---------------------------------------------------------------------------

func TestParseTargetArgs_RequiresOneTarget(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want string // empty == should succeed
	}{
		{"neither", `{}`, "Provide either"},
		{"both", `{"tab_name":"x","path":"/tmp/y.mdeck"}`, "mutually exclusive"},
		{"tab only", `{"tab_name":"deck.mdeck"}`, ""},
		{"path only", `{"path":"/tmp/y.mdeck"}`, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, fault := parseTargetArgs([]byte(tc.raw))
			if tc.want == "" {
				if fault != nil {
					t.Fatalf("expected nil fault, got %+v", fault)
				}
				return
			}
			if fault == nil {
				t.Fatalf("expected fault containing %q, got nil", tc.want)
			}
			if !strings.Contains(fault.Msg, tc.want) {
				t.Errorf("expected msg containing %q, got %q", tc.want, fault.Msg)
			}
		})
	}
}

func TestLoadDeckFromPath_HappyAndError(t *testing.T) {
	// Happy path: write a tiny valid deck to a temp file, then load.
	tmp := t.TempDir()
	deckPath := tmp + "/probe.mdeck"
	body := `{"version":1,"aspect":"16:9","slides":[{"id":"s1","title":"hi","tiles":[]}]}`
	if err := os.WriteFile(deckPath, []byte(body), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	deck, fault := loadDeckFromPath(deckPath)
	if fault != nil {
		t.Fatalf("happy: %+v", fault)
	}
	if aspect, _ := deck["aspect"].(string); aspect != "16:9" {
		t.Errorf("aspect mismatch: %v", deck["aspect"])
	}

	// Error: missing file → io_error.
	_, fault = loadDeckFromPath(tmp + "/no_such.mdeck")
	if fault == nil || fault.Code != "io_error" {
		t.Fatalf("missing file: expected io_error fault, got %+v", fault)
	}

	// Error: malformed JSON → parse_error.
	bad := tmp + "/bad.mdeck"
	if err := os.WriteFile(bad, []byte("not json {{{"), 0644); err != nil {
		t.Fatalf("bad setup: %v", err)
	}
	_, fault = loadDeckFromPath(bad)
	if fault == nil || fault.Code != "parse_error" {
		t.Fatalf("bad json: expected parse_error fault, got %+v", fault)
	}
}

func TestToolListSlides_FromPath(t *testing.T) {
	tmp := t.TempDir()
	deckPath := tmp + "/list.mdeck"
	body := `{"version":1,"aspect":"4:3","slides":[
		{"id":"s_a","title":"first","tiles":[{"id":"t1"}]},
		{"id":"s_b","tiles":[]}
	]}`
	if err := os.WriteFile(deckPath, []byte(body), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	// hostClient unused for path mode but must be non-nil.
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath})
	out := toolListSlides(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	if aspect, _ := out["aspect"].(string); aspect != "4:3" {
		t.Errorf("aspect propagation: got %v", out["aspect"])
	}
	slides, ok := out["slides"].([]map[string]interface{})
	if !ok {
		t.Fatalf("expected slides slice, got %T", out["slides"])
	}
	if len(slides) != 2 {
		t.Fatalf("expected 2 slides, got %d", len(slides))
	}
	if slides[0]["title"] != "first" {
		t.Errorf("first slide title: got %v", slides[0]["title"])
	}
	if _, has := slides[1]["title"]; has {
		t.Errorf("second slide should NOT have title (none in source): got %v", slides[1])
	}
}

func TestToolGetSlide_OutOfRange(t *testing.T) {
	tmp := t.TempDir()
	deckPath := tmp + "/oor.mdeck"
	if err := os.WriteFile(deckPath, []byte(`{"slides":[]}`), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath, "slide_index": 0})
	out := toolGetSlide(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure on empty deck, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "out_of_range" {
		t.Errorf("expected out_of_range code, got %q", code)
	}
}

func TestToolListAnnotationKinds_NoArgs(t *testing.T) {
	out := toolListAnnotationKinds(nil)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	kinds, ok := out["kinds"].([]map[string]interface{})
	if !ok {
		t.Fatalf("expected kinds slice")
	}
	if len(kinds) < 3 {
		t.Errorf("expected at least 3 kinds, got %d", len(kinds))
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

// ---------------------------------------------------------------------------
// Write-tool tests — path mode exercises mutateDeck end-to-end on disk.
// ---------------------------------------------------------------------------

func writeDeckFile(t *testing.T, body string) string {
	t.Helper()
	tmp := t.TempDir()
	p := tmp + "/deck.mdeck"
	if err := os.WriteFile(p, []byte(body), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	return p
}

func readDeckFile(t *testing.T, path string) map[string]interface{} {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("readback: %v", err)
	}
	var d map[string]interface{}
	if err := json.Unmarshal(body, &d); err != nil {
		t.Fatalf("readback parse: %v", err)
	}
	return d
}

func TestToolAddSlide_AppendsByDefault(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"aspect":"16:9","slides":[{"id":"s1"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath, "title": "two"})
	out := toolAddSlide(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	if idx, _ := out["slide_index"].(int); idx != 1 {
		t.Errorf("expected slide_index=1, got %v", out["slide_index"])
	}
	d := readDeckFile(t, deckPath)
	slides := d["slides"].([]interface{})
	if len(slides) != 2 {
		t.Fatalf("expected 2 slides, got %d", len(slides))
	}
	s1 := slides[1].(map[string]interface{})
	if s1["title"] != "two" {
		t.Errorf("expected title=two, got %v", s1["title"])
	}
}

func TestToolAddSlide_InsertAtPosition(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s0"},{"id":"s1"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath, "position": 1, "title": "middle"})
	out := toolAddSlide(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	d := readDeckFile(t, deckPath)
	slides := d["slides"].([]interface{})
	if len(slides) != 3 {
		t.Fatalf("expected 3 slides, got %d", len(slides))
	}
	if slides[0].(map[string]interface{})["id"] != "s0" {
		t.Errorf("first slide should still be s0")
	}
	if slides[1].(map[string]interface{})["title"] != "middle" {
		t.Errorf("middle slide title mismatch: %v", slides[1])
	}
	if slides[2].(map[string]interface{})["id"] != "s1" {
		t.Errorf("third slide should be original s1")
	}
}

func TestToolSetSlideTitle_SetAndClear(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","title":"old"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	// Set
	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath, "slide_index": 0, "title": "new"})
	out := toolSetSlideTitle(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("set: expected success, got %+v", out)
	}
	if title := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["title"]; title != "new" {
		t.Errorf("expected title=new, got %v", title)
	}

	// Clear
	rawArgs, _ = json.Marshal(map[string]interface{}{"path": deckPath, "slide_index": 0, "title": ""})
	out = toolSetSlideTitle(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("clear: expected success, got %+v", out)
	}
	if _, has := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["title"]; has {
		t.Errorf("title should have been erased")
	}
}

func TestToolSetSlideTitle_RequiresTitleArg(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath, "slide_index": 0})
	out := toolSetSlideTitle(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure when title omitted, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "schema_validation_failed" {
		t.Errorf("expected schema_validation_failed, got %q", code)
	}
}

func TestToolSetAspect_AcceptsValidRejectsInvalid(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"aspect":"16:9","slides":[{"id":"s1"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath, "aspect": "4:3"})
	out := toolSetAspect(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("valid aspect: expected success, got %+v", out)
	}
	if a := readDeckFile(t, deckPath)["aspect"]; a != "4:3" {
		t.Errorf("expected aspect=4:3, got %v", a)
	}

	rawArgs, _ = json.Marshal(map[string]interface{}{"path": deckPath, "aspect": "21:9"})
	out = toolSetAspect(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("invalid aspect: expected failure, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "schema_validation_failed" {
		t.Errorf("expected schema_validation_failed, got %q", code)
	}
}

func TestToolMoveSlide_HappyAndNoOpAndRange(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"a"},{"id":"b"},{"id":"c"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	// happy: move first to last
	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath, "from_index": 0, "to_index": 2})
	out := toolMoveSlide(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("move: expected success, got %+v", out)
	}
	slides := readDeckFile(t, deckPath)["slides"].([]interface{})
	got := []string{
		slides[0].(map[string]interface{})["id"].(string),
		slides[1].(map[string]interface{})["id"].(string),
		slides[2].(map[string]interface{})["id"].(string),
	}
	if got[0] != "b" || got[1] != "c" || got[2] != "a" {
		t.Errorf("expected order [b,c,a], got %v", got)
	}

	// no-op
	rawArgs, _ = json.Marshal(map[string]interface{}{"path": deckPath, "from_index": 1, "to_index": 1})
	out = toolMoveSlide(client, rawArgs)
	if noOp, _ := out["no_op"].(bool); !noOp {
		t.Errorf("expected no_op=true, got %+v", out)
	}

	// out of range
	rawArgs, _ = json.Marshal(map[string]interface{}{"path": deckPath, "from_index": 99, "to_index": 0})
	out = toolMoveSlide(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("out of range: expected failure, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "out_of_range" {
		t.Errorf("expected out_of_range, got %q", code)
	}
}

func TestToolRemoveSlide_RefusesLastSlide(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"only"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath, "slide_index": 0})
	out := toolRemoveSlide(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure removing only slide, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "deck_empty_forbidden" {
		t.Errorf("expected deck_empty_forbidden, got %q", code)
	}
}

func TestToolAddSpreadsheetTile_DefaultsToEmptyGrid(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0,
		"x": 0.0, "y": 0.0, "w": 0.5, "h": 0.5,
		"rows": 2, "cols": 3,
	})
	out := toolAddSpreadsheetTile(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	tile := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})[0].(map[string]interface{})
	if tile["kind"] != "spreadsheet" {
		t.Errorf("expected kind=spreadsheet, got %v", tile["kind"])
	}
	cells := tile["cells"].([]interface{})
	if len(cells) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(cells))
	}
	row0 := cells[0].([]interface{})
	if len(row0) != 3 {
		t.Fatalf("expected 3 cols, got %d", len(row0))
	}
	c00 := row0[0].(map[string]interface{})
	if c00["value"] != "" || int(c00["type"].(float64)) != 0 {
		t.Errorf("expected empty cell, got %v", c00)
	}
}

func TestToolAddSpreadsheetTile_AcceptsCallerCells(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0,
		"x": 0.0, "y": 0.0, "w": 0.5, "h": 0.5,
		"rows": 1, "cols": 2,
		"cells": [][]interface{}{
			{"hello", 42},
		},
	})
	out := toolAddSpreadsheetTile(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	tile := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})[0].(map[string]interface{})
	row0 := tile["cells"].([]interface{})[0].([]interface{})
	c0 := row0[0].(map[string]interface{})
	c1 := row0[1].(map[string]interface{})
	if c0["value"] != "hello" || int(c0["type"].(float64)) != 1 {
		t.Errorf("auto-typed string: got %v", c0)
	}
	if c1["value"] != float64(42) || int(c1["type"].(float64)) != 2 {
		t.Errorf("auto-typed number: got %v", c1)
	}
}

func TestToolAddSpreadsheetTile_RowMismatch(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0,
		"x": 0.0, "y": 0.0, "w": 0.5, "h": 0.5,
		"rows": 2, "cols": 2,
		"cells": [][]interface{}{{"a", "b"}}, // 1 row, but rows=2
	})
	out := toolAddSpreadsheetTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure on row count mismatch, got %+v", out)
	}
}

func TestToolModifySpreadsheetCells_PatchesAndSkips(t *testing.T) {
	body := `{"version":1,"slides":[{"id":"s1","tiles":[
		{"id":"t1","kind":"spreadsheet","rows":2,"cols":2,"cells":[
			[{"value":"a","type":1},{"value":"b","type":1}],
			[{"value":"c","type":1},{"value":"d","type":1}]
		]}
	]}]}`
	deckPath := writeDeckFile(t, body)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0, "tile_id": "t1",
		"cells": []map[string]interface{}{
			{"row": 0, "col": 0, "value": "X", "type": 1},
			{"row": 5, "col": 5, "value": "OOB"}, // out of bounds
			{"row": 1, "col": 1, "bold": true},
		},
	})
	out := toolModifySpreadsheetCells(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	if up, _ := out["cells_updated"].(int); up != 2 {
		t.Errorf("expected cells_updated=2, got %v", out["cells_updated"])
	}
	skipped, _ := out["skipped"].([]interface{})
	if len(skipped) != 1 {
		t.Errorf("expected 1 skipped, got %v", out["skipped"])
	}
	cells := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})[0].(map[string]interface{})["cells"].([]interface{})
	c00 := cells[0].([]interface{})[0].(map[string]interface{})
	if c00["value"] != "X" {
		t.Errorf("expected (0,0).value=X, got %v", c00["value"])
	}
	c11 := cells[1].([]interface{})[1].(map[string]interface{})
	if c11["bold"] != true {
		t.Errorf("expected (1,1).bold=true, got %v", c11)
	}
}

func TestToolResizeSpreadsheet_GrowAndShrink(t *testing.T) {
	body := `{"version":1,"slides":[{"id":"s1","tiles":[
		{"id":"t1","kind":"spreadsheet","rows":2,"cols":2,"cells":[
			[{"value":"a","type":1},{"value":"b","type":1}],
			[{"value":"c","type":1},{"value":"d","type":1}]
		]}
	]}]}`
	deckPath := writeDeckFile(t, body)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	// grow to 3x3
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0, "tile_id": "t1",
		"rows": 3, "cols": 3,
	})
	out := toolResizeSpreadsheet(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("grow: expected success, got %+v", out)
	}
	tile := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})[0].(map[string]interface{})
	if int(tile["rows"].(float64)) != 3 || int(tile["cols"].(float64)) != 3 {
		t.Errorf("expected 3x3, got %vx%v", tile["rows"], tile["cols"])
	}
	cells := tile["cells"].([]interface{})
	if cells[0].([]interface{})[0].(map[string]interface{})["value"] != "a" {
		t.Errorf("preserve: expected (0,0)=a, got %v", cells[0])
	}
	if cells[2].([]interface{})[2].(map[string]interface{})["value"] != "" {
		t.Errorf("new cell should be empty, got %v", cells[2])
	}

	// shrink to 1x1
	rawArgs, _ = json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0, "tile_id": "t1",
		"rows": 1, "cols": 1,
	})
	out = toolResizeSpreadsheet(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("shrink: expected success, got %+v", out)
	}
	tile = readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})[0].(map[string]interface{})
	if int(tile["rows"].(float64)) != 1 || int(tile["cols"].(float64)) != 1 {
		t.Errorf("expected 1x1, got %vx%v", tile["rows"], tile["cols"])
	}
}

func TestToolResizeSpreadsheet_RejectsNonSpreadsheet(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[{"id":"t1","kind":"text"}]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0, "tile_id": "t1",
		"rows": 2, "cols": 2,
	})
	out := toolResizeSpreadsheet(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure on non-spreadsheet tile, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "kind_mismatch" {
		t.Errorf("expected kind_mismatch, got %q", code)
	}
}

func TestToolAddTextTile_HappyPath(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0,
		"x": 0.1, "y": 0.1, "w": 0.5, "h": 0.3,
		"content": "hello world", "text_mode": "bullet", "font_size": 24,
	})
	out := toolAddTextTile(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	if id, _ := out["tile_id"].(string); !strings.HasPrefix(id, "tile_") {
		t.Errorf("expected tile_ prefix, got %q", id)
	}
	tiles := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})
	if len(tiles) != 1 {
		t.Fatalf("expected 1 tile, got %d", len(tiles))
	}
	tile := tiles[0].(map[string]interface{})
	if tile["kind"] != "text" {
		t.Errorf("expected kind=text, got %v", tile["kind"])
	}
	if tile["text_mode"] != "bullet" {
		t.Errorf("expected text_mode=bullet, got %v", tile["text_mode"])
	}
	if tile["content"] != "hello world" {
		t.Errorf("expected content=hello world, got %v", tile["content"])
	}
	// font_size round-trips through JSON as float64; check numerically.
	if fs, _ := tile["font_size"].(float64); fs != 24 {
		t.Errorf("expected font_size=24, got %v", tile["font_size"])
	}
}

func TestToolAddTextTile_RejectsBadCoords(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0,
		"x": 0.5, "y": 0.5, "w": 0.8, "h": 0.3, "content": "x",
	})
	out := toolAddTextTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected coord overflow failure, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "schema_validation_failed" {
		t.Errorf("expected schema_validation_failed, got %q", code)
	}
}

func TestToolAddTextTile_RejectsBadTextMode(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0,
		"x": 0.0, "y": 0.0, "w": 0.5, "h": 0.5,
		"content": "x", "text_mode": "fancy",
	})
	out := toolAddTextTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected text_mode failure, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "schema_validation_failed" {
		t.Errorf("expected schema_validation_failed, got %q", code)
	}
}

func TestToolAddTextTile_RejectsBadFontSize(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0,
		"x": 0.0, "y": 0.0, "w": 0.5, "h": 0.5,
		"content": "x", "font_size": 500,
	})
	out := toolAddTextTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected font_size failure, got %+v", out)
	}
}

func TestToolRemoveTile_HappyAndScrubs(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[{"id":"t_a"},{"id":"t_b"}],"reveal":["t_a","t_b"]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0, "tile_id": "t_a",
	})
	out := toolRemoveTile(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	if removed, _ := out["removed_at"].(int); removed != 0 {
		t.Errorf("expected removed_at=0, got %v", out["removed_at"])
	}
	slide := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})
	tiles := slide["tiles"].([]interface{})
	if len(tiles) != 1 || tiles[0].(map[string]interface{})["id"] != "t_b" {
		t.Errorf("expected only t_b remaining, got %v", tiles)
	}
	reveal := slide["reveal"].([]interface{})
	if len(reveal) != 1 || reveal[0] != "t_b" {
		t.Errorf("expected reveal=[t_b], got %v", reveal)
	}
}

func TestToolRemoveTile_NotFound(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[{"id":"t_a"}]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0, "tile_id": "missing",
	})
	out := toolRemoveTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "tile_not_found" {
		t.Errorf("expected tile_not_found, got %q", code)
	}
}

func TestToolRemoveSlide_HappyPath(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"a"},{"id":"b"},{"id":"c"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath, "slide_index": 1})
	out := toolRemoveSlide(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	if id, _ := out["slide_id"].(string); id != "b" {
		t.Errorf("expected removed id=b, got %q", id)
	}
	if rem, _ := out["remaining_slides"].(int); rem != 2 {
		t.Errorf("expected remaining_slides=2, got %v", out["remaining_slides"])
	}
	slides := readDeckFile(t, deckPath)["slides"].([]interface{})
	if len(slides) != 2 {
		t.Fatalf("expected 2 slides on disk, got %d", len(slides))
	}
	if slides[0].(map[string]interface{})["id"] != "a" || slides[1].(map[string]interface{})["id"] != "c" {
		t.Errorf("expected order [a,c], got %v", slides)
	}
}
