package config

import "testing"

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
