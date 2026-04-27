// Package bridge implements the length-prefixed JSON framing protocol used
// between the Go MCP server and the Python CAD worker subprocess.
//
// Frame format (design §3):
//
//	Content-Length: NNNN\r\n
//	Content-Type: application/json; charset=utf-8\r\n
//	\r\n
//	<body bytes>
package bridge

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

const (
	headerContentLength = "Content-Length"
	headerContentType   = "Content-Type"
	contentTypeJSON     = "application/json; charset=utf-8"
)

// WriteFrame writes a single length-prefixed frame to w.
// It emits both Content-Length and Content-Type headers followed by CRLF CRLF
// and then the raw body bytes.
func WriteFrame(w io.Writer, body []byte) error {
	header := fmt.Sprintf(
		"%s: %d\r\n%s: %s\r\n\r\n",
		headerContentLength, len(body),
		headerContentType, contentTypeJSON,
	)
	if _, err := io.WriteString(w, header); err != nil {
		return fmt.Errorf("bridge.WriteFrame: write header: %w", err)
	}
	if _, err := w.Write(body); err != nil {
		return fmt.Errorf("bridge.WriteFrame: write body: %w", err)
	}
	return nil
}

// ReadFrame reads one length-prefixed frame from r.
// It reads CRLF-terminated header lines until the blank separator, extracts
// the Content-Length value, then reads exactly that many bytes as the body.
//
// On any header parse failure the caller must drain the reader and restart
// the worker (design §3 "On header parse failure").
func ReadFrame(r *bufio.Reader) ([]byte, error) {
	contentLength := -1

	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, fmt.Errorf("bridge.ReadFrame: read header line: %w", err)
		}
		// Strip trailing CRLF or LF.
		line = strings.TrimRight(line, "\r\n")

		// Blank line == end of headers.
		if line == "" {
			break
		}

		parts := strings.SplitN(line, ": ", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("bridge.ReadFrame: malformed header: %q", line)
		}
		name := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])

		if strings.EqualFold(name, headerContentLength) {
			n, parseErr := strconv.Atoi(value)
			if parseErr != nil || n < 0 {
				return nil, fmt.Errorf("bridge.ReadFrame: invalid Content-Length %q: %w", value, parseErr)
			}
			contentLength = n
		}
		// Other headers (e.g. Content-Type) are accepted and ignored.
	}

	if contentLength < 0 {
		return nil, fmt.Errorf("bridge.ReadFrame: missing Content-Length header")
	}

	body := make([]byte, contentLength)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, fmt.Errorf("bridge.ReadFrame: read body (%d bytes): %w", contentLength, err)
	}
	return body, nil
}
