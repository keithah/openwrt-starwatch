package api

import (
	"errors"
	"fmt"
	"net/http"
	"time"

	diagnosticspkg "starwatch/internal/diagnostics"
	"starwatch/internal/history"
	"starwatch/internal/outage"
)

func (s *server) diagnostics(w http.ResponseWriter, r *http.Request) {
	spanText := r.URL.Query().Get("span")
	if spanText == "" {
		spanText = "3h"
	}
	span, err := parseSpan(spanText)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	now := s.deps.Now()
	since := now.Add(-span)
	latency, err := s.queryDiagnosticSeries(history.LatencyMS, since, span)
	if err != nil {
		s.writeDiagnosticsError(w, err)
		return
	}
	power, err := s.queryDiagnosticSeries(history.PowerW, since, span)
	if err != nil {
		s.writeDiagnosticsError(w, err)
		return
	}
	var battery diagnosticspkg.BatteryInput
	var batteryPower history.QueryResult
	if s.deps.Settings != nil {
		view := s.deps.Settings.View().Battery
		battery = diagnosticspkg.BatteryInput{
			Enabled: view.Enabled, CapacityWh: view.CapacityWh, StateOfChargePercent: view.StateOfChargePercent,
			ReservePercent: view.ReservePercent, ConversionEfficiencyPercent: view.ConversionEfficiencyPercent,
		}
		if view.StateOfChargeUpdatedAt != nil {
			battery.StateOfChargeUpdatedAt = *view.StateOfChargeUpdatedAt
		}
		if battery.Enabled {
			if span == 15*time.Minute {
				batteryPower = power
			} else {
				batteryPower, err = s.queryDiagnosticSeries(history.PowerW, now.Add(-15*time.Minute), 15*time.Minute)
				if err != nil {
					s.writeDiagnosticsError(w, err)
					return
				}
			}
		}
	}
	snapshot := s.deps.Snapshot.Snapshot()
	wanSnapshot := snapshot.WAN
	if s.deps.WAN != nil {
		wanSnapshot = s.deps.WAN.Snapshot()
	}
	var outages []outage.Entry
	if s.deps.Outages != nil {
		outages, err = s.deps.Outages.Query(since, 0)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
	writeJSON(w, http.StatusOK, diagnosticspkg.Summarize(diagnosticspkg.Input{
		Span: spanText, Now: now, Since: since, Latency: latency, Power: power,
		Snapshot: snapshot, WAN: wanSnapshot, Outages: outages, Battery: battery, BatteryPower: batteryPower,
	}))
}

func (s *server) queryDiagnosticSeries(series string, since time.Time, span time.Duration) (history.QueryResult, error) {
	if s.deps.History == nil {
		return history.QueryResult{Tier: history.TierRAM}, nil
	}
	return s.deps.History.QuerySpan(series, since, span, 0)
}

func (s *server) writeDiagnosticsError(w http.ResponseWriter, err error) {
	if errors.Is(err, history.ErrUnknownSeries) {
		http.Error(w, fmt.Sprintf("unknown diagnostic series: %v", err), http.StatusBadRequest)
		return
	}
	http.Error(w, err.Error(), http.StatusInternalServerError)
}
