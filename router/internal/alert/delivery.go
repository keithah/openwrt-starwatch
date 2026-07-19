package alert

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
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

type deliveryJob struct {
	notification Notification
	endpoint     string
}

type deliveryHTTPError struct {
	code   int
	status string
}

func (e *deliveryHTTPError) Error() string { return "HTTP " + e.status }

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

func (d *Dispatcher) SetEndpoints(webhookURL, ntfyURL string) {
	d.mu.Lock()
	d.options.WebhookURL, d.options.NtfyURL = webhookURL, ntfyURL
	d.mu.Unlock()
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
	webhookQueue := make(chan deliveryJob, cap(d.queue))
	ntfyQueue := make(chan deliveryJob, cap(d.queue))
	var workers sync.WaitGroup
	workers.Add(2)
	go func() {
		defer workers.Done()
		d.runEndpoint(ctx, "webhook", webhookQueue)
	}()
	go func() {
		defer workers.Done()
		d.runEndpoint(ctx, "ntfy", ntfyQueue)
	}()
	defer workers.Wait()
	for {
		select {
		case <-ctx.Done():
			return
		case notification := <-d.queue:
			webhookURL, ntfyURL := d.endpoints()
			if webhookURL != "" {
				d.enqueueEndpoint("webhook", webhookQueue, deliveryJob{notification: notification, endpoint: webhookURL})
			}
			if ntfyURL != "" {
				d.enqueueEndpoint("ntfy", ntfyQueue, deliveryJob{notification: notification, endpoint: ntfyURL})
			}
		}
	}
}

func (d *Dispatcher) deliver(ctx context.Context, notification Notification) {
	webhookURL, ntfyURL := d.endpoints()
	var deliveries sync.WaitGroup
	if webhookURL != "" {
		deliveries.Add(1)
		go func() {
			defer deliveries.Done()
			d.deliverEndpoint(ctx, "webhook", deliveryJob{notification: notification, endpoint: webhookURL})
		}()
	}
	if ntfyURL != "" {
		deliveries.Add(1)
		go func() {
			defer deliveries.Done()
			d.deliverEndpoint(ctx, "ntfy", deliveryJob{notification: notification, endpoint: ntfyURL})
		}()
	}
	deliveries.Wait()
}

func (d *Dispatcher) endpoints() (string, string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.options.WebhookURL, d.options.NtfyURL
}

func (d *Dispatcher) runEndpoint(ctx context.Context, kind string, jobs <-chan deliveryJob) {
	for {
		select {
		case <-ctx.Done():
			return
		case job := <-jobs:
			d.deliverEndpoint(ctx, kind, job)
		}
	}
}

func (d *Dispatcher) deliverEndpoint(ctx context.Context, kind string, job deliveryJob) {
	var err error
	if kind == "webhook" {
		err = d.webhook(ctx, job.notification, job.endpoint)
	} else {
		err = d.ntfy(ctx, job.notification, job.endpoint)
	}
	if err != nil && ctx.Err() == nil {
		d.logf("starwatchd: %s delivery failed for %s: %s", kind, job.notification.Alert, safeDeliveryError(err))
	}
}

func (d *Dispatcher) enqueueEndpoint(kind string, queue chan deliveryJob, job deliveryJob) {
	select {
	case queue <- job:
		return
	default:
	}
	select {
	case dropped := <-queue:
		d.logf("starwatchd: %s delivery queue full; dropping oldest %s notification", kind, dropped.notification.Alert)
	default:
	}
	select {
	case queue <- job:
	default:
		d.logf("starwatchd: %s delivery queue remained full; dropping %s notification", kind, job.notification.Alert)
	}
}

func (d *Dispatcher) logf(format string, args ...any) {
	d.mu.Lock()
	d.options.Logf(format, args...)
	d.mu.Unlock()
}

func safeDeliveryError(err error) string {
	var statusError *deliveryHTTPError
	if errors.As(err, &statusError) {
		return statusError.Error()
	}
	var requestError *url.Error
	if errors.As(err, &requestError) {
		switch {
		case errors.Is(requestError.Err, context.DeadlineExceeded):
			return "request timed out"
		case errors.Is(requestError.Err, context.Canceled):
			return "request canceled"
		default:
			return "network request failed"
		}
	}
	return fmt.Sprintf("%T", err)
}

func retryableDeliveryError(err error) bool {
	var statusError *deliveryHTTPError
	if errors.As(err, &statusError) {
		return statusError.code == http.StatusTooManyRequests || statusError.code >= http.StatusInternalServerError
	}
	var requestError *url.Error
	return errors.As(err, &requestError)
}

func (d *Dispatcher) webhook(ctx context.Context, notification Notification, endpoint string) error {
	body, err := json.Marshal(notification)
	if err != nil {
		return err
	}
	var lastErr error
	for attempt := 0; attempt < 4; attempt++ {
		request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
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
			err = &deliveryHTTPError{code: response.StatusCode, status: response.Status}
		}
		lastErr = err
		if attempt == 3 || !retryableDeliveryError(err) {
			break
		}
		if err := d.options.Sleep(ctx, d.options.Backoff*time.Duration(1<<attempt)); err != nil {
			return err
		}
	}
	return lastErr
}

func (d *Dispatcher) ntfy(ctx context.Context, notification Notification, endpoint string) error {
	body, err := json.Marshal(notification)
	if err != nil {
		return err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
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
		return &deliveryHTTPError{code: response.StatusCode, status: response.Status}
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
