package api

import (
	"bytes"
	"image/png"
	"testing"

	"starwatch/internal/dish"
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
