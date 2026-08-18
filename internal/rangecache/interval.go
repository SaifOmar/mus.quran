package rangecache

import "sort"

// Interval is a half-open range [Start, End).
type Interval struct {
	Start int64 `json:"start"`
	End   int64 `json:"end"`
}

// Segment is one piece of a requested range: cached (servable from the .dat
// file) or missing (must be fetched from the origin).
type Segment struct {
	Start  int64
	End    int64
	Cached bool
}

// Intervals is a sorted, non-overlapping, coalesced set of half-open ranges
// (the "fetched_ranges" sidecar field).
type Intervals []Interval

// Add merges [s, e) into the set, coalescing adjacent/overlapping intervals.
func (in *Intervals) Add(s, e int64) {
	if e <= s {
		return
	}
	iv := *in
	// First interval whose End >= s (insertion point for the left edge).
	i := sort.Search(len(iv), func(i int) bool { return iv[i].End >= s })
	// A left neighbor that overlaps or is adjacent must be merged too.
	if i > 0 && iv[i-1].End >= s {
		i--
	}
	start, end := s, e
	if i < len(iv) && iv[i].Start < start {
		start = iv[i].Start
	}
	// Merge everything overlapping or adjacent [start, end].
	j := i
	for j < len(iv) && iv[j].Start <= end {
		if iv[j].End > end {
			end = iv[j].End
		}
		j++
	}
	out := make(Intervals, 0, len(iv)-(j-i)+1)
	out = append(out, iv[:i]...)
	out = append(out, Interval{Start: start, End: end})
	out = append(out, iv[j:]...)
	*in = out
}

// Contains reports whether [s, e) is fully covered by the set.
func (in Intervals) Contains(s, e int64) bool {
	if e <= s {
		return true
	}
	i := sort.Search(len(in), func(i int) bool { return in[i].End >= e })
	return i < len(in) && in[i].Start <= s
}

// Full reports whether the set covers exactly [0, size).
func (in Intervals) Full(size int64) bool {
	return len(in) == 1 && in[0].Start == 0 && in[0].End == size
}

// Bytes returns the total number of bytes covered by the set.
func (in Intervals) Bytes() int64 {
	var n int64
	for _, iv := range in {
		n += iv.End - iv.Start
	}
	return n
}

// Segments splits [s, e) into alternating cached/missing sub-ranges in byte
// order.
func (in Intervals) Segments(s, e int64) []Segment {
	if e <= s {
		return nil
	}
	var out []Segment
	pos := s
	// First interval whose End > s (may cover pos or start after it).
	i := sort.Search(len(in), func(i int) bool { return in[i].End > s })
	for pos < e {
		if i < len(in) && in[i].Start <= pos {
			end := minInt(in[i].End, e)
			out = append(out, Segment{Start: pos, End: end, Cached: true})
			pos = end
			if in[i].End <= e {
				i++
			}
		} else if i < len(in) && in[i].Start < e {
			end := minInt(in[i].Start, e)
			out = append(out, Segment{Start: pos, End: end, Cached: false})
			pos = end
		} else {
			out = append(out, Segment{Start: pos, End: e, Cached: false})
			pos = e
		}
	}
	return out
}

func minInt(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
