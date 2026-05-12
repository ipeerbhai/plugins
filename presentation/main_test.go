// Tests for the host capability client and the first migrated tool.
//
// These exercise the synchronous call/correlate logic with mocked stdio
// rather than spawning a real Minerva process.
package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
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

func TestToolSetSlideBackground_Color(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0, "color": "A07A4A",
	})
	out := toolSetSlideBackground(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	bg := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["background"].(map[string]interface{})
	if bg["kind"] != "color" {
		t.Errorf("expected kind=color, got %v", bg["kind"])
	}
	if bg["value"] != "#A07A4A" {
		t.Errorf("expected hash-prefixed hex, got %v", bg["value"])
	}
}

func TestToolSetSlideBackground_ImagePath(t *testing.T) {
	tmp := t.TempDir()
	imgPath := tmp + "/bg.png"
	// PNG magic prefix so the sniffer picks "image/png".
	pngBytes := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0xff, 0xfe}
	if err := os.WriteFile(imgPath, pngBytes, 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0, "image_path": imgPath,
	})
	out := toolSetSlideBackground(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	bg := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["background"].(map[string]interface{})
	if bg["kind"] != "image" {
		t.Errorf("expected kind=image, got %v", bg["kind"])
	}
	// Phase-5 R3 adoption: bg.value is a blob envelope, not bare base64.
	env, ok := bg["value"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected bg.value to be a Dictionary (blob envelope), got %T: %v", bg["value"], bg["value"])
	}
	if flag, _ := env["__blob__"].(bool); !flag {
		t.Errorf("expected envelope __blob__=true, got %v", env["__blob__"])
	}
	if ct, _ := env["content_type"].(string); ct != "image/png" {
		t.Errorf("expected content_type=image/png (sniffed), got %q", ct)
	}
	if b, _ := env["bytes"].(string); b == "" {
		t.Errorf("expected non-empty base64 bytes, got %v", env["bytes"])
	}
}


// TestToolSetSlideBackground_ImageBase64 verifies the image_base64 input path
// also produces a blob envelope (phase-5 R3 plugin-side adoption).
func TestToolSetSlideBackground_ImageBase64(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)
	// base64 of {0xFF, 0xD8, 0xFF, 0xE0, 'A', 'B'} — JPEG magic prefix.
	jpegB64 := base64.StdEncoding.EncodeToString([]byte{0xFF, 0xD8, 0xFF, 0xE0, 'A', 'B'})

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0, "image_base64": jpegB64,
	})
	out := toolSetSlideBackground(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	bg := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["background"].(map[string]interface{})
	env, ok := bg["value"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected envelope shape, got %T", bg["value"])
	}
	if ct, _ := env["content_type"].(string); ct != "image/jpeg" {
		t.Errorf("expected content_type=image/jpeg (sniffed), got %q", ct)
	}
	if b, _ := env["bytes"].(string); b != jpegB64 {
		t.Errorf("expected bytes to round-trip base64, got %q", b)
	}
}


// TestSniffImageContentType exercises the magic-byte sniffer used by the
// background envelope writer. Mirrors slide_model.gd's sniff coverage.
func TestSniffImageContentType(t *testing.T) {
	cases := []struct {
		name string
		in   []byte
		want string
	}{
		{"png", []byte{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}, "image/png"},
		{"jpeg", []byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10}, "image/jpeg"},
		{"gif", []byte{0x47, 0x49, 0x46, 0x38, 0x39, 0x61}, "image/gif"},
		{"webp", []byte{0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50}, "image/webp"},
		{"empty falls back to png", []byte{}, "image/png"},
		{"garbage falls back to png", []byte{0x00, 0x00, 0x00, 0x00}, "image/png"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := sniffImageContentType(tc.in)
			if got != tc.want {
				t.Errorf("sniff(%q): got %q, want %q", tc.name, got, tc.want)
			}
		})
	}
}

func TestToolSetSlideBackground_RequiresExactlyOneSource(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1"}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	// none
	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath, "slide_index": 0})
	out := toolSetSlideBackground(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure when no source, got %+v", out)
	}

	// two
	rawArgs, _ = json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0,
		"color": "#fff", "image_base64": "abc",
	})
	out = toolSetSlideBackground(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure when two sources, got %+v", out)
	}
}

func TestToolCreateDeck_HappyPath(t *testing.T) {
	tmp := t.TempDir()
	deckPath := tmp + "/foo.mdeck"
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "title": "Hello",
	})
	out := toolCreateDeck(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	if p, _ := out["path"].(string); p != deckPath {
		t.Errorf("expected path %q, got %v", deckPath, out["path"])
	}
	if cnt, _ := out["slide_count"].(int); cnt != 1 {
		t.Errorf("expected slide_count=1, got %v", out["slide_count"])
	}
	d := readDeckFile(t, deckPath)
	if int(d["version"].(float64)) != 1 {
		t.Errorf("expected version=1, got %v", d["version"])
	}
	if d["aspect"] != "16:9" {
		t.Errorf("expected aspect=16:9, got %v", d["aspect"])
	}
	slide := d["slides"].([]interface{})[0].(map[string]interface{})
	if slide["title"] != "Hello" {
		t.Errorf("expected title=Hello, got %v", slide["title"])
	}
}

func TestToolCreateDeck_AppendsExtension(t *testing.T) {
	tmp := t.TempDir()
	rawArgs, _ := json.Marshal(map[string]interface{}{"path": tmp + "/no_ext"})
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)
	out := toolCreateDeck(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	if p, _ := out["path"].(string); !strings.HasSuffix(p, ".mdeck") {
		t.Errorf("expected .mdeck suffix, got %q", p)
	}
}

func TestToolCreateDeck_CreatesMissingParentDir(t *testing.T) {
	// Regression guard: GDScript _write_deck_to_disk called make_dir_recursive
	// before writing. Plugin must do the same — otherwise toolCreateDeck
	// to a path under a non-existent dir would fail with io_error.
	tmp := t.TempDir()
	nestedPath := tmp + "/a/b/c/deck.mdeck"
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": nestedPath})
	out := toolCreateDeck(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success when parent dir is missing, got %+v", out)
	}
	if _, err := os.Stat(nestedPath); err != nil {
		t.Errorf("deck file should exist at %s, got err: %v", nestedPath, err)
	}
}

