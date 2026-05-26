# Markdast Performance Benchmarks

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

## Next Steps

- [ ] Phase 3-4: Periodically re-run (no expected changes during feature work)
- [ ] Phase 5: Experimental optimizations, measure delta
- [ ] Phase 6: Post-optimization baseline (expect 2-3x improvement on long documents)
