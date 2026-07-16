// Package web owns the Starwatch browser application assets.
package web

import (
	"embed"
	"io/fs"
	"os"
)

//go:embed *.html *.css *.js vendor/*
var embedded embed.FS

// FileSystem returns the checked-in application, or a development directory
// when STARWATCH_WEB_DIR is set before the HTTP server is constructed.
func FileSystem() fs.FS {
	if directory := os.Getenv("STARWATCH_WEB_DIR"); directory != "" {
		return os.DirFS(directory)
	}
	return embedded
}