func TestToolCreateDeck_RejectsBadAspect(t *testing.T) {
	tmp := t.TempDir()
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": tmp + "/d.mdeck", "aspect": "21:9",
	})
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)
	out := toolCreateDeck(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure, got %+v", out)
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

func TestToolModifySpreadsheetCells_BadTypeKeepsOtherFields(t *testing.T) {
	// Regression guard: GDScript _modify_spreadsheet_cells continues past a
	// bad `type` key — other keys in the same patch still apply, and the
	// cell still counts as updated. Go map iteration is non-deterministic,
	// so the fix must continue (not break) the inner key loop.
	body := `{"version":1,"slides":[{"id":"s1","tiles":[
		{"id":"t1","kind":"spreadsheet","rows":1,"cols":1,"cells":[
			[{"value":"old","type":1}]
		]}
	]}]}`
	deckPath := writeDeckFile(t, body)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0, "tile_id": "t1",
		"cells": []map[string]interface{}{
			{"row": 0, "col": 0, "value": "new", "type": 99, "bold": true},
		},
	})
	out := toolModifySpreadsheetCells(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	// Match GDScript: cell counts as updated even though type was bad.
	if up, _ := out["cells_updated"].(int); up != 1 {
		t.Errorf("expected cells_updated=1, got %v", out["cells_updated"])
	}
	skipped, _ := out["skipped"].([]interface{})
	if len(skipped) != 1 {
		t.Errorf("expected 1 skipped (the bad type), got %v", out["skipped"])
	}
	cell := readDeckFile(t, deckPath)["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})[0].(map[string]interface{})["cells"].([]interface{})[0].([]interface{})[0].(map[string]interface{})
	// value and bold should have applied; type should NOT have changed from 1.
	if cell["value"] != "new" {
		t.Errorf("expected value=new (applied despite bad type), got %v", cell["value"])
	}
	if cell["bold"] != true {
		t.Errorf("expected bold=true (applied despite bad type), got %v", cell["bold"])
	}
	if int(cell["type"].(float64)) != 1 {
		t.Errorf("expected type=1 (unchanged), got %v", cell["type"])
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

func TestToolAddTextTile_RejectsOutOfRangeCoord(t *testing.T) {
	deckPath := writeDeckFile(t, `{"version":1,"slides":[{"id":"s1","tiles":[]}]}`)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	// x outside [0,1] — what the GDScript original also rejects.
	// (Note: x+w > 1 is intentionally permitted — see validateCoords.)
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path": deckPath, "slide_index": 0,
		"x": 1.5, "y": 0.5, "w": 0.3, "h": 0.3, "content": "x",
	})
	out := toolAddTextTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected out-of-range coord failure, got %+v", out)
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

// ---------------------------------------------------------------------------
// Phase 5 R5 — hostClient helper tests: GetNode, GetBlob, PutBlob, Patch
// ---------------------------------------------------------------------------

// cannedCapResponse builds a single-line canned broker response for cap-N.
func cannedCapResponse(id, resultJSON string) string {
	return `{"jsonrpc":"2.0","id":"` + id + `","result":` + resultJSON + `}` + "\n"
}

// TestHostClient_GetNode_HappyPath_RootValue verifies that GetNode with path=""
// returns the broker's result value intact and found=true.
func TestHostClient_GetNode_HappyPath_RootValue(t *testing.T) {
	resultPayload := `{"success":true,"result":{"editor_name":"deck.mdeck","path":"","found":true,"value":{"aspect":"16:9","slides":[]}}}`
	canned := cannedCapResponse("cap-1", resultPayload)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	found, value, fault := client.GetNode("deck.mdeck", "")
	if fault != nil {
		t.Fatalf("expected nil fault, got %+v", fault)
	}
	if !found {
		t.Fatal("expected found=true")
	}
	m, ok := value.(map[string]interface{})
	if !ok {
		t.Fatalf("expected map value, got %T", value)
	}
	if aspect, _ := m["aspect"].(string); aspect != "16:9" {
		t.Errorf("expected aspect=16:9, got %v", m["aspect"])
	}

	// Verify the wire request named the right capability.
	if !strings.Contains(stdout.String(), `"capability":"host.documents.get_node"`) {
		t.Errorf("expected get_node capability in wire request, got: %s", stdout.String())
	}
}

// TestHostClient_GetNode_NotFound_IsNotError verifies that a not-found result
// returns found=false and no fault — it is a legitimate outcome, not an error.
func TestHostClient_GetNode_NotFound_IsNotError(t *testing.T) {
	resultPayload := `{"success":true,"result":{"editor_name":"deck.mdeck","path":"/slides/99","found":false,"value":null}}`
	canned := cannedCapResponse("cap-1", resultPayload)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	found, value, fault := client.GetNode("deck.mdeck", "/slides/99")
	if fault != nil {
		t.Fatalf("expected nil fault on not-found, got %+v", fault)
	}
	if found {
		t.Error("expected found=false")
	}
	if value != nil {
		t.Errorf("expected nil value on not-found, got %v", value)
	}
}

// TestHostClient_GetNode_PassesThroughBrokerErrorCode verifies that a broker
// error (success=false) surfaces the broker's error_code unchanged.
func TestHostClient_GetNode_PassesThroughBrokerErrorCode(t *testing.T) {
	resultPayload := `{"success":false,"error_code":"not_buffer_canonical","error_message":"editor is not buffer-canonical"}`
	canned := cannedCapResponse("cap-1", resultPayload)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	found, _, fault := client.GetNode("deck.mdeck", "/slides")
	if fault == nil {
		t.Fatal("expected fault, got nil")
	}
	if fault.Code != "not_buffer_canonical" {
		t.Errorf("expected error_code=not_buffer_canonical, got %q", fault.Code)
	}
	if found {
		t.Error("expected found=false on error path")
	}
}

// TestHostClient_GetBlob_HappyPath_RoundTripBytes verifies that GetBlob
// base64-decodes the broker's bytes_b64 field correctly.
func TestHostClient_GetBlob_HappyPath_RoundTripBytes(t *testing.T) {
	original := []byte("hello blob world")
	encoded := base64.StdEncoding.EncodeToString(original)
	resultPayload := `{"success":true,"result":{"editor_name":"deck.mdeck","blob_handle":"blob-7","content_type":"image/png","bytes_b64":"` + encoded + `"}}`
	canned := cannedCapResponse("cap-1", resultPayload)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	ct, data, fault := client.GetBlob("deck.mdeck", "blob-7")
	if fault != nil {
		t.Fatalf("expected nil fault, got %+v", fault)
	}
	if ct != "image/png" {
		t.Errorf("expected content_type=image/png, got %q", ct)
	}
	if !bytes.Equal(data, original) {
		t.Errorf("round-trip mismatch: got %q, want %q", data, original)
	}
}

// TestHostClient_GetBlob_PassesThroughBlobNotFound verifies that a broker
// blob_not_found error surfaces the code unchanged.
func TestHostClient_GetBlob_PassesThroughBlobNotFound(t *testing.T) {
	resultPayload := `{"success":false,"error_code":"blob_not_found","error_message":"no blob with handle blob-99"}`
	canned := cannedCapResponse("cap-1", resultPayload)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	ct, data, fault := client.GetBlob("deck.mdeck", "blob-99")
	if fault == nil {
		t.Fatal("expected fault, got nil")
	}
	if fault.Code != "blob_not_found" {
		t.Errorf("expected error_code=blob_not_found, got %q", fault.Code)
	}
	if ct != "" || data != nil {
		t.Errorf("expected empty ct and nil data on error, got ct=%q data=%v", ct, data)
	}
}

// TestHostClient_PutBlob_HappyPath_ReturnsHandle verifies that PutBlob
// returns the broker-assigned handle on success.
func TestHostClient_PutBlob_HappyPath_ReturnsHandle(t *testing.T) {
	resultPayload := `{"success":true,"result":{"editor_name":"deck.mdeck","blob_handle":"blob-42","content_type":"image/jpeg"}}`
	canned := cannedCapResponse("cap-1", resultPayload)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	handle, fault := client.PutBlob("deck.mdeck", "image/jpeg", []byte("fake jpeg data"))
	if fault != nil {
		t.Fatalf("expected nil fault, got %+v", fault)
	}
	if handle != "blob-42" {
		t.Errorf("expected handle=blob-42, got %q", handle)
	}
}

// TestHostClient_PutBlob_EncodesBytesAsBase64 verifies that the wire payload
// contains the base64 encoding of the input bytes (not raw bytes).
func TestHostClient_PutBlob_EncodesBytesAsBase64(t *testing.T) {
	rawBytes := []byte("binary\x00\x01\x02content")
	expectedB64 := base64.StdEncoding.EncodeToString(rawBytes)

	resultPayload := `{"success":true,"result":{"editor_name":"deck.mdeck","blob_handle":"blob-1","content_type":"application/octet-stream"}}`
	canned := cannedCapResponse("cap-1", resultPayload)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	_, fault := client.PutBlob("deck.mdeck", "application/octet-stream", rawBytes)
	if fault != nil {
		t.Fatalf("expected nil fault, got %+v", fault)
	}

	wireOut := stdout.String()
	if !strings.Contains(wireOut, expectedB64) {
		t.Errorf("wire payload missing expected base64 %q in: %s", expectedB64, wireOut)
	}
	if !strings.Contains(wireOut, `"capability":"host.documents.put_blob"`) {
		t.Errorf("expected put_blob capability in wire request, got: %s", wireOut)
	}
}

// TestPatchBuilder_ChainedAddRemove_DispatchesOnePatch verifies that chaining
// Add + Remove on a builder results in a single wire call carrying both ops,
// in order.
func TestPatchBuilder_ChainedAddRemove_DispatchesOnePatch(t *testing.T) {
	resultPayload := `{"success":true,"result":{"editor_name":"deck.mdeck","op_count":2,"applied_ops":2,"dirty":true}}`
	canned := cannedCapResponse("cap-1", resultPayload)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	opCount, fault := client.Patch("deck.mdeck").
		Add("/slides/-", map[string]interface{}{"id": "new-slide"}).
		Remove("/slides/0").
		Send()
	if fault != nil {
		t.Fatalf("expected nil fault, got %+v", fault)
	}
	if opCount != 2 {
		t.Errorf("expected opCount=2, got %d", opCount)
	}

	wireOut := stdout.String()
	// Only one wire call should have been made.
	if strings.Count(wireOut, `"method":"minerva/capability"`) != 1 {
		t.Errorf("expected exactly one wire call, got: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"capability":"host.documents.patch_state"`) {
		t.Errorf("expected patch_state capability, got: %s", wireOut)
	}

	// Both ops must appear, add before remove.
	addIdx := strings.Index(wireOut, `"op":"add"`)
	removeIdx := strings.Index(wireOut, `"op":"remove"`)
	if addIdx < 0 || removeIdx < 0 {
		t.Errorf("missing op entries in wire payload: %s", wireOut)
	}
	if addIdx > removeIdx {
		t.Errorf("expected add before remove in wire payload")
	}
}

// TestPatchBuilder_EmptySend_ReturnsEmptyPatchFault verifies the client-side
// fail-fast when Send is called with no ops accumulated.
func TestPatchBuilder_EmptySend_ReturnsEmptyPatchFault(t *testing.T) {
	// No canned response needed — Send must fail before any wire call.
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	opCount, fault := client.Patch("deck.mdeck").Send()
	if fault == nil {
		t.Fatal("expected fault on empty patch, got nil")
	}
	if fault.Code != "empty_patch" {
		t.Errorf("expected code=empty_patch, got %q", fault.Code)
	}
	if opCount != 0 {
		t.Errorf("expected opCount=0, got %d", opCount)
	}
	// No wire call should have been made.
	if stdout.Len() > 0 {
		t.Errorf("expected no wire output on empty-patch fail-fast, got: %s", stdout.String())
	}
}

// TestPatchBuilder_SecondSend_ReturnsAlreadySent (cold-review R5 follow-up):
// Send is documented as single-use. Verify a second .Send() on the same
// builder returns the "already_sent" fault and does NOT make a second wire
// call (which would double-dispatch the same patch — invisible to the broker
// but a real-world correctness hazard).
func TestPatchBuilder_SecondSend_ReturnsAlreadySent(t *testing.T) {
	// First Send: provide a canned success response so the builder transitions
	// to sent=true.
	resp := `{"jsonrpc":"2.0","id":"cap-1","result":{"success":true,"result":{"editor_name":"deck.mdeck","op_count":1,"applied_ops":1,"dirty":true}}}` + "\n"
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(resp), &stdout)

	builder := client.Patch("deck.mdeck").Add("/aspect", "16:9")
	opCount1, fault1 := builder.Send()
	if fault1 != nil {
		t.Fatalf("first Send unexpected fault: %+v", fault1)
	}
	if opCount1 != 1 {
		t.Errorf("first Send opCount: want 1, got %d", opCount1)
	}

	// Record stdout length so we can prove the second Send did NOT write.
	preSecondLen := stdout.Len()

	// Second Send must return already_sent without touching the wire.
	opCount2, fault2 := builder.Send()
	if fault2 == nil {
		t.Fatal("second Send: expected already_sent fault, got nil")
	}
	if fault2.Code != "already_sent" {
		t.Errorf("second Send: want code=already_sent, got %q", fault2.Code)
	}
	if opCount2 != 0 {
		t.Errorf("second Send: want opCount=0, got %d", opCount2)
	}
	if stdout.Len() != preSecondLen {
		t.Errorf("second Send wrote to wire (len delta = %d); should have short-circuited", stdout.Len()-preSecondLen)
	}
}

// TestPatchBuilder_PassesThroughPatchFailedFromBroker verifies that a broker
// patch_failed error surfaces the code unchanged.
func TestPatchBuilder_PassesThroughPatchFailedFromBroker(t *testing.T) {
	resultPayload := `{"success":false,"error_code":"patch_failed","error_message":"op 1: path /slides/99 not found"}`
	canned := cannedCapResponse("cap-1", resultPayload)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	opCount, fault := client.Patch("deck.mdeck").
		Replace("/slides/99/title", "Oops").
		Send()
	if fault == nil {
		t.Fatal("expected fault, got nil")
	}
	if fault.Code != "patch_failed" {
		t.Errorf("expected error_code=patch_failed, got %q", fault.Code)
	}
	if opCount != 0 {
		t.Errorf("expected opCount=0 on failure, got %d", opCount)
	}
}

// TestPatchBuilder_AllOpTypes_WireShape verifies that all six op constructors
// produce correctly-shaped ops in the wire payload.
func TestPatchBuilder_AllOpTypes_WireShape(t *testing.T) {
	resultPayload := `{"success":true,"result":{"editor_name":"deck.mdeck","op_count":6,"applied_ops":6,"dirty":true}}`
	canned := cannedCapResponse("cap-1", resultPayload)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)

	_, fault := client.Patch("deck.mdeck").
		Add("/a", "v1").
		Remove("/b").
		Replace("/c", "v2").
		Move("/d", "/e").
		Copy("/f", "/g").
		Test("/h", "v3").
		Send()
	if fault != nil {
		t.Fatalf("expected nil fault, got %+v", fault)
	}

	wireOut := stdout.String()
	for _, op := range []string{"add", "remove", "replace", "move", "copy", "test"} {
		if !strings.Contains(wireOut, `"op":"`+op+`"`) {
			t.Errorf("missing op %q in wire payload: %s", op, wireOut)
		}
	}
}

// ---------------------------------------------------------------------------
// Phase 5 R6 — tab_name path tests: verify tools use get_node / patch_state
// rather than get_state / set_state.
// ---------------------------------------------------------------------------

// cannedGetNodeSlides returns a canned broker response for get_node("/slides").
func cannedGetNodeSlides(id string, slides interface{}) string {
	payload, _ := json.Marshal(map[string]interface{}{
		"success": true,
		"result": map[string]interface{}{
			"editor_name": "deck.mdeck",
			"path":        "/slides",
			"found":       true,
			"value":       slides,
		},
	})
	return cannedCapResponse(id, string(payload))
}

// cannedGetNodeRoot returns a canned broker response for get_node("") (root).
func cannedGetNodeRoot(id string, root interface{}) string {
	payload, _ := json.Marshal(map[string]interface{}{
		"success": true,
		"result": map[string]interface{}{
			"editor_name": "deck.mdeck",
			"path":        "",
			"found":       true,
			"value":       root,
		},
	})
	return cannedCapResponse(id, string(payload))
}

// cannedGetNodePath returns a canned broker response for get_node(path).
func cannedGetNodePath(id, path string, found bool, value interface{}) string {
	payload, _ := json.Marshal(map[string]interface{}{
		"success": true,
		"result": map[string]interface{}{
			"editor_name": "deck.mdeck",
			"path":        path,
			"found":       found,
			"value":       value,
		},
	})
	return cannedCapResponse(id, string(payload))
}

// cannedPatchOK returns a canned broker success for patch_state.
func cannedPatchOK(id string, opCount int) string {
	payload, _ := json.Marshal(map[string]interface{}{
		"success": true,
		"result": map[string]interface{}{
			"editor_name": "deck.mdeck",
			"op_count":    opCount,
			"applied_ops": opCount,
			"dirty":       true,
		},
	})
	return cannedCapResponse(id, string(payload))
}

// TestToolListSlides_TabName_CallsGetNode verifies list_slides with tab_name
// calls host.documents.get_node at /slides (not get_state).
func TestToolListSlides_TabName_CallsGetNode(t *testing.T) {
	slides := []interface{}{
		map[string]interface{}{"id": "s1", "title": "First", "tiles": []interface{}{}},
		map[string]interface{}{"id": "s2", "tiles": []interface{}{"t1"}},
	}
	root := map[string]interface{}{"aspect": "4:3", "version": float64(1)}
	// Two sequential capability calls: cap-1 = /slides, cap-2 = root.
	canned := cannedGetNodeSlides("cap-1", slides) + cannedGetNodeRoot("cap-2", root)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck"})
	out := toolListSlides(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	// Must use get_node, NOT get_state.
	if strings.Contains(wireOut, `"capability":"host.documents.get_state"`) {
		t.Errorf("tab_name mode must NOT call get_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"capability":"host.documents.get_node"`) {
		t.Errorf("expected get_node capability in wire, got: %s", wireOut)
	}
	// /slides path must appear in one of the get_node calls.
	if !strings.Contains(wireOut, `"/slides"`) {
		t.Errorf("expected /slides path in wire, got: %s", wireOut)
	}
	// Aspect and version should propagate from root call.
	if aspect, _ := out["aspect"].(string); aspect != "4:3" {
		t.Errorf("expected aspect=4:3, got %v", out["aspect"])
	}
	// Tile count should be correct.
	summaries, ok := out["slides"].([]map[string]interface{})
	if !ok {
		t.Fatalf("expected slides slice, got %T", out["slides"])
	}
	if len(summaries) != 2 {
		t.Fatalf("expected 2 slides, got %d", len(summaries))
	}
	if summaries[0]["title"] != "First" {
		t.Errorf("expected first slide title=First, got %v", summaries[0]["title"])
	}
	if summaries[1]["tile_count"] != 1 {
		t.Errorf("expected second slide tile_count=1, got %v", summaries[1]["tile_count"])
	}
}

// TestToolGetSlide_TabName_CallsGetNode verifies get_slide with tab_name
// calls get_node at /slides/<i>, not get_state.
func TestToolGetSlide_TabName_CallsGetNode(t *testing.T) {
	slide := map[string]interface{}{"id": "s0", "title": "Intro", "tiles": []interface{}{}}
	canned := cannedGetNodePath("cap-1", "/slides/0", true, slide)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "slide_index": 0})
	out := toolGetSlide(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.get_state"`) {
		t.Errorf("tab_name mode must NOT call get_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"/slides/0"`) {
		t.Errorf("expected /slides/0 path in wire, got: %s", wireOut)
	}
	if s, _ := out["slide"].(map[string]interface{}); s["title"] != "Intro" {
		t.Errorf("expected slide title=Intro, got %v", out["slide"])
	}
}

// TestToolGetSlide_TabName_NotFound verifies that a not-found get_node for a
// slide index maps to out_of_range, not a protocol error.
func TestToolGetSlide_TabName_NotFound(t *testing.T) {
	canned := cannedGetNodePath("cap-1", "/slides/99", false, nil)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "slide_index": 99})
	out := toolGetSlide(client, rawArgs)

	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure on out-of-range, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "out_of_range" {
		t.Errorf("expected out_of_range, got %q", code)
	}
}

