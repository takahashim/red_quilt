# Markdast Performance Benchmarks

## v1.2.0 Inline pipeline redesign (2026-05-26, Ruby 4.0.5)

**Environment**: Ruby 4.0.5, Apple Silicon (M-series)

**Methodology**: `benchmark-ips` (5s warmup + measurement), `Markdast.parse()`

**Pipeline changes since v1.1.0**:
- InlineParser / InlineScanner replaced by a two-stage Inline::Lexer +
  Inline::Builder pipeline (see `inline-redesign.md`)
- Builder implements CommonMark spec 6.2 delimiter stack (Phase 9-B)
- Substring chain and base_offset arithmetic eliminated
- delimiter_stack / bracket_stack entries are small attr_accessor classes
  (Ruby 4.0+ attr access is faster than Symbol-keyed Hash lookup)

### Results

```
Fixture                      i/s      Time/iter   vs. short_paragraph
──────────────────────────────────────────────────────────────────────
short_paragraph         ~25,200      40 μs      1.0x (baseline)
many_links               ~1,320     760 μs     19.1x slower
long_paragraph           ~1,130     880 μs     22.3x slower
nested_emphasis            ~905    1.10 ms     27.9x slower
mixed_markup               ~885    1.13 ms     28.5x slower
deep_nesting               ~690    1.45 ms     36.7x slower
```

### v1.0.0 → v1.1.0 → v1.2.0 Speedup

| Fixture | v1.0.0 | v1.1.0 | v1.2.0 (Ruby 4.0.5) | Total speedup |
|---------|--------|--------|---------------------|---------------|
| short_paragraph | 6,586 | 10,391 | ~25,200 | **3.8x** |
| many_links | 515 | 532 | ~1,320 | **2.6x** |
| mixed_markup | 134 | 342 | ~885 | **6.6x** |
| nested_emphasis | 89 | 390 | ~905 | **10.2x** |
| deep_nesting | 69 | 222 | ~690 | **10.0x** |
| long_paragraph | 37 | 550 | ~1,130 | **30.5x** ✨ |

Notes:
- v1.0 → v1.1: pure-algorithmic + scanner improvements on Ruby 3.4.
- v1.1 → v1.2: redesigned inline pipeline (substring-free, single-instance
  Lexer / Builder, CommonMark spec 6.2 delimiter stack) plus the
  Ruby 4.0 attr_accessor performance lift.

---

## v1.1.0 Optimized (2026-05-26)

**Environment**: Ruby 3.4.1, Apple Silicon

**Methodology**: `benchmark-ips` (5s warmup + measurement), `Markdast.parse()`

**Optimizations applied**:
- Regex-based `scan_text()` (replaces per-char array search)
- Incremental delimiter counting in `find_emphasis_closing()` (O(n) vs O(n²))
- Direct index operations instead of `remaining` string copies
- Accessor methods (`char_before`, `char_at`, `match_at`, `rindex_from`) to avoid reflection/copying

### Results

```
Fixture                      i/s      Time/iter   vs. v1.0.0
──────────────────────────────────────────────────────────────
short_paragraph          10,391     96.24 μs      1.0x (baseline)
  long_paragraph            550      1.82 ms     18.87x slower
      many_links            532      1.88 ms     19.52x slower
  nested_emphasis           390      2.56 ms     26.63x slower
    mixed_markup           342      2.92 ms     30.37x slower
    deep_nesting           222      4.51 ms     46.90x slower
```

### v1.0.0 → v1.1.0 Speedup

| Fixture | v1.0.0 | v1.1.0 | Speedup |
|---------|--------|--------|---------|
| short_paragraph | 6,586 | 10,391 | **+58%** |
| many_links | 515 | 532 | +3% |
| mixed_markup | 134 | 342 | **+155% (2.5x)** |
| nested_emphasis | 89 | 390 | **+338% (4.4x)** |
| deep_nesting | 69 | 222 | **+222% (3.2x)** |
| long_paragraph | 37 | 550 | **+1,387% (14.9x)** ✨ |

---

## v1.0.0 Baseline (2026-05-26)

**Environment**: Ruby 3.4.1, Apple Silicon

**Methodology**: `benchmark-ips` (5s warmup + measurement), `Markdast.parse()`

### Results

```
Fixture                      i/s      Time/iter   vs. baseline
─────────────────────────────────────────────────────────────
short_paragraph           6,586    151.82 μs      1.0x (baseline)
many_links                  515      1.94 ms     12.77x slower
mixed_markup                134      7.46 ms     49.12x slower
nested_emphasis              89     11.14 ms     73.36x slower
deep_nesting                 69     14.40 ms     94.86x slower
long_paragraph               37     26.86 ms    176.93x slower ⚠️
```

### Fixture Descriptions

| Name | Size | Characteristics |
|------|------|-----------------|
| short_paragraph | 1 line, 50 chars | Single paragraph, basic markup (baseline) |
| many_links | 100 links | `[link](/url)` repeated 100× |
| mixed_markup | 20 sections | Headings, paragraphs, multiple formats |
| nested_emphasis | 50 nesting | `*foo **bar *baz* bim** bop*` ×50 |
| deep_nesting | 50 nesting | `*_**___***___**_*` ×50 (max nesting) |
| long_paragraph | 1500+ chars | Single paragraph, 100× "ipsum dolor" + emphasis |

### Analysis

**Critical Issues** (>10x slower):
- **long_paragraph (176x)**: Substring creation in `InlineScanner#remaining`, repeated `rindex` in `find_emphasis_closing`
- **deep_nesting (94x)**: Recursive `InlineParser.new` + substring on each nesting level
- **nested_emphasis (73x)**: Same as deep nesting, emphasis delimiter matching

**Expected Improvements** (per code review):
1. Index-based scanning (no `remaining` substring): **2-3x improvement on long_paragraph**
2. 1-pass emphasis matching: **2x improvement on nested emphasis**
3. Single-pass inline parser (reuse scanner): **1.5x improvement on deep_nesting**

---

## Measurement Commands

Run benchmarks:
```bash
ruby spec/bench_inline.rb
```

Track over time:
```bash
# Log results to git-tracked file
ruby spec/bench_inline.rb >> BENCH_LOG.txt
```

---

## Performance Optimization Summary

**v1.0 → v1.1 Results**:
- ✅ Achieved **2.5–14.9x improvement** across emphasis-heavy fixtures (target: 2–3x)
- ✅ Zero regression on `many_links` and `short_paragraph`
- ✅ All 70 CommonMark tests passing

**Optimizations are production-ready**. Next work: v1.2 features (formatter, transformer, diagnostics) or v2.0 planning.
