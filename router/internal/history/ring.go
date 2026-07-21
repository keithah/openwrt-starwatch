package history

import "time"

type ring struct {
	times   []int64
	values  []float32
	next    int
	count   int
	ordered bool
}

func newRing(capacity int) *ring {
	if capacity < 1 {
		capacity = 1
	}
	return &ring{times: make([]int64, capacity), values: make([]float32, capacity), ordered: true}
}

func (r *ring) append(point Point) {
	if r.count > 0 {
		previous := (r.next + len(r.times) - 1) % len(r.times)
		if point.Time.Unix() < r.times[previous] {
			r.ordered = false
		}
	}
	r.times[r.next] = point.Time.Unix()
	r.values[r.next] = point.Value
	r.next = (r.next + 1) % len(r.values)
	if r.count < len(r.values) {
		r.count++
	}
}

func (r *ring) isOrdered() bool { return r.ordered }

func (r *ring) snapshot() []Point {
	result := make([]Point, r.count)
	start := r.next - r.count
	if start < 0 {
		start += len(r.values)
	}
	for i := range result {
		index := (start + i) % len(r.values)
		result[i] = Point{Time: time.Unix(r.times[index], 0).UTC(), Value: r.values[index]}
	}
	return result
}