// TestToolGetTile_TabName_CallsGetNode verifies get_tile with tab_name
// calls get_node at /slides/<i>/tiles/<j>, not get_state.
func TestToolGetTile_TabName_CallsGetNode(t *testing.T) {
	tile := map[string]interface{}{"id": "t0", "kind": "text", "x": 0.1, "y": 0.1, "w": 0.5, "h": 0.3}
	canned := cannedGetNodePath("cap-1", "/slides/0/tiles/0", true, tile)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "slide_index": 0, "tile_index": 0})
	out := toolGetTile(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.get_state"`) {
		t.Errorf("tab_name mode must NOT call get_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"/slides/0/tiles/0"`) {
		t.Errorf("expected /slides/0/tiles/0 path in wire, got: %s", wireOut)
	}
}

// TestToolListTiles_TabName_CallsGetNode verifies list_tiles with tab_name
// calls get_node at /slides/<i>/tiles.
func TestToolListTiles_TabName_CallsGetNode(t *testing.T) {
	tiles := []interface{}{
		map[string]interface{}{"id": "t0", "kind": "text", "x": 0.1, "y": 0.1, "w": 0.5, "h": 0.3},
	}
	canned := cannedGetNodePath("cap-1", "/slides/0/tiles", true, tiles)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "slide_index": 0})
	out := toolListTiles(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.get_state"`) {
		t.Errorf("tab_name mode must NOT call get_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"/slides/0/tiles"`) {
		t.Errorf("expected /slides/0/tiles path in wire, got: %s", wireOut)
	}
}

