// Package runtime resolves the path of the Python interpreter and worker
// entrypoint for the CAD worker subprocess.
package runtime

import (
	"fmt"
	"os/exec"
)

// PythonPath returns the path to the Python interpreter to spawn the worker with.
//
// Plan A (Round 2): look up `python3` from $PATH (dev-mode resolution).
// Plan B (future grandchild): extract embedded PBS Python tarball to
// <data_directory>/runtime/<plugin_version>/ and return that path.
// See Docs/design/Go-python-bridge-design.md §6 for the full design.
func PythonPath() (string, error) {
	p, err := exec.LookPath("python3")
	if err != nil {
		return "", fmt.Errorf("python3 not on PATH: %w (TODO: replace with embedded PBS extract per design §6)", err)
	}
	return p, nil
}

// WorkerScriptDir returns the absolute filesystem path to the directory
// containing the Python worker entrypoint module (`mcad_worker`).
//
// Plan A: assumes the plugin runs from a checkout, with worker/ next to the
// Go binary. The caller invokes `python -m mcad_worker` with cwd set to the
// returned directory.
//
// pluginRoot is typically the directory containing manifest.json, which the
// plugin was launched from. We rely on the layout established in Round 1:
// pluginRoot/worker/mcad_worker/.
func WorkerScriptDir(pluginRoot string) string {
	return pluginRoot + "/worker"
}
