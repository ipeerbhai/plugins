// Package runtime resolves the path of the Python interpreter and worker
// entrypoint for the CAD worker subprocess.
package runtime

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

// PythonPath returns the path to the Python interpreter to spawn the worker with.
//
// Plan A (Round 2, dev-mode):
//  1. Prefer <workerDir>/.venv/bin/python (POSIX) or <workerDir>\.venv\Scripts\python.exe (Windows)
//     when present — this is what `python3 -m venv .venv` produces and is the
//     contract for developer setup (see DCR 019dc0552d6a, Round 3 pickup state).
//  2. Otherwise fall back to `python3` on $PATH.
//
// Plan B (future grandchild, consumer-mode): extract embedded PBS Python tarball
// to <data_directory>/runtime/<plugin_version>/ and return that path.
// See Docs/design/Go-python-bridge-design.md §6.
func PythonPath(workerDir string) (string, error) {
	if workerDir != "" {
		if p := venvPython(workerDir); p != "" {
			return p, nil
		}
	}
	p, err := exec.LookPath("python3")
	if err != nil {
		return "", fmt.Errorf("python3 not on PATH and no .venv at %s: %w (TODO: replace with embedded PBS extract per design §6)", workerDir, err)
	}
	return p, nil
}

// venvPython returns the path to a venv-managed Python interpreter under
// <workerDir>/.venv if it exists and is executable, otherwise "".
func venvPython(workerDir string) string {
	var candidate string
	if runtime.GOOS == "windows" {
		candidate = filepath.Join(workerDir, ".venv", "Scripts", "python.exe")
	} else {
		candidate = filepath.Join(workerDir, ".venv", "bin", "python")
	}
	info, err := os.Stat(candidate)
	if err != nil || info.IsDir() {
		return ""
	}
	return candidate
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
