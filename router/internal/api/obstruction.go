package api

import (
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"strings"
	"time"

	"starwatch/internal/dish"
)

func (s *server) obstructionMap(w http.ResponseWriter, r *http.Request) {
	provider := s.deps.Obstruction
	if provider == nil {
		http.Error(w, "obstruction map unavailable", http.StatusServiceUnavailable)
		return
	}
	snapshot := provider.Snapshot()
	if !snapshot.DishReachable || snapshot.Topology != dish.TopologyFull {
		http.Error(w, "dish unreachable", http.StatusServiceUnavailable)
		return
	}
	grid := snapshot.ObstructionMap
	mapInterval := s.deps.MapInterval
	if s.deps.Settings != nil {
		mapInterval = time.Duration(s.deps.Settings.View().Main.PollMap) * time.Second
	}
	if grid == nil || s.deps.Now().Sub(grid.FetchedAt) >= mapInterval {
		var err error
		grid, err = provider.RefreshObstructionMap(r.Context())
		if err != nil || grid == nil {
			http.Error(w, "dish unreachable", http.StatusServiceUnavailable)
			return
		}
	}
	if strings.Contains(r.Header.Get("Accept"), "image/png") {
		w.Header().Set("Content-Type", "image/png")
		if err := renderObstructionPNG(w, grid); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
		}
		return
	}
	writeJSON(w, http.StatusOK, grid)
}

func renderObstructionPNG(destination io.Writer, grid *dish.ObstructionMap) error {
	if grid == nil || grid.Rows == 0 || grid.Cols == 0 || uint64(grid.Rows)*uint64(grid.Cols) > uint64(len(grid.SNR)) {
		return fmt.Errorf("invalid obstruction map dimensions")
	}
	result := image.NewNRGBA(image.Rect(0, 0, int(grid.Cols), int(grid.Rows)))
	for row := 0; row < int(grid.Rows); row++ {
		for col := 0; col < int(grid.Cols); col++ {
			value := grid.SNR[row*int(grid.Cols)+col]
			var pixel color.NRGBA
			switch {
			case value < 0:
				pixel = color.NRGBA{}
			case value == 0:
				pixel = color.NRGBA{R: 255, A: 255}
			default:
				if value > 1 {
					value = 1
				}
				shade := uint8(value * 255)
				pixel = color.NRGBA{R: shade, G: shade, B: 255, A: 255}
			}
			result.SetNRGBA(col, row, pixel)
		}
	}
	return png.Encode(destination, result)
}
