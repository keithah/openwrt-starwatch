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

type OptionValue struct {
	SectionType string
	SectionName string
	Option      string
	Value       string
}

func RewriteUCI(source string, updates []OptionValue) (string, error) {
	type sectionKey struct{ typ, name string }
	pending := make(map[sectionKey][]OptionValue)
	for _, update := range updates {
		key := sectionKey{update.SectionType, update.SectionName}
		pending[key] = append(pending[key], update)
	}
	applied := make(map[string]bool)
	lines := strings.Split(source, "\n")
	result := make([]string, 0, len(lines)+len(updates))
	current := sectionKey{}
	haveSection := false
	flushMissing := func() {
		if !haveSection {
			return
		}
		for _, update := range pending[current] {
			id := updateID(update)
			if !applied[id] {
				result = append(result, "\toption "+update.Option+" '"+quoteUCI(update.Value)+"'")
				applied[id] = true
			}
		}
	}
	for _, raw := range lines {
		trimmed := strings.TrimSpace(raw)
		keyword, rest, ok := splitFirst(trimmed)
		if ok && keyword == "config" {
			flushMissing()
			typ, nameText, named := splitFirst(rest)
			name := ""
			if named {
				name = unquote(nameText)
			}
			current, haveSection = sectionKey{unquote(typ), name}, true
			result = append(result, raw)
			continue
		}
		if haveSection && ok && keyword == "option" {
			option, _, parsed := splitFirst(rest)
			if parsed {
				option = unquote(option)
				for _, update := range pending[current] {
					if update.Option == option {
						indent := raw[:len(raw)-len(strings.TrimLeftFunc(raw, unicode.IsSpace))]
						result = append(result, indent+"option "+option+" '"+quoteUCI(update.Value)+"'")
						applied[updateID(update)] = true
						goto nextLine
					}
				}
			}
		}
		result = append(result, raw)
	nextLine:
	}
	flushMissing()
	appendedSections := make(map[sectionKey]bool)
	for _, update := range updates {
		if applied[updateID(update)] {
			continue
		}
		key := sectionKey{update.SectionType, update.SectionName}
		if !appendedSections[key] {
			header := "config " + update.SectionType
			if update.SectionName != "" {
				header += " '" + quoteUCI(update.SectionName) + "'"
			}
			result = append(result, header)
			appendedSections[key] = true
		}
		result = append(result, "\toption "+update.Option+" '"+quoteUCI(update.Value)+"'")
		applied[updateID(update)] = true
	}
	return strings.Join(result, "\n"), nil
}

func updateID(update OptionValue) string {
	return update.SectionType + "\x00" + update.SectionName + "\x00" + update.Option
}

func quoteUCI(value string) string { return strings.ReplaceAll(value, "'", "'\\''") }

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
