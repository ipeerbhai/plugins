// Package runtime resolves the path of the bundled Python runtime that the
// CAD worker subprocess is launched from.
//
// TODO(round-2): implement PBS tarball extraction, SHA-256 manifest check,
// fallback lookup chain, and GC of old runtime versions per design §6.
// The full shape is documented in Go-python-bridge-design.md §6
// ("Python Packaging → Runtime directory").
package runtime

import (
	"path/filepath"
)

// RuntimeRoot returns the path to the extracted runtime directory for the
// given plugin data directory and plugin version.
//
// Canonical form (design §6):
//
//	<dataDir>/runtime/<pluginVersion>/
//
// Round 1 stub: returns the path without verifying existence or extracting
// anything.  A later grandchild task will add the three-step lookup (user
// cache → pre-bundled → embedded tarball) and the GC policy.
func RuntimeRoot(dataDir, pluginVersion string) string {
	return filepath.Join(dataDir, "runtime", pluginVersion)
}