// TestToolListAnnotations_TabName_CallsGetNode verifies list_annotations with
// tab_name calls get_node at /slides/<i>/annotations.
func TestToolListAnnotations_TabName_CallsGetNode(t *testing.T) {
	anns := []interface{}{
		map[string]interface{}{"id": "a1", "kind": "comment"},
	}
	canned := cannedGetNodePath("cap-1", "/slides/0/annotations", true, anns)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "slide_index": 0})
	out := toolListAnnotations(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if !strings.Contains(wireOut, `"/slides/0/annotations"`) {
		t.Errorf("expected /slides/0/annotations path in wire, got: %s", wireOut)
	}
}

// TestToolSetAspect_TabName_CallsPatchState verifies set_aspect with tab_name
// calls patch_state (not set_state) with a replace op on /aspect.
func TestToolSetAspect_TabName_CallsPatchState(t *testing.T) {
	canned := cannedPatchOK("cap-1", 1)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "aspect": "4:3"})
	out := toolSetAspect(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.set_state"`) {
		t.Errorf("tab_name mode must NOT call set_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"capability":"host.documents.patch_state"`) {
		t.Errorf("expected patch_state in wire, got: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"op":"replace"`) {
		t.Errorf("expected replace op in wire, got: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"/aspect"`) {
		t.Errorf("expected /aspect path in wire, got: %s", wireOut)
	}
}

// TestToolSetSlideTitle_TabName_CallsPatchState_Set verifies set_slide_title
// with tab_name uses patch_state with an add op (title → set).
func TestToolSetSlideTitle_TabName_CallsPatchState_Set(t *testing.T) {
	canned := cannedPatchOK("cap-1", 1)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "slide_index": 0, "title": "My Title"})
	out := toolSetSlideTitle(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.set_state"`) {
		t.Errorf("tab_name mode must NOT call set_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"capability":"host.documents.patch_state"`) {
		t.Errorf("expected patch_state in wire, got: %s", wireOut)
	}
}

// TestToolSetSlideTitle_TabName_CallsPatchState_Clear verifies set_slide_title
// with title="" issues a get_node (to validate slide exists) then a remove op.
func TestToolSetSlideTitle_TabName_CallsPatchState_Clear(t *testing.T) {
	slide := map[string]interface{}{"id": "s0", "title": "Old", "tiles": []interface{}{}}
	// cap-1 = get_node to verify slide, cap-2 = patch_state remove op.
	canned := cannedGetNodePath("cap-1", "/slides/0", true, slide) + cannedPatchOK("cap-2", 1)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "slide_index": 0, "title": ""})
	out := toolSetSlideTitle(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if !strings.Contains(wireOut, `"op":"remove"`) {
		t.Errorf("expected remove op for title clear, got: %s", wireOut)
	}
}

