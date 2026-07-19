package alert

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func TestDispatcherRetriesWebhookThreeTimesWithExponentialBackoff(t *testing.T) {
	var calls atomic.Int32
	var received Notification
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.Header.Get("Content-Type") != "application/json" {
			t.Errorf("content type: %q", r.Header.Get("Content-Type"))
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode: %v", err)
		}
		if calls.Load() < 4 {
			http.Error(w, "retry", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	var sleeps []time.Duration
	dispatcher := NewDispatcher(DeliveryOptions{
		WebhookURL: server.URL, HTTPClient: server.Client(), QueueSize: 1, Backoff: 10 * time.Millisecond,
		Sleep: func(_ context.Context, duration time.Duration) error { sleeps = append(sleeps, duration); return nil },
	})
	want := Notification{Alert: "outage_started", Severity: SeverityCritical, State: StateFiring, At: 123, Detail: map[string]any{"cause": "NO_DOWNLINK"}, Device: "ut-1"}

	dispatcher.deliver(context.Background(), want)

	if calls.Load() != 4 || !reflect.DeepEqual(sleeps, []time.Duration{10 * time.Millisecond, 20 * time.Millisecond, 40 * time.Millisecond}) {
		t.Fatalf("calls=%d sleeps=%v", calls.Load(), sleeps)
	}
	if received.Alert != want.Alert || received.Severity != want.Severity || received.State != want.State || received.At != want.At || received.Device != want.Device {
		t.Fatalf("webhook body: %+v", received)
	}
}

func TestDispatcherMapsNtfyHeadersFromSeverity(t *testing.T) {
	for _, test := range []struct {
		severity Severity
		priority string
		tags     string
	}{
		{SeverityCritical, "urgent", "rotating_light"},
		{SeverityWarning, "high", "warning"},
		{SeverityInfo, "default", "information_source"},
	} {
		t.Run(string(test.severity), func(t *testing.T) {
			var title, priority, tags string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				title, priority, tags = r.Header.Get("Title"), r.Header.Get("Priority"), r.Header.Get("Tags")
				_, _ = io.Copy(io.Discard, r.Body)
				w.WriteHeader(http.StatusOK)
			}))
			defer server.Close()
			dispatcher := NewDispatcher(DeliveryOptions{NtfyURL: server.URL, HTTPClient: server.Client()})

			dispatcher.deliver(context.Background(), Notification{Alert: "test_alert", Severity: test.severity, State: StateFiring})

			if title != "Starwatch: test_alert firing" || priority != test.priority || tags != test.tags {
				t.Fatalf("headers title=%q priority=%q tags=%q", title, priority, tags)
			}
		})
	}
}

func TestDispatcherQueueDropsOldestAndLogsWarning(t *testing.T) {
	var output bytes.Buffer
	dispatcher := NewDispatcher(DeliveryOptions{QueueSize: 2, Logf: log.New(&output, "", 0).Printf})
	dispatcher.Enqueue(Notification{Alert: "one"})
	dispatcher.Enqueue(Notification{Alert: "two"})
	dispatcher.Enqueue(Notification{Alert: "three"})

	first, second := <-dispatcher.queue, <-dispatcher.queue
	if first.Alert != "two" || second.Alert != "three" {
		t.Fatalf("queue: %+v %+v", first, second)
	}
	if !bytes.Contains(output.Bytes(), []byte("dropping oldest")) {
		t.Fatalf("log: %q", output.String())
	}
}

func TestDispatcherFailureLogDoesNotExposeEndpointSecret(t *testing.T) {
	const endpoint = "https://hooks.example.test/services/secret-token"
	var output bytes.Buffer
	dispatcher := NewDispatcher(DeliveryOptions{
		WebhookURL: endpoint,
		HTTPClient: &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
			return nil, errors.New("connection refused")
		})},
		Backoff: time.Millisecond,
		Sleep:   func(context.Context, time.Duration) error { return nil },
		Logf:    log.New(&output, "", 0).Printf,
	})
	dispatcher.deliver(context.Background(), Notification{Alert: "dish_unreachable"})
	logged := output.String()
	if strings.Contains(logged, endpoint) || strings.Contains(logged, "secret-token") {
		t.Fatalf("secret endpoint leaked in log: %q", logged)
	}
	if !strings.Contains(logged, "dish_unreachable") || !strings.Contains(logged, "webhook") {
		t.Fatalf("log lacks safe context: %q", logged)
	}
}
