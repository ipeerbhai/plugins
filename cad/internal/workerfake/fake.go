// Package workerfake provides a pure-Go test double for the Python CAD worker.
//
// It implements the same length-prefixed framing (bridge §3) and request/
// response protocol (bridge §4) as the real worker, keyed by canned responses
// registered at construction time.  The fake is used exclusively in tests;
// no production code imports it (design §11).
//
// Usage:
//
//	f := workerfake.New()
//	f.Register("init", "", bridge.Response{OK: true, Result: json.RawMessage(`{"worker_version":"fake"}`)})
//	clientR, workerW := io.Pipe()
//	workerR, clientW := io.Pipe()
//	go f.Run(workerR, workerW)
//	// clientR / clientW are the test's I/O pair
package workerfake

import (
	"bufio"
	"crypto/md5" //nolint:gosec // md5 used only for non-security keying
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"sync"

	"github.com/ipeerbhai/plugins/cad/internal/bridge"
)

// key uniquely identifies a canned response entry.
type key struct {
	method     string
	paramsHash string // hex-encoded MD5 of canonical params JSON, or "" for wildcard
}

// entry holds a canned response.
type entry struct {
	resp bridge.Response
}

// Fake is a pure-Go worker double.
type Fake struct {
	mu         sync.Mutex
	canned     map[key]entry
	callCounts map[string]int // method → count
}

// New creates an empty Fake with no canned responses.
func New() *Fake {
	return &Fake{
		canned:     make(map[key]entry),
		callCounts: make(map[string]int),
	}
}

// Register installs a canned response for (method, paramsHash).
// Pass paramsHash="" to match any params for that method (wildcard).
// The last call for a given key wins.
func (f *Fake) Register(method, paramsHash string, resp bridge.Response) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.canned[key{method, paramsHash}] = entry{resp: resp}
}

// CallCount returns the number of times the fake processed a request with
// the given method name.
func (f *Fake) CallCount(method string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.callCounts[method]
}

// HashParams returns the hex-encoded MD5 of the canonical JSON encoding of v.
// Use this to compute the paramsHash argument to Register when you care about
// specific param values.
func HashParams(v interface{}) (string, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return "", fmt.Errorf("workerfake.HashParams: %w", err)
	}
	sum := md5.Sum(b) //nolint:gosec
	return hex.EncodeToString(sum[:]), nil
}

// Run drives the fake: it emits a worker.ready notification, then reads framed
// requests from in and writes framed responses to out until in reaches EOF.
// Intended to be launched in a goroutine.
func (f *Fake) Run(in io.Reader, out io.Writer) {
	// Emit worker.ready first (design §5).
	readyParams, _ := json.Marshal(map[string]string{
		"version":   "fake-1.0.0",
		"build123d": "fake",
		"occt":      "fake",
	})
	notif := &bridge.Notification{
		Method: "worker.ready",
		Params: readyParams,
	}
	notifBytes, err := bridge.MarshalNotification(notif)
	if err != nil {
		log.Printf("workerfake: marshal worker.ready: %v", err)
		return
	}
	if err := bridge.WriteFrame(out, notifBytes); err != nil {
		log.Printf("workerfake: write worker.ready: %v", err)
		return
	}

	// Drain and respond to requests.
	r := bufio.NewReaderSize(in, 1<<20)
	for {
		body, err := bridge.ReadFrame(r)
		if err != nil {
			// EOF or pipe close — normal shutdown.
			return
		}

		var req bridge.Request
		if err := json.Unmarshal(body, &req); err != nil {
			log.Printf("workerfake: unmarshal request: %v", err)
			continue
		}

		f.mu.Lock()
		f.callCounts[req.Method]++
		f.mu.Unlock()

		resp := f.dispatch(&req)
		resp.ID = req.ID

		respBytes, err := bridge.MarshalResponse(&resp)
		if err != nil {
			log.Printf("workerfake: marshal response: %v", err)
			continue
		}
		if err := bridge.WriteFrame(out, respBytes); err != nil {
			log.Printf("workerfake: write response: %v", err)
			return
		}
	}
}

// dispatch looks up the canned response for req.  It tries an exact
// params-hash match first, then the wildcard.  If nothing matches, it returns
// a generic error response.
func (f *Fake) dispatch(req *bridge.Request) bridge.Response {
	// Compute params hash for exact-match lookup.
	var paramsHash string
	if len(req.Params) > 0 {
		sum := md5.Sum(req.Params) //nolint:gosec
		paramsHash = hex.EncodeToString(sum[:])
	}

	f.mu.Lock()
	defer f.mu.Unlock()

	// Exact match.
	if e, ok := f.canned[key{req.Method, paramsHash}]; ok {
		return e.resp
	}
	// Wildcard match.
	if e, ok := f.canned[key{req.Method, ""}]; ok {
		return e.resp
	}

	// No canned response found.
	errJSON, _ := json.Marshal(&bridge.WorkerError{
		Kind:    "internal",
		Message: fmt.Sprintf("workerfake: no canned response for method %q", req.Method),
	})
	return bridge.Response{
		OK:    false,
		Error: &bridge.WorkerError{Kind: "internal", Message: string(errJSON)},
	}
}