// TestToolAddSlide_TabName_CallsPatchState verifies add_slide with tab_name
// reads /slides count then calls patch_state with an add op.
func TestToolAddSlide_TabName_CallsPatchState(t *testing.T) {
	slides := []interface{}{
		map[string]interface{}{"id": "s0"},
	}
	// cap-1 = get_node /slides, cap-2 = patch_state add.
	canned := cannedGetNodeSlides("cap-1", slides) + cannedPatchOK("cap-2", 1)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "title": "New Slide"})
	out := toolAddSlide(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.set_state"`) {
		t.Errorf("tab_name mode must NOT call set_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"capability":"host.documents.patch_state"`) {
		t.Errorf("expected patch_state in wire, got: %s", wireOut)
	}
	// Appending to end → /slides/- path.
	if !strings.Contains(wireOut, `"/slides/-"`) {
		t.Errorf("expected /slides/- path for append, got: %s", wireOut)
	}
	// slide_index should be 1 (was 1 slide, appended at index 1).
	if idx, _ := out["slide_index"].(int); idx != 1 {
		t.Errorf("expected slide_index=1, got %v", out["slide_index"])
	}
}

// TestToolRemoveSlide_TabName_CallsPatchState verifies remove_slide with tab_name
// reads /slides to validate, then calls patch_state with a remove op.
func TestToolRemoveSlide_TabName_CallsPatchState(t *testing.T) {
	slides := []interface{}{
		map[string]interface{}{"id": "a"},
		map[string]interface{}{"id": "b"},
	}
	// cap-1 = get_node /slides, cap-2 = patch_state remove.
	canned := cannedGetNodeSlides("cap-1", slides) + cannedPatchOK("cap-2", 1)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "slide_index": 0})
	out := toolRemoveSlide(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.set_state"`) {
		t.Errorf("tab_name mode must NOT call set_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"op":"remove"`) {
		t.Errorf("expected remove op in wire, got: %s", wireOut)
	}
	if id, _ := out["slide_id"].(string); id != "a" {
		t.Errorf("expected removed id=a, got %v", out["slide_id"])
	}
	if rem, _ := out["remaining_slides"].(int); rem != 1 {
		t.Errorf("expected remaining_slides=1, got %v", out["remaining_slides"])
	}
}

// TestToolRemoveSlide_TabName_RefusesLastSlide verifies deck_empty_forbidden
// fires before calling patch_state when only 1 slide remains.
func TestToolRemoveSlide_TabName_RefusesLastSlide(t *testing.T) {
	slides := []interface{}{map[string]interface{}{"id": "only"}}
	canned := cannedGetNodeSlides("cap-1", slides)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "slide_index": 0})
	out := toolRemoveSlide(client, rawArgs)

	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure on last slide, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "deck_empty_forbidden" {
		t.Errorf("expected deck_empty_forbidden, got %q", code)
	}
	// Must not have called patch_state.
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.patch_state"`) {
		t.Errorf("must not call patch_state when refusing to empty deck: %s", wireOut)
	}
}

// TestToolMoveSlide_TabName_CallsPatchState verifies move_slide with tab_name
// uses patch_state with a move op.
func TestToolMoveSlide_TabName_CallsPatchState(t *testing.T) {
	slides := []interface{}{
		map[string]interface{}{"id": "a"},
		map[string]interface{}{"id": "b"},
		map[string]interface{}{"id": "c"},
	}
	// cap-1 = get_node /slides, cap-2 = patch_state move.
	canned := cannedGetNodeSlides("cap-1", slides) + cannedPatchOK("cap-2", 1)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "from_index": 0, "to_index": 2})
	out := toolMoveSlide(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if !strings.Contains(wireOut, `"op":"move"`) {
		t.Errorf("expected move op in wire, got: %s", wireOut)
	}
}

// TestToolMoveSlide_TabName_NoOp verifies that from==to returns no_op without
// any capability calls.
func TestToolMoveSlide_TabName_NoOp(t *testing.T) {
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{"tab_name": "deck.mdeck", "from_index": 1, "to_index": 1})
	out := toolMoveSlide(client, rawArgs)

	if noOp, _ := out["no_op"].(bool); !noOp {
		t.Errorf("expected no_op=true, got %+v", out)
	}
	if stdout.Len() > 0 {
		t.Errorf("expected no wire calls for no-op, got: %s", stdout.String())
	}
}

// TestToolAddTextTile_TabName_CallsPatchState verifies add_text_tile with
// tab_name uses patch_state with an add op appending to /slides/<i>/tiles.
func TestToolAddTextTile_TabName_CallsPatchState(t *testing.T) {
	slide := map[string]interface{}{"id": "s0", "tiles": []interface{}{}}
	// cap-1 = get_node /slides/0 (existence check), cap-2 = patch_state add.
	canned := cannedGetNodePath("cap-1", "/slides/0", true, slide) + cannedPatchOK("cap-2", 1)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"tab_name":    "deck.mdeck",
		"slide_index": 0,
		"x":           0.1, "y": 0.1, "w": 0.5, "h": 0.3,
		"content": "hello",
	})
	out := toolAddTextTile(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.set_state"`) {
		t.Errorf("tab_name mode must NOT call set_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"/slides/0/tiles/-"`) {
		t.Errorf("expected /slides/0/tiles/- append path in wire, got: %s", wireOut)
	}
}

// TestToolAddSpreadsheetTile_TabName_CallsPatchState verifies add_spreadsheet_tile
// with tab_name calls patch_state (not set_state).
func TestToolAddSpreadsheetTile_TabName_CallsPatchState(t *testing.T) {
	slide := map[string]interface{}{"id": "s0", "tiles": []interface{}{}}
	// cap-1 = get_node /slides/0, cap-2 = patch_state add.
	canned := cannedGetNodePath("cap-1", "/slides/0", true, slide) + cannedPatchOK("cap-2", 1)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"tab_name":    "deck.mdeck",
		"slide_index": 0,
		"x":           0.0, "y": 0.0, "w": 0.5, "h": 0.5,
		"rows": 2, "cols": 3,
	})
	out := toolAddSpreadsheetTile(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.set_state"`) {
		t.Errorf("tab_name mode must NOT call set_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"capability":"host.documents.patch_state"`) {
		t.Errorf("expected patch_state in wire, got: %s", wireOut)
	}
}

// TestToolRemoveTile_TabName_CallsPatchState verifies remove_tile with tab_name
// calls patch_state with remove (and replace for reveal scrub).
func TestToolRemoveTile_TabName_CallsPatchState(t *testing.T) {
	slide := map[string]interface{}{
		"id":     "s0",
		"tiles":  []interface{}{map[string]interface{}{"id": "t_a"}, map[string]interface{}{"id": "t_b"}},
		"reveal": []interface{}{"t_a", "t_b"},
	}
	// cap-1 = get_node /slides/0, cap-2 = patch_state (remove tile + replace reveal).
	canned := cannedGetNodePath("cap-1", "/slides/0", true, slide) + cannedPatchOK("cap-2", 2)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"tab_name":    "deck.mdeck",
		"slide_index": 0,
		"tile_id":     "t_a",
	})
	out := toolRemoveTile(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.set_state"`) {
		t.Errorf("tab_name mode must NOT call set_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"op":"remove"`) {
		t.Errorf("expected remove op in wire, got: %s", wireOut)
	}
	if removed, _ := out["removed_at"].(int); removed != 0 {
		t.Errorf("expected removed_at=0 (t_a is first), got %v", out["removed_at"])
	}
}

