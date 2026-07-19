package api

import (
	"bytes"
	"errors"
	"image"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"starwatch/internal/dish"
	"starwatch/internal/history"
)

func TestObstructionPNGPixelClasses(t *testing.T) {
	var output bytes.Buffer
	grid := &dish.ObstructionMap{Rows: 2, Cols: 2, SNR: []float32{-1, 0, .5, 1}}
	if err := renderObstructionPNG(&output, grid); err != nil {
		t.Fatal(err)
	}
	image, err := png.Decode(bytes.NewReader(output.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if image.Bounds().Dx() != 2 || image.Bounds().Dy() != 2 {
		t.Fatalf("bounds: %v", image.Bounds())
	}
	_, _, _, alpha := image.At(0, 0).RGBA()
	red, green, blue, _ := image.At(1, 0).RGBA()
	if alpha != 0 || red != 0xffff || green != 0 || blue != 0 {
		t.Fatalf("transparent alpha=%x obstructed=%x/%x/%x", alpha, red, green, blue)
	}
	lowR, lowG, lowB, _ := image.At(0, 1).RGBA()
	highR, highG, highB, _ := image.At(1, 1).RGBA()
	if lowB != 0xffff || lowR == 0xffff || lowG == 0xffff || highR != 0xffff || highG != 0xffff || highB != 0xffff {
		t.Fatalf("gradient low=%x/%x/%x high=%x/%x/%x", lowR, lowG, lowB, highR, highG, highB)
	}
}

func TestObstructionPNGFailureReturnsCleanHTTPError(t *testing.T) {
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)
	grid := &dish.ObstructionMap{Rows: 2, Cols: 2, SNR: []float32{1}, FetchedAt: now}
	provider := &obstructionStub{snapshot: dish.Snapshot{
		Topology: dish.TopologyFull, DishReachable: true, ObstructionMap: grid,
	}}
	handler := NewServer(Deps{
		Token: "secret", Snapshot: provider, Obstruction: provider, History: history.NewStore(1),
		Now: func() time.Time { return now }, MapInterval: time.Minute,
	})
	defer handler.Close()
	req := httptest.NewRequest(http.MethodGet, "/api/obstruction-map", nil)
	req.Header.Set("Authorization", "Bearer secret")
	req.Header.Set("Accept", "image/png")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)

	if response.Code != http.StatusInternalServerError {
		t.Fatalf("code=%d body=%q", response.Code, response.Body.String())
	}
	if contentType := response.Header().Get("Content-Type"); strings.HasPrefix(contentType, "image/png") {
		t.Fatalf("content type=%q", contentType)
	}
}

func TestObstructionPNGEncodeFailureDoesNotAppendHTTPErrorToPartialPNG(t *testing.T) {
	original := encodeObstructionPNG
	encodeObstructionPNG = func(destination io.Writer, _ image.Image) error {
		_, _ = destination.Write([]byte("partial-png"))
		return errors.New("encode failed")
	}
	t.Cleanup(func() { encodeObstructionPNG = original })
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)
	grid := &dish.ObstructionMap{Rows: 1, Cols: 1, SNR: []float32{1}, FetchedAt: now}
	provider := &obstructionStub{snapshot: dish.Snapshot{
		Topology: dish.TopologyFull, DishReachable: true, ObstructionMap: grid,
	}}
	handler := NewServer(Deps{
		Token: "secret", Snapshot: provider, Obstruction: provider, History: history.NewStore(1),
		Now: func() time.Time { return now }, MapInterval: time.Minute,
	})
	defer handler.Close()
	req := httptest.NewRequest(http.MethodGet, "/api/obstruction-map", nil)
	req.Header.Set("Authorization", "Bearer secret")
	req.Header.Set("Accept", "image/png")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, req)

	if response.Code != http.StatusInternalServerError || strings.Contains(response.Body.String(), "partial-png") {
		t.Fatalf("code=%d body=%q", response.Code, response.Body.String())
	}
}
