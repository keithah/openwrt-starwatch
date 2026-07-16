package alert

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"
)

type DeliveryOptions struct {
	WebhookURL string
	NtfyURL    string
	HTTPClient *http.Client
	QueueSize  int
	Backoff    time.Duration
	Sleep      func(context.Context, time.Duration) error
	Logf       func(string, ...any)
}

type Dispatcher struct {
	options DeliveryOptions
	queue   chan Notification
	mu      sync.Mutex
}

func NewDispatcher(options DeliveryOptions) *Dispatcher {
	if options.HTTPClient == nil {
		options.HTTPClient = &http.Client{Timeout: 10 * time.Second}
	}
	if options.QueueSize <= 0 {
		options.QueueSize = 64
	}
	if options.Backoff <= 0 {
		options.Backoff = time.Second
	}
	if options.Sleep == nil {
		options.Sleep = sleepContext
	}
	if options.Logf == nil {
		options.Logf = log.Printf
	}
	return &Dispatcher{options: options, queue: make(chan Notification, options.QueueSize)}
}

func (d *Dispatcher) Enqueue(notification Notification) {
	d.mu.Lock()
	defer d.mu.Unlock()
	select {
	case d.queue <- notification:
		return
	default:
	}
	select {
	case dropped := <-d.queue:
		d.options.Logf("starwatchd: alert delivery queue full; dropping oldest %s notification", dropped.Alert)
	default:
	}
	select {
	case d.queue <- notification:
	default:
		d.options.Logf("starwatchd: alert delivery queue remained full; dropping %s notification", notification.Alert)
	}
}

func (d *Dispatcher) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case notification := <-d.queue:
			d.deliver(ctx, notification)
		}
	}
}

func (d *Dispatcher) deliver(ctx context.Context, notification Notification) {
	if d.options.WebhookURL != "" {
		if err := d.webhook(ctx, notification); err != nil {
			d.options.Logf("starwatchd: webhook delivery failed: %v", err)
		}
	}
	if d.options.NtfyURL != "" {
		if err := d.ntfy(ctx, notification); err != nil {
			d.options.Logf("starwatchd: ntfy delivery failed: %v", err)
		}
	}
}

func (d *Dispatcher) webhook(ctx context.Context, notification Notification) error {
	body, err := json.Marshal(notification)
	if err != nil {
		return err
	}
	var lastErr error
	for attempt := 0; attempt < 4; attempt++ {
		request, err := http.NewRequestWithContext(ctx, http.MethodPost, d.options.WebhookURL, bytes.NewReader(body))
		if err != nil {
			return err
		}
		request.Header.Set("Content-Type", "application/json")
		response, err := d.options.HTTPClient.Do(request)
		if err == nil {
			_, _ = io.Copy(io.Discard, response.Body)
			_ = response.Body.Close()
			if response.StatusCode >= 200 && response.StatusCode < 300 {
				return nil
			}
			err = fmt.Errorf("HTTP %s", response.Status)
		}
		lastErr = err
		if attempt == 3 {
			break
		}
		if err := d.options.Sleep(ctx, d.options.Backoff*time.Duration(1<<attempt)); err != nil {
			return err
		}
	}
	return lastErr
}

func (d *Dispatcher) ntfy(ctx context.Context, notification Notification) error {
	body, err := json.Marshal(notification)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, d.options.NtfyURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Title", fmt.Sprintf("Starwatch: %s %s", notification.Alert, notification.State))
	priority, tags := ntfyHeaders(notification.Severity)
	request.Header.Set("Priority", priority)
	request.Header.Set("Tags", tags)
	response, err := d.options.HTTPClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, response.Body)
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("HTTP %s", response.Status)
	}
	return nil
}

func ntfyHeaders(severity Severity) (string, string) {
	switch severity {
	case SeverityCritical:
		return "urgent", "rotating_light"
	case SeverityWarning:
		return "high", "warning"
	default:
		return "default", "information_source"
	}
}

func sleepContext(ctx context.Context, duration time.Duration) error {
	timer := time.NewTimer(duration)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