// TestToolSetSlideBackground_TabName_CallsPatchState verifies set_slide_background
// with tab_name calls patch_state with a replace op on /slides/<i>/background.
func TestToolSetSlideBackground_TabName_CallsPatchState(t *testing.T) {
	canned := cannedPatchOK("cap-1", 1)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"tab_name":    "deck.mdeck",
		"slide_index": 0,
		"color":       "#FF0000",
	})
	out := toolSetSlideBackground(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.set_state"`) {
		t.Errorf("tab_name mode must NOT call set_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"/slides/0/background"`) {
		t.Errorf("expected /slides/0/background path in wire, got: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"op":"replace"`) {
		t.Errorf("expected replace op in wire, got: %s", wireOut)
	}
}

// TestToolModifySpreadsheetCells_TabName_CallsPatchState verifies
// modify_spreadsheet_cells with tab_name calls get_node for the slide, mutates
// cells in memory, then patches only /slides/<i>/tiles/<j>/cells.
func TestToolModifySpreadsheetCells_TabName_CallsPatchState(t *testing.T) {
	slide := map[string]interface{}{
		"id": "s0",
		"tiles": []interface{}{
			map[string]interface{}{
				"id":   "t1",
				"kind": "spreadsheet",
				"rows": float64(2), "cols": float64(2),
				"cells": []interface{}{
					[]interface{}{map[string]interface{}{"value": "a", "type": float64(1)}, map[string]interface{}{"value": "b", "type": float64(1)}},
					[]interface{}{map[string]interface{}{"value": "c", "type": float64(1)}, map[string]interface{}{"value": "d", "type": float64(1)}},
				},
			},
		},
	}
	// cap-1 = get_node /slides/0, cap-2 = patch_state replace cells.
	canned := cannedGetNodePath("cap-1", "/slides/0", true, slide) + cannedPatchOK("cap-2", 1)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"tab_name":    "deck.mdeck",
		"slide_index": 0,
		"tile_id":     "t1",
		"cells": []map[string]interface{}{
			{"row": 0, "col": 0, "value": "X", "type": 1},
		},
	})
	out := toolModifySpreadsheetCells(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.set_state"`) {
		t.Errorf("tab_name mode must NOT call set_state; wire: %s", wireOut)
	}
	// Must patch only the cells subtree, not the full tile or slide.
	if !strings.Contains(wireOut, `/slides/0/tiles/0/cells`) {
		t.Errorf("expected /slides/0/tiles/0/cells path in patch, got: %s", wireOut)
	}
	if up, _ := out["cells_updated"].(int); up != 1 {
		t.Errorf("expected cells_updated=1, got %v", out["cells_updated"])
	}
}

// TestToolResizeSpreadsheet_TabName_CallsPatchState verifies resize_spreadsheet
// with tab_name patches rows/cols/cells atomically.
func TestToolResizeSpreadsheet_TabName_CallsPatchState(t *testing.T) {
	slide := map[string]interface{}{
		"id": "s0",
		"tiles": []interface{}{
			map[string]interface{}{
				"id":   "t1",
				"kind": "spreadsheet",
				"rows": float64(2), "cols": float64(2),
				"cells": []interface{}{
					[]interface{}{map[string]interface{}{"value": "a", "type": float64(1)}, map[string]interface{}{"value": "b", "type": float64(1)}},
					[]interface{}{map[string]interface{}{"value": "c", "type": float64(1)}, map[string]interface{}{"value": "d", "type": float64(1)}},
				},
			},
		},
	}
	// cap-1 = get_node /slides/0, cap-2 = patch_state (3 replace ops: rows/cols/cells).
	canned := cannedGetNodePath("cap-1", "/slides/0", true, slide) + cannedPatchOK("cap-2", 3)

	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(canned), &stdout)
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"tab_name":    "deck.mdeck",
		"slide_index": 0,
		"tile_id":     "t1",
		"rows":        3, "cols": 3,
	})
	out := toolResizeSpreadsheet(client, rawArgs)

	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	wireOut := stdout.String()
	if strings.Contains(wireOut, `"capability":"host.documents.set_state"`) {
		t.Errorf("tab_name mode must NOT call set_state; wire: %s", wireOut)
	}
	if !strings.Contains(wireOut, `"capability":"host.documents.patch_state"`) {
		t.Errorf("expected patch_state in wire, got: %s", wireOut)
	}
	if old, _ := out["old_rows"].(int); old != 2 {
		t.Errorf("expected old_rows=2, got %v", out["old_rows"])
	}
	if nw, _ := out["new_rows"].(int); nw != 3 {
		t.Errorf("expected new_rows=3, got %v", out["new_rows"])
	}
}

// ---------------------------------------------------------------------------
// minerva_presentation_list_open_annotations (T6 tail migration)
// ---------------------------------------------------------------------------

func TestToolListOpenAnnotations_FiltersByLifecycle(t *testing.T) {
	tmp := t.TempDir()
	deckPath := tmp + "/loa.mdeck"
	body := `{
		"version": 1,
		"aspect": "16:9",
		"slides": [
			{
				"id": "s_a",
				"annotations": [
					{"id":"ann_open_1","kind":"callout","summary":"todo A","lifecycle":"open"},
					{"id":"ann_resolved","kind":"callout","summary":"done","lifecycle":"resolved"},
					{"id":"ann_default","kind":"2d_text","summary":"default lifecycle is open"}
				]
			},
			{
				"id": "s_b",
				"annotations": [
					{"id":"ann_open_2","kind":"2d_arrow","summary":"todo B","lifecycle":"open"},
					{"id":"ann_applied","kind":"callout","summary":"applied","lifecycle":"applied"}
				]
			},
			{"id":"s_c"}
		]
	}`
	if err := os.WriteFile(deckPath, []byte(body), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath})
	out := toolListOpenAnnotations(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	count, _ := out["count"].(int)
	if count != 3 {
		t.Errorf("expected count=3 (2 explicit open + 1 default lifecycle), got %d", count)
	}
	open, _ := out["open"].([]interface{})
	if len(open) != 3 {
		t.Fatalf("expected 3 entries, got %d (%+v)", len(open), open)
	}
	// Build a map id → entry to assert content + slide_index without ordering coupling.
	got := map[string]map[string]interface{}{}
	for _, raw := range open {
		entry, _ := raw.(map[string]interface{})
		id, _ := entry["annotation_id"].(string)
		got[id] = entry
	}
	if got["ann_open_1"] == nil || got["ann_open_1"]["slide_index"] != 0 {
		t.Errorf("ann_open_1 missing or wrong slide_index: %+v", got["ann_open_1"])
	}
	if got["ann_default"] == nil || got["ann_default"]["slide_index"] != 0 {
		t.Errorf("ann_default (implicit-open) missing or wrong slide_index: %+v", got["ann_default"])
	}
	if got["ann_open_2"] == nil || got["ann_open_2"]["slide_index"] != 1 {
		t.Errorf("ann_open_2 missing or wrong slide_index: %+v", got["ann_open_2"])
	}
	if got["ann_resolved"] != nil {
		t.Errorf("resolved annotation should be filtered out, got %+v", got["ann_resolved"])
	}
	if got["ann_applied"] != nil {
		t.Errorf("applied annotation should be filtered out, got %+v", got["ann_applied"])
	}
	// kind + summary propagated.
	if got["ann_open_1"]["kind"] != "callout" || got["ann_open_1"]["summary"] != "todo A" {
		t.Errorf("ann_open_1 kind/summary not propagated: %+v", got["ann_open_1"])
	}
}

func TestToolListOpenAnnotations_EmptyDeck(t *testing.T) {
	tmp := t.TempDir()
	deckPath := tmp + "/empty.mdeck"
	if err := os.WriteFile(deckPath, []byte(`{"slides":[{"id":"s1"},{"id":"s2"}]}`), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{"path": deckPath})
	out := toolListOpenAnnotations(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success on empty deck, got %+v", out)
	}
	if count, _ := out["count"].(int); count != 0 {
		t.Errorf("expected count=0, got %d", count)
	}
}

// ---------------------------------------------------------------------------
// minerva_presentation_add_annotation (T6 tail R2)
// ---------------------------------------------------------------------------

// writeBlankDeck writes a minimal deck with one empty slide to a temp file.
// Returns the path.
func writeBlankDeck(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	path := tmp + "/ann.mdeck"
	body := `{"version":1,"aspect":"16:9","slides":[{"id":"s_a","tiles":[],"reveal":[]}]}`
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	return path
}

