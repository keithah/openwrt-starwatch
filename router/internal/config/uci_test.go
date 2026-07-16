package config

import (
	"strings"
	"testing"
)

func TestParseUCI(t *testing.T) {
	doc, err := ParseUCI(`
# comment
config starwatch 'main'
	option listen "127.0.0.1"
	list probe_host '1.1.1.1'
	list probe_host '8.8.8.8'
`)
	if err != nil {
		t.Fatal(err)
	}
	main := doc.Find("starwatch", "main")
	if main == nil || main.Options["listen"] != "127.0.0.1" {
		t.Fatalf("main section: %#v", main)
	}
	if got := main.Lists["probe_host"]; len(got) != 2 || got[1] != "8.8.8.8" {
		t.Fatalf("probe hosts: %#v", got)
	}
}

func TestParseUCIRejectsOptionOutsideSection(t *testing.T) {
	if _, err := ParseUCI("option port '9633'"); err == nil {
		t.Fatal("expected malformed UCI error")
	}
}

func TestParseUCIAcceptsTabsBetweenTokens(t *testing.T) {
	doc, err := ParseUCI("config\tstarwatch\t'main'\noption\tport\t'9633'\n")
	if err != nil {
		t.Fatal(err)
	}
	section := doc.Find("starwatch", "main")
	if section == nil || section.Options["port"] != "9633" {
		t.Fatalf("section: %#v", section)
	}
}

func TestRewriteUCIPreservesUnknownContentAndComments(t *testing.T) {
	source := `# keep this comment
config starwatch 'main'
	option probe_interval '2'
	option future_option 'keep-me'

config plugin 'unknown'
	list mystery 'one'
`
	result, err := RewriteUCI(source, []OptionValue{{SectionType: "starwatch", SectionName: "main", Option: "probe_interval", Value: "5"}, {SectionType: "starwatch", SectionName: "main", Option: "poll_map", Value: "900"}})
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"# keep this comment", "option probe_interval '5'", "option poll_map '900'", "option future_option 'keep-me'", "config plugin 'unknown'", "list mystery 'one'"} {
		if !strings.Contains(result, expected) {
			t.Fatalf("missing %q in:\n%s", expected, result)
		}
	}
}
