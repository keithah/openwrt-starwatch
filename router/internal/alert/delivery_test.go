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

func TestDispatcherDoesNotRetryTerminalWebhook4xx(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		http.Error(w, "invalid", http.StatusBadRequest)
	}))
	defer server.Close()
	var sleeps []time.Duration
	dispatcher := NewDispatcher(DeliveryOptions{
		WebhookURL: server.URL, HTTPClient: server.Client(), Backoff: time.Millisecond,
		Sleep: func(_ context.Context, duration time.Duration) error { sleeps = append(sleeps, duration); return nil },
	})
	if err := dispatcher.webhook(context.Background(), Notification{Alert: "test"}, server.URL); err == nil {
		t.Fatal("terminal 400 returned no error")
	}
	if calls.Load() != 1 || len(sleeps) != 0 {
		t.Fatalf("calls=%d sleeps=%v", calls.Load(), sleeps)
	}
}

func TestDispatcherRetriesWebhookRateLimit(t *testing.T) {
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if calls.Add(1) == 1 {
			http.Error(w, "later", http.StatusTooManyRequests)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	var sleeps []time.Duration
	dispatcher := NewDispatcher(DeliveryOptions{
		HTTPClient: server.Client(), Backoff: time.Millisecond,
		Sleep: func(_ context.Context, duration time.Duration) error { sleeps = append(sleeps, duration); return nil },
	})
	if err := dispatcher.webhook(context.Background(), Notification{Alert: "test"}, server.URL); err != nil {
		t.Fatal(err)
	}
	if calls.Load() != 2 || !reflect.DeepEqual(sleeps, []time.Duration{time.Millisecond}) {
		t.Fatalf("calls=%d sleeps=%v", calls.Load(), sleeps)
	}
}

func TestDispatcherRunDoesNotLetWebhookRetryBlockNtfy(t *testing.T) {
	retryStarted := make(chan struct{}, 1)
	releaseRetry := make(chan struct{})
	ntfyDelivered := make(chan string, 2)
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		body, _ := io.ReadAll(request.Body)
		var notification Notification
		_ = json.Unmarshal(body, &notification)
		status := http.StatusServiceUnavailable
		if request.URL.Host == "ntfy.test" {
			status = http.StatusNoContent
			ntfyDelivered <- notification.Alert
		}
		return &http.Response{StatusCode: status, Status: http.StatusText(status), Body: io.NopCloser(strings.NewReader(""))}, nil
	})}
	dispatcher := NewDispatcher(DeliveryOptions{
		WebhookURL: "https://webhook.test/hook", NtfyURL: "https://ntfy.test/topic", HTTPClient: client, QueueSize: 4,
		Sleep: func(ctx context.Context, _ time.Duration) error {
			select {
			case retryStarted <- struct{}{}:
			default:
			}
			select {
			case <-releaseRetry:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		},
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	defer close(releaseRetry)
	done := make(chan struct{})
	go func() { dispatcher.Run(ctx); close(done) }()
	dispatcher.Enqueue(Notification{Alert: "one"})
	select {
	case <-retryStarted:
	case <-time.After(time.Second):
		t.Fatal("webhook did not enter retry backoff")
	}
	dispatcher.Enqueue(Notification{Alert: "two"})
	for _, want := range []string{"one", "two"} {
		select {
		case got := <-ntfyDelivered:
			if got != want {
				t.Fatalf("ntfy delivery=%q want=%q", got, want)
			}
		case <-time.After(time.Second):
			t.Fatalf("ntfy delivery %q blocked by webhook retry", want)
		}
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("dispatcher did not stop")
	}
}
