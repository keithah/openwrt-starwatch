// Package config parses Starwatch's OpenWrt UCI configuration.
package config

import (
	"fmt"
	"strings"
	"unicode"
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
		keyword, rest, ok := splitFirst(line)
		if !ok {
			return nil, fmt.Errorf("line %d: malformed %q", lineNumber+1, line)
		}
		switch keyword {
		case "config":
			typ, sectionName, named := splitFirst(rest)
			name := ""
			if named {
				name = unquote(sectionName)
			}
			current = newSection(unquote(typ), name)
			doc.Sections = append(doc.Sections, current)
		case "option", "list":
			if current == nil {
				return nil, fmt.Errorf("line %d: %s outside section", lineNumber+1, keyword)
			}
			key, value, ok := splitFirst(rest)
			if !ok {
				return nil, fmt.Errorf("line %d: malformed %q", lineNumber+1, line)
			}
			key, value = unquote(key), unquote(value)
			if keyword == "option" {
				current.Options[key] = value
			} else {
				current.Lists[key] = append(current.Lists[key], value)
			}
		default:
			return nil, fmt.Errorf("line %d: unknown keyword %q", lineNumber+1, keyword)
		}
	}
	return doc, nil
}

func splitFirst(value string) (string, string, bool) {
	index := strings.IndexFunc(value, unicode.IsSpace)
	if index < 0 {
		return value, "", false
	}
	first := value[:index]
	rest := strings.TrimLeftFunc(value[index:], unicode.IsSpace)
	return first, rest, rest != ""
}

func (d *UCIDoc) Find(typ, name string) *UCISection {
	for _, section := range d.Sections {
		if section.Type == typ && section.Name == name {
			return section
		}
	}
	return nil
}
