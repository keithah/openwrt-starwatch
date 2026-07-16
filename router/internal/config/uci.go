// Package config parses Starwatch's OpenWrt UCI configuration.
package config

import (
	"fmt"
	"strings"
)

type UCISection struct {
	Type    string
	Name    string
	Options map[string]string
	Lists   map[string][]string
}

type UCIDoc struct {
	Sections []*UCISection
}

func newSection(typ, name string) *UCISection {
	return &UCISection{Type: typ, Name: name, Options: map[string]string{}, Lists: map[string][]string{}}
}

func unquote(s string) string {
	if len(s) >= 2 && ((s[0] == '\'' && s[len(s)-1] == '\'') || (s[0] == '"' && s[len(s)-1] == '"')) {
		return s[1 : len(s)-1]
	}
	return s
}

func ParseUCI(src string) (*UCIDoc, error) {
	doc := &UCIDoc{}
	var current *UCISection
	for lineNumber, raw := range strings.Split(src, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.SplitN(line, " ", 2)
		if len(fields) != 2 {
			return nil, fmt.Errorf("line %d: malformed %q", lineNumber+1, line)
		}
		rest := strings.TrimSpace(fields[1])
		switch fields[0] {
		case "config":
			parts := strings.SplitN(rest, " ", 2)
			name := ""
			if len(parts) == 2 {
				name = unquote(strings.TrimSpace(parts[1]))
			}
			current = newSection(unquote(parts[0]), name)
			doc.Sections = append(doc.Sections, current)
		case "option", "list":
			if current == nil {
				return nil, fmt.Errorf("line %d: %s outside section", lineNumber+1, fields[0])
			}
			parts := strings.SplitN(rest, " ", 2)
			if len(parts) != 2 {
				return nil, fmt.Errorf("line %d: malformed %q", lineNumber+1, line)
			}
			key, value := unquote(parts[0]), unquote(strings.TrimSpace(parts[1]))
			if fields[0] == "option" {
				current.Options[key] = value
			} else {
				current.Lists[key] = append(current.Lists[key], value)
			}
		default:
			return nil, fmt.Errorf("line %d: unknown keyword %q", lineNumber+1, fields[0])
		}
	}
	return doc, nil
}

func (d *UCIDoc) Find(typ, name string) *UCISection {
	for _, section := range d.Sections {
		if section.Type == typ && section.Name == name {
			return section
		}
	}
	return nil
}