// readDeck reads + parses an .mdeck file (helper for post-mutation assertions).
func readDeck(t *testing.T, path string) map[string]interface{} {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read deck: %v", err)
	}
	var deck map[string]interface{}
	if err := json.Unmarshal(data, &deck); err != nil {
		t.Fatalf("parse deck: %v", err)
	}
	return deck
}

func TestToolAddAnnotation_CalloutDefaultAnchor(t *testing.T) {
	path := writeBlankDeck(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"kind":        "callout",
		"summary":     "todo: fix this",
	})
	out := toolAddAnnotation(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	annID, _ := out["annotation_id"].(string)
	if annID == "" {
		t.Fatal("annotation_id missing")
	}

	deck := readDeck(t, path)
	slide := deck["slides"].([]interface{})[0].(map[string]interface{})
	anns := slide["annotations"].([]interface{})
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	env := anns[0].(map[string]interface{})
	if env["id"] != annID {
		t.Errorf("envelope id mismatch: got %v, want %v", env["id"], annID)
	}
	if env["kind"] != "callout" {
		t.Errorf("kind: %v", env["kind"])
	}
	if env["lifecycle"] != "open" {
		t.Errorf("lifecycle default: %v", env["lifecycle"])
	}
	if v := env["schema_version"]; v != float64(2) {
		t.Errorf("schema_version: %v (%T)", v, v)
	}
	anchor := env["anchor"].(map[string]interface{})
	if anchor["plugin"] != "presentation" {
		t.Errorf("callout default anchor.plugin = %v, want presentation", anchor["plugin"])
	}
	if anchor["id"] != "s_a" {
		t.Errorf("anchor.id should be slide id: %v", anchor["id"])
	}
	// text-bearing: summary mirrored into kind_payload.text
	kp := env["kind_payload"].(map[string]interface{})
	if kp["text"] != "todo: fix this" {
		t.Errorf("callout (text-bearing) should mirror summary into kind_payload.text, got %v", kp["text"])
	}
	if env["view_context"] != "presentation:s_a" {
		t.Errorf("view_context: %v", env["view_context"])
	}
}

func TestToolAddAnnotation_2dArrowUsesCoreAnchor(t *testing.T) {
	path := writeBlankDeck(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"kind":        "2d_arrow",
		"summary":     "point here",
	})
	out := toolAddAnnotation(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	deck := readDeck(t, path)
	env := deck["slides"].([]interface{})[0].(map[string]interface{})["annotations"].([]interface{})[0].(map[string]interface{})
	anchor := env["anchor"].(map[string]interface{})
	if anchor["plugin"] != "core" {
		t.Errorf("2d_arrow default anchor.plugin = %v, want core", anchor["plugin"])
	}
	// 2d_arrow is NOT text-bearing → kind_payload.text should not be auto-populated
	kp := env["kind_payload"].(map[string]interface{})
	if _, has := kp["text"]; has {
		t.Errorf("2d_arrow kind_payload should not auto-set text, got %v", kp)
	}
}

func TestToolAddAnnotation_RejectsInvalidKind(t *testing.T) {
	path := writeBlankDeck(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"kind":        "freehand", // NOT in the substrate-valid set
		"summary":     "should fail",
	})
	out := toolAddAnnotation(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure on invalid kind, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "schema_validation_failed" {
		t.Errorf("expected schema_validation_failed, got %q", code)
	}
}

func TestToolAddAnnotation_RejectsEmptySummary(t *testing.T) {
	path := writeBlankDeck(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"kind":        "callout",
		"summary":     "",
	})
	out := toolAddAnnotation(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure on empty summary, got %+v", out)
	}
}

func TestToolAddAnnotation_OutOfRangeSlide(t *testing.T) {
	path := writeBlankDeck(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 99,
		"kind":        "callout",
		"summary":     "x",
	})
	out := toolAddAnnotation(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected out_of_range, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "out_of_range" {
		t.Errorf("expected out_of_range, got %q", code)
	}
}

// ---------------------------------------------------------------------------
// minerva_presentation_remove_annotation (T6 tail R2)
// ---------------------------------------------------------------------------

func TestToolRemoveAnnotation_LastOneOmitsKey(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/rm.mdeck"
	body := `{
		"slides": [{
			"id": "s_a",
			"annotations": [
				{"id":"ann_only","kind":"callout","summary":"x","lifecycle":"open"}
			]
		}]
	}`
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":          path,
		"slide_index":   0,
		"annotation_id": "ann_only",
	})
	out := toolRemoveAnnotation(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	deck := readDeck(t, path)
	slide := deck["slides"].([]interface{})[0].(map[string]interface{})
	if _, has := slide["annotations"]; has {
		t.Errorf("omit-when-default: annotations key should be removed when last one is gone, got %+v", slide["annotations"])
	}
}

func TestToolRemoveAnnotation_ScrubsRevealRefs(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/scrub.mdeck"
	body := `{
		"slides": [{
			"id": "s_a",
			"annotations": [
				{"id":"ann_x","kind":"callout","summary":"x","lifecycle":"open"},
				{"id":"ann_y","kind":"callout","summary":"y","lifecycle":"open"}
			],
			"reveal": ["tile_t1", "ann_x", "tile_t2"]
		}]
	}`
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":          path,
		"slide_index":   0,
		"annotation_id": "ann_x",
	})
	out := toolRemoveAnnotation(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	deck := readDeck(t, path)
	slide := deck["slides"].([]interface{})[0].(map[string]interface{})
	reveal := slide["reveal"].([]interface{})
	if len(reveal) != 2 {
		t.Fatalf("reveal should shrink from 3→2 after scrubbing ann_x, got %d (%+v)", len(reveal), reveal)
	}
	for _, r := range reveal {
		if r == "ann_x" {
			t.Errorf("ann_x should be scrubbed, still in reveal: %+v", reveal)
		}
	}
	// ann_y still present (we only removed ann_x)
	anns := slide["annotations"].([]interface{})
	if len(anns) != 1 {
		t.Errorf("expected 1 surviving annotation, got %d", len(anns))
	}
}

func TestToolRemoveAnnotation_NotFound(t *testing.T) {
	path := writeBlankDeck(t) // no annotations
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":          path,
		"slide_index":   0,
		"annotation_id": "nope",
	})
	out := toolRemoveAnnotation(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected failure, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "not_found" {
		t.Errorf("expected not_found, got %q", code)
	}
}

// ---------------------------------------------------------------------------
// minerva_presentation_set_annotation_resolved (T6 tail R2)
// ---------------------------------------------------------------------------

func TestToolSetAnnotationResolved_ResolvedBoolTrue(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/res.mdeck"
	body := `{
		"slides": [{
			"id":"s_a",
			"annotations": [{"id":"a","kind":"callout","summary":"x","lifecycle":"open"}]
		}]
	}`
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":          path,
		"slide_index":   0,
		"annotation_id": "a",
		"resolved":      true,
	})
	out := toolSetAnnotationResolved(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	if lc, _ := out["lifecycle"].(string); lc != "resolved" {
		t.Errorf("response lifecycle: %v", lc)
	}
	deck := readDeck(t, path)
	env := deck["slides"].([]interface{})[0].(map[string]interface{})["annotations"].([]interface{})[0].(map[string]interface{})
	if env["lifecycle"] != "resolved" {
		t.Errorf("envelope lifecycle after resolved=true: %v", env["lifecycle"])
	}
}

func TestToolSetAnnotationResolved_ExplicitLifecycleAppliesNote(t *testing.T) {
	tmp := t.TempDir()
	path := tmp + "/note.mdeck"
	body := `{
		"slides": [{
			"id":"s_a",
			"annotations": [{"id":"a","kind":"callout","summary":"x","lifecycle":"open"}]
		}]
	}`
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":          path,
		"slide_index":   0,
		"annotation_id": "a",
		"lifecycle":     "applied",
		"note":          "merged in commit abc123",
	})
	out := toolSetAnnotationResolved(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	deck := readDeck(t, path)
	env := deck["slides"].([]interface{})[0].(map[string]interface{})["annotations"].([]interface{})[0].(map[string]interface{})
	if env["lifecycle"] != "applied" {
		t.Errorf("explicit lifecycle wins: got %v, want applied", env["lifecycle"])
	}
	notes, _ := env["resolution_notes"].([]interface{})
	if len(notes) != 1 {
		t.Fatalf("expected 1 resolution note, got %d", len(notes))
	}
	rn := notes[0].(map[string]interface{})
	if rn["lifecycle"] != "applied" {
		t.Errorf("note.lifecycle: %v", rn["lifecycle"])
	}
	if rn["note"] != "merged in commit abc123" {
		t.Errorf("note.note: %v", rn["note"])
	}
	if _, has := rn["at"]; !has {
		t.Errorf("note.at missing")
	}
}

func TestToolSetAnnotationResolved_RequiresOneArg(t *testing.T) {
	path := writeBlankDeck(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":          path,
		"slide_index":   0,
		"annotation_id": "a",
	})
	out := toolSetAnnotationResolved(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected schema_validation_failed, got %+v", out)
	}
}

// ---------------------------------------------------------------------------
// minerva_presentation_modify_tile (T6 tail R3)
// ---------------------------------------------------------------------------

// writeDeckWithTiles seeds a deck with one slide containing one text + one
// image tile. Returns the path; tile ids are "t_text" and "t_image".
func writeDeckWithTiles(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	path := tmp + "/mt.mdeck"
	body := `{
		"version": 1,
		"aspect": "16:9",
		"slides": [{
			"id": "s_a",
			"tiles": [
				{"id":"t_text","kind":"text","x":0.1,"y":0.1,"w":0.4,"h":0.2,"content":"hello","text_mode":"plain"},
				{"id":"t_image","kind":"image","x":0.5,"y":0.5,"w":0.3,"h":0.3,"src":"old"}
			]
		}]
	}`
	if err := os.WriteFile(path, []byte(body), 0644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	return path
}

func TestToolModifyTile_CoordsAndRotation(t *testing.T) {
	path := writeDeckWithTiles(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "t_text",
		"x":           0.2,
		"w":           0.5,
		"rotation":    0.785, // pi/4
	})
	out := toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	deck := readDeck(t, path)
	tile := deck["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})[0].(map[string]interface{})
	if tile["x"] != 0.2 {
		t.Errorf("x: %v", tile["x"])
	}
	if tile["w"] != 0.5 {
		t.Errorf("w: %v", tile["w"])
	}
	if tile["rotation"] != 0.785 {
		t.Errorf("rotation: %v", tile["rotation"])
	}
	if tile["y"] != 0.1 {
		t.Errorf("y (unchanged) lost: %v", tile["y"])
	}
}

func TestToolModifyTile_RotationZeroErases(t *testing.T) {
	path := writeDeckWithTiles(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	// First set rotation.
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "t_text",
		"rotation":    0.5,
	})
	out := toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("set rotation failed: %+v", out)
	}
	// Now clear.
	rawArgs, _ = json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "t_text",
		"rotation":    0,
	})
	out = toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("clear rotation failed: %+v", out)
	}
	deck := readDeck(t, path)
	tile := deck["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})[0].(map[string]interface{})
	if _, has := tile["rotation"]; has {
		t.Errorf("rotation=0 should erase the key, got %+v", tile)
	}
}

func TestToolModifyTile_TextFieldsOnImageTileRejected(t *testing.T) {
	path := writeDeckWithTiles(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "t_image",
		"content":     "should fail",
	})
	out := toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected reject, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "schema_validation_failed" {
		t.Errorf("expected schema_validation_failed, got %q", code)
	}
}

func TestToolModifyTile_FontSizeBoundsAndClear(t *testing.T) {
	path := writeDeckWithTiles(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	// Out of range — should fail.
	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "t_text",
		"font_size":   500,
	})
	out := toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("font_size=500 should fail, got %+v", out)
	}

	// In range — sets.
	rawArgs, _ = json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "t_text",
		"font_size":   42,
	})
	out = toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("font_size=42 should succeed, got %+v", out)
	}

	// 0 — clears.
	rawArgs, _ = json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "t_text",
		"font_size":   0,
	})
	out = toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("font_size=0 should succeed (clear), got %+v", out)
	}
	deck := readDeck(t, path)
	tile := deck["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})[0].(map[string]interface{})
	if _, has := tile["font_size"]; has {
		t.Errorf("font_size=0 should erase the key, got %+v", tile["font_size"])
	}
}

func TestToolModifyTile_ImageSourceMutualExclusion(t *testing.T) {
	path := writeDeckWithTiles(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":         path,
		"slide_index":  0,
		"tile_id":      "t_image",
		"image_base64": "ignored",
		"solid_color":  "#ff0000",
	})
	out := toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected schema_validation_failed on two sources, got %+v", out)
	}
}

func TestToolModifyTile_SolidColorSynthesisesPNG(t *testing.T) {
	path := writeDeckWithTiles(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "t_image",
		"solid_color": "#1F4E5A",
	})
	out := toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); !success {
		t.Fatalf("expected success, got %+v", out)
	}
	deck := readDeck(t, path)
	tile := deck["slides"].([]interface{})[0].(map[string]interface{})["tiles"].([]interface{})[1].(map[string]interface{})
	src, _ := tile["src"].(string)
	if src == "" || src == "old" {
		t.Fatalf("expected replaced src with PNG base64, got len=%d (%q)", len(src), src[:min(40, len(src))])
	}
	raw, err := base64.StdEncoding.DecodeString(src)
	if err != nil {
		t.Fatalf("src is not base64: %v", err)
	}
	// PNG magic: 89 50 4E 47 0D 0A 1A 0A
	if len(raw) < 8 || raw[0] != 0x89 || raw[1] != 'P' || raw[2] != 'N' || raw[3] != 'G' {
		t.Errorf("not a PNG: %v", raw[:min(8, len(raw))])
	}
}

func TestToolModifyTile_SolidColorRejectsInvalidHex(t *testing.T) {
	path := writeDeckWithTiles(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "t_image",
		"solid_color": "rgb(1,2,3)",
	})
	out := toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected reject, got %+v", out)
	}
}

func TestToolModifyTile_RejectsCoordsOutOfRange(t *testing.T) {
	path := writeDeckWithTiles(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "t_text",
		"x":           1.5,
	})
	out := toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected reject for x>1, got %+v", out)
	}
}

func TestToolModifyTile_SourceGraphicsEditorDeferredCleanly(t *testing.T) {
	path := writeDeckWithTiles(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":                   path,
		"slide_index":            0,
		"tile_id":                "t_image",
		"source_graphics_editor": "diagram1",
	})
	out := toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected not-yet-supported error, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "not_implemented_in_plugin_yet" {
		t.Errorf("expected not_implemented_in_plugin_yet, got %q", code)
	}
}

func TestToolModifyTile_TileNotFound(t *testing.T) {
	path := writeDeckWithTiles(t)
	var stdout bytes.Buffer
	client := newMockClient(strings.NewReader(""), &stdout)

	rawArgs, _ := json.Marshal(map[string]interface{}{
		"path":        path,
		"slide_index": 0,
		"tile_id":     "nope",
	})
	out := toolModifyTile(client, rawArgs)
	if success, _ := out["success"].(bool); success {
		t.Fatalf("expected not_found, got %+v", out)
	}
	if code, _ := out["error_code"].(string); code != "not_found" {
		t.Errorf("expected not_found, got %q", code)
	}
}

func TestParseAspectRatio_FallbackOnGarbage(t *testing.T) {
	if r := parseAspectRatio("garbage"); r != 16.0/9.0 {
		t.Errorf("fallback failed: %v", r)
	}
	if r := parseAspectRatio("4:3"); r != 4.0/3.0 {
		t.Errorf("4:3: %v", r)
	}
	if r := parseAspectRatio("1:1"); r != 1.0 {
		t.Errorf("1:1: %v", r)
	}
}
