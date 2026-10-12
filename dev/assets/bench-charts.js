/* lockfreequeues bench charts — ECharts wiring for docs/benchmarks.md.
 *
 * Loads the merged Bencher Metric Format (BMF) snapshot from
 * `../assets/bench-results/latest.json` — page lives at
 * `/<version>/benchmarks/` under mike + mkdocs `use_directory_urls`,
 * so we go up one level to reach `/<version>/assets/`. The same
 * relative path works under /dev/, /latest/, and /v*\/ aliases.
 *
 * Rendering: Apache ECharts 5.x via CDN. We use the `dark` theme as a
 * baseline and override foreground/background/grid colors with the
 * mkdocs Material palette CSS variables so the charts pick up both
 * dark and light schemes. We listen for the Material color-scheme
 * attribute on `<body>` and re-paint when it flips.
 *
 * Page architecture (multi-panel):
 *   #bench-hero                       — ECharts horizontal bar at a
 *                                       canonical shape (lfq vs alts)
 *   #bench-throughput-spsc            — line chart, SPSC topology
 *   #bench-throughput-mpsc            — line chart, MPSC topology
 *   #bench-throughput-mpmc-bounded    — line chart, MPMC bounded
 *   #bench-throughput-mpmc-unbounded  — line chart, MPMC unbounded
 *   #bench-latency                    — line chart, percentile ladder
 *   #bench-status                     — banner injected on fallback
 *
 * Slug shape: `<library>/<topology>/<P>p<C>c`.
 *
 * BMF measure shape: `{ value, lower_value?, upper_value? }`.
 *
 * Failure modes (graceful):
 *   - latest.json fetch fails or returns _status: "fallback" -> try
 *     example.json fixture and surface a status banner.
 *   - fixture also unavailable -> error banner; panels show empty state.
 *   - ECharts global missing -> per-panel message; hero falls back to
 *     a hand-rendered DOM bar list so the headline still reads.
 */

(function () {
  'use strict';

  // ── module: constants ───────────────────────────────────────────────
  const SNAPSHOT_URL  = '../assets/bench-results/latest.json';
  const FIXTURE_URL   = '../assets/bench-results/example.json';
  const CHART_MEASURE = 'throughput_ops_ms';
  const CHART_HEIGHT  = 360;

  // CONTRACT-TEST-PARSED-START LIBRARY_COLORS
  const LIBRARY_COLORS = Object.freeze({
    // lockfree queue family (bounded) — Material indigo 500
    lockfree_spsc:           '#3f51b5',
    lockfree_spmc:           '#3f51b5',
    lockfree_mpsc:           '#3f51b5',
    lockfree_mpmc:           '#3f51b5',
    // lockfree queue family (unbounded) — Material indigo 400
    lockfree_unbounded_spsc: '#5c6bc0',
    lockfree_unbounded_spmc: '#5c6bc0',
    lockfree_unbounded_mpsc: '#5c6bc0',
    lockfree_unbounded_mpmc: '#5c6bc0',
    // associative maps & sets
    ctrie:                   '#3f51b5',
    skiplist:                '#00897b',
    locked_table:            '#78909c',
    // stacks & deques
    treiber_stack:           '#3f51b5',
    locked_stack:            '#78909c',
    chase_lev_deque:         '#8e24aa',
    // broadcast ring
    broadcast_ring_drop:     '#3f51b5',
    broadcast_ring_backoff:  '#0277bd',
    // rate limiting & streaming
    token_bucket:            '#e65100',
    stream_ring:             '#2e7d32',
    // comparison libraries — distinct stable colors
    crossbeam_array_queue:           '#f4511e',
    crossbeam_seg_queue:             '#fb8c00',
    moodycamel:                      '#43a047',
    boost_lockfree_queue:            '#00897b',
    boost_lockfree_spsc:             '#00897b',
    loony:                           '#8e24aa',
    threading_channels:              '#6d4c41',
    nim_channel:                     '#546e7a',
    nim_channels:                    '#546e7a',
    atomic_queue:                    '#2e7d32',
    rigtorp_mpmc:                    '#1565c0',
    rigtorp_spsc:                    '#0277bd',
    flume:                           '#d84315',
    kanal:                           '#c2185b',
    liblfds:                         '#455a64',
  });
  // CONTRACT-TEST-PARSED-END LIBRARY_COLORS

  // CONTRACT-TEST-PARSED-START BLOCKING_LIBRARIES
  const BLOCKING_LIBRARIES = [
    'threading_channels', 'nim_channel', 'nim_channels',
    'locked_table', 'locked_stack', 'broadcast_ring_backoff',
  ];
  // CONTRACT-TEST-PARSED-END BLOCKING_LIBRARIES
  const BLOCKING_SET = new Set(BLOCKING_LIBRARIES);

  const LOCKFREE_FAMILY = [
    'lockfree_spsc', 'lockfree_spmc',
    'lockfree_mpsc', 'lockfree_mpmc',
    'lockfree_unbounded_spsc', 'lockfree_unbounded_spmc',
    'lockfree_unbounded_mpsc', 'lockfree_unbounded_mpmc',
    'ctrie', 'skiplist', 'treiber_stack', 'chase_lev_deque',
    'broadcast_ring_drop', 'broadcast_ring_backoff', 'token_bucket', 'stream_ring',
  ];
  const LFQ_FAMILY_SET = new Set(LOCKFREE_FAMILY);

  const LIBRARY_ECOSYSTEMS = Object.freeze({
    // Nim native & stdlib
    lockfree_spsc: 'nim', lockfree_spmc: 'nim', lockfree_mpsc: 'nim', lockfree_mpmc: 'nim',
    lockfree_unbounded_spsc: 'nim', lockfree_unbounded_spmc: 'nim',
    lockfree_unbounded_mpsc: 'nim', lockfree_unbounded_mpmc: 'nim',
    nim_channel: 'nim', nim_channels: 'nim', threading_channels: 'nim', loony: 'nim',
    ctrie: 'nim', skiplist: 'nim', locked_table: 'nim',
    treiber_stack: 'nim', locked_stack: 'nim', chase_lev_deque: 'nim',
    broadcast_ring_drop: 'nim', broadcast_ring_backoff: 'nim',
    token_bucket: 'nim', stream_ring: 'nim',
    // C++
    moodycamel: 'cpp', boost_lockfree_queue: 'cpp', boost_lockfree_spsc: 'cpp',
    atomic_queue: 'cpp', rigtorp_mpmc: 'cpp', rigtorp_spsc: 'cpp',
    // Rust
    crossbeam_array_queue: 'rust', crossbeam_seg_queue: 'rust',
    flume: 'rust', kanal: 'rust',
    // C
    liblfds: 'c',
  });


  let _activeEcosystem = 'all'; // 'all' | 'nim' | 'cpp' | 'rust'
  let _activeHeroShape = null;  // null (auto) | '4p4c' | '2p2c' | '4p1c' | '1p1c'
  let _activeDisplayMode = 'absolute'; // 'absolute' | 'relative'
  let _currentBmfResult = null;

  function matchesEcosystem(library) {
    if (_activeEcosystem === 'all') return true;
    if (isLockfreequeues(library)) return true;
    const eco = LIBRARY_ECOSYSTEMS[library];
    return eco === _activeEcosystem;
  }

  const HERO_SHAPE_PREFERENCE = [
    { topology: 'mpmc', shape: '4p4c' },
    { topology: 'mpmc', shape: '2p2c' },
    { topology: 'mpsc', shape: '4p1c' },
    { topology: 'spsc', shape: '1p1c' },
  ];

  const TOPOLOGY_LABELS = Object.freeze({
    spsc: 'SPSC',
    mpsc: 'MPSC',
    mpmc: 'MPMC',
    spsc_unbounded: 'SPSC (unbounded)',
    mpsc_unbounded: 'MPSC (unbounded)',
    mpmc_unbounded: 'MPMC (unbounded)',
    stack_mpmc: 'MPMC Stack',
    read_heavy: 'Read-Heavy (90/10)',
    balanced: 'Balanced (50/50)',
    write_heavy: 'Write-Heavy (10/90)',
    work_stealing: 'Work-Stealing',
    fanout: '1-to-N Fan-Out',
    contention: 'Contention',
    spsc_chunk: 'SPSC Chunk Streaming',
  });

  function topologyLabel(topology) {
    return TOPOLOGY_LABELS[topology] || topology.toUpperCase();
  }

  function isBoundedTopology(topology) {
    return !topology.endsWith('_unbounded');
  }

  const THROUGHPUT_PANELS = [
    { id: 'bench-throughput-spsc',           label: 'SPSC',
      includes: (topology) => topology === 'spsc'
                              || topology === 'spsc_unbounded' },
    { id: 'bench-throughput-mpsc',           label: 'MPSC',
      includes: (topology) => topology === 'mpsc'
                              || topology === 'mpsc_unbounded' },
    { id: 'bench-throughput-mpmc-bounded',   label: 'MPMC (bounded)',
      includes: (topology) => topology === 'mpmc' },
    { id: 'bench-throughput-mpmc-unbounded', label: 'MPMC (unbounded)',
      includes: (topology) => topology === 'mpmc_unbounded' },
    // Maps & Sets
    { id: 'bench-maps-read-heavy',           label: 'Read-Heavy (90/10)',
      includes: (topology) => topology === 'read_heavy' },
    { id: 'bench-maps-balanced',             label: 'Balanced (50/50)',
      includes: (topology) => topology === 'balanced' },
    { id: 'bench-maps-write-heavy',          label: 'Write-Heavy (10/90)',
      includes: (topology) => topology === 'write_heavy' },
    // Stacks & Deques
    { id: 'bench-stacks-mpmc',               label: 'MPMC Stack Contention',
      includes: (topology) => topology === 'stack_mpmc' },
    { id: 'bench-deques-work-stealing',      label: 'Work-Stealing Deque',
      includes: (topology) => topology === 'work_stealing' },
    // Broadcast Ring
    { id: 'bench-broadcast-fanout',          label: '1-to-N Multicast Fan-Out',
      includes: (topology) => topology === 'fanout' },
    // Rate Limiting & Streaming
    { id: 'bench-tokenbucket-contention',    label: 'TokenBucket Contention',
      includes: (topology) => topology === 'contention' },
    { id: 'bench-streambuffer-throughput',   label: 'StreamRing SPSC Bandwidth',
      includes: (topology) => topology === 'spsc_chunk' },
  ];

  // Source-code links per panel container id. Each panel heading gets
  // a small superscript-style anchor pointing at the bench binary that
  // produces the topology's slugs. Keep this map in sync with the
  // `benchmarks/nim/` bench harness — adding a new panel here without
  // a real source target produces a broken link.
  const BENCH_SOURCE_URLS = Object.freeze({
    'bench-throughput-spsc':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_spsc.nim',
    'bench-throughput-mpsc':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_mpsc.nim',
    'bench-throughput-mpmc-bounded':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_mpmc_bounded.nim',
    'bench-throughput-mpmc-unbounded':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_unbounded_mpmc.nim',
    'bench-latency':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_latency.nim',
    'bench-maps-read-heavy':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_maps.nim',
    'bench-maps-balanced':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_maps.nim',
    'bench-maps-write-heavy':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_maps.nim',
    'bench-stacks-mpmc':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_stacks_deques.nim',
    'bench-deques-work-stealing':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_stacks_deques.nim',
    'bench-broadcast-fanout':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_broadcast.nim',
    'bench-tokenbucket-contention':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_ratelimit_streaming.nim',
    'bench-streambuffer-throughput':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_ratelimit_streaming.nim',
  });

  // Build the small "↗ source" anchor next to a panel heading. Uses
  // Material foreground--light for muted contrast and opens in a new
  // tab. Safe to call multiple times for the same panel — the helper
  // is idempotent via a `data-bench-source-link` marker.
  function buildSourceLink(panelId) {
    const url = BENCH_SOURCE_URLS[panelId];
    if (!url) return null;
    return el('a', {
      class: 'bench-source-link',
      href: url,
      target: '_blank',
      rel: 'noopener noreferrer',
      title: 'View benchmark source on GitHub',
    }, '↗ source');
  }

  function appendSourceLink(headingNode, panelId) {
    if (!headingNode || !panelId) return;
    if (headingNode.querySelector('.bench-source-link')) return;
    const link = buildSourceLink(panelId);
    if (link) headingNode.appendChild(link);
  }

  // Locate the markdown-rendered heading (h3/h4/h5/h6) that immediately
  // precedes a panel container, walking up siblings through `<div>`
  // wrappers that mkdocs injects for `markdown="0"` blocks. Returns
  // null if no heading is found within a small lookback budget.
  function findPrecedingHeading(panelNode) {
    let node = panelNode;
    // Walk up through wrapping divs until we find a heading sibling.
    for (let hop = 0; hop < 4 && node; hop += 1) {
      let sib = node.previousElementSibling;
      while (sib) {
        if (/^H[1-6]$/.test(sib.tagName)) return sib;
        // Skip over noscript/script/empty wrappers but stop on
        // anything substantive.
        if (sib.tagName !== 'SCRIPT' && sib.tagName !== 'NOSCRIPT') {
          // A non-heading substantive sibling means the heading is
          // not directly before this panel; bubble up to the parent.
          break;
        }
        sib = sib.previousElementSibling;
      }
      node = node.parentElement;
    }
    return null;
  }

  const FALLBACK_PALETTE = [
    '#7eb6ff', '#ff9f7e', '#9ee37e', '#d77eff', '#ffeb7e',
    '#7effd9', '#ff7e9c', '#bfff7e', '#7e9cff', '#ffb87e',
  ];
  let _fallbackIdx = 0;
  const _fallbackAssigned = new Map();

  function getColor(library) {
    if (LIBRARY_COLORS[library]) return LIBRARY_COLORS[library];
    if (_fallbackAssigned.has(library)) return _fallbackAssigned.get(library);
    console.warn(
      "[bench-charts] library '" + library +
      "' has no entry in LIBRARY_COLORS; falling back to palette[" +
      (_fallbackIdx % FALLBACK_PALETTE.length) +
      "]. Add it to LIBRARY_COLORS in docs/assets/bench-charts.js."
    );
    const c = FALLBACK_PALETTE[_fallbackIdx % FALLBACK_PALETTE.length];
    _fallbackIdx += 1;
    _fallbackAssigned.set(library, c);
    return c;
  }

  function isBlocking(library) { return BLOCKING_SET.has(library); }
  function isLockfree(library) {
    return LFQ_FAMILY_SET.has(library) || library.startsWith('lockfree_');
  }
  const isLockfreequeues = isLockfree;
  function displayLabel(library) {
    return library + (isBlocking(library) ? ' *' : '');
  }

  // ── module: helpers ─────────────────────────────────────────────────

  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const k in attrs) {
        if (k === 'class') node.className = attrs[k];
        else if (k === 'style') node.setAttribute('style', attrs[k]);
        else node.setAttribute(k, attrs[k]);
      }
    }
    for (const c of children) {
      if (c == null) continue;
      node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    }
    return node;
  }

  function parseSlug(slug) {
    const parts = slug.split('/');
    if (parts.length < 3) return null;
    const library = parts[0];
    const topology = parts.slice(1, -1).join('/');
    const shape = parts[parts.length - 1];
    let p = 0, c = 0, totalThreads = 0;
    const mPC = /^(\d+)p(\d+)c$/.exec(shape);
    const mT = /^(\d+)t$/.exec(shape);
    const mWT = /^(\d+)w(\d+)t$/.exec(shape);
    if (mPC) {
      p = parseInt(mPC[1], 10);
      c = parseInt(mPC[2], 10);
      totalThreads = p + c;
    } else if (mT) {
      totalThreads = parseInt(mT[1], 10);
      p = totalThreads;
      c = 0;
    } else if (mWT) {
      p = parseInt(mWT[1], 10);
      c = parseInt(mWT[2], 10);
      totalThreads = p + c;
    } else {
      totalThreads = 1;
    }
    return { library, topology, shape, p, c, totalThreads };
  }

  function parseByteSize(label) {
    const m = /^(\d+)(b|kb|mb|gb)$/i.exec(label);
    if (!m) return -1;
    const num = parseInt(m[1], 10);
    const unit = m[2].toLowerCase();
    if (unit === 'b') return num;
    if (unit === 'kb') return num * 1024;
    if (unit === 'mb') return num * 1024 * 1024;
    if (unit === 'gb') return num * 1024 * 1024 * 1024;
    return num;
  }

  function sortShapeLabels(labels) {
    return Array.from(labels)
      .map((label) => {
        const mPC = /^(\d+)p(\d+)c$/.exec(label);
        const mT = /^(\d+)t$/.exec(label);
        const mWT = /^(\d+)w(\d+)t$/.exec(label);
        const bytes = parseByteSize(label);
        if (mPC) {
          const p = parseInt(mPC[1], 10);
          const c = parseInt(mPC[2], 10);
          return { label, p, c, total: p + c, bytes: -1 };
        }
        if (mT) {
          const t = parseInt(mT[1], 10);
          return { label, p: t, c: 0, total: t, bytes: -1 };
        }
        if (mWT) {
          const w = parseInt(mWT[1], 10);
          const t = parseInt(mWT[2], 10);
          return { label, p: w, c: t, total: w + t, bytes: -1 };
        }
        if (bytes >= 0) {
          return { label, p: 0, c: 0, total: 0, bytes };
        }
        return { label, p: -1, c: -1, total: -1, bytes: -1 };
      })
      .sort((a, b) => {
        if (a.bytes >= 0 && b.bytes >= 0) return a.bytes - b.bytes;
        if (a.total === -1 && b.total === -1) return a.label.localeCompare(b.label);
        if (a.total === -1) return -1;
        if (b.total === -1) return 1;
        return (a.total - b.total) || (a.p - b.p) || (a.c - b.c);
      })
      .map((item) => item.label);
  }


  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  // ── module: Material palette wiring ────────────────────────────────
  //
  // ECharts theme is `dark`/`light`-baseline; we override the visible
  // chrome (text, axis lines, splitlines, tooltip) with the mkdocs
  // Material palette CSS variables so charts match body text regardless
  // of scheme. We read computed style on `<body>` to resolve the
  // variables — ECharts wants actual color strings, not `var(...)`.
  function readPalette() {
    const cs = getComputedStyle(document.body);
    const get = (name, fallback) => {
      const v = cs.getPropertyValue(name).trim();
      return v || fallback;
    };
    return {
      fg:        get('--md-default-fg-color',           '#e8e8ea'),
      fgLight:   get('--md-default-fg-color--light',    '#aaaaaa'),
      fgLightest: get('--md-default-fg-color--lightest', '#444444'),
      bg:        get('--md-default-bg-color',           '#1a1a1d'),
      codeBg:    get('--md-code-bg-color',              '#23232a'),
    };
  }

  function currentScheme() {
    return document.body.getAttribute('data-md-color-scheme') || 'default';
  }

  function isLightScheme() {
    // mkdocs Material: default | slate (slate == dark). `default` is light.
    return currentScheme() !== 'slate';
  }

  // Build a partial ECharts option that styles axes/tooltip/legend with
  // the current Material palette. Merged into every chart's option so
  // the theme switch only needs to re-call `setOption(buildPaletteOpt())`.
  function buildPaletteOpt() {
    const p = readPalette();
    return {
      backgroundColor: 'transparent',
      textStyle:       { color: p.fg },
      title:           { textStyle: { color: p.fg } },
      legend:          {
        textStyle: { color: p.fg },
        inactiveColor: p.fgLightest,
      },
      tooltip: {
        backgroundColor: p.bg,
        borderColor:     p.fgLightest,
        textStyle:       { color: p.fg },
        extraCssText:    'box-shadow: 0 2px 8px rgba(0,0,0,0.3);',
      },
      xAxis: {
        axisLine:  { lineStyle: { color: p.fgLight } },
        axisLabel: { color: p.fg },
        axisTick:  { lineStyle: { color: p.fgLight } },
        splitLine: { lineStyle: { color: p.fgLightest } },
        nameTextStyle: { color: p.fgLight },
      },
      yAxis: {
        axisLine:  { lineStyle: { color: p.fgLight } },
        axisLabel: { color: p.fg },
        axisTick:  { lineStyle: { color: p.fgLight } },
        splitLine: { lineStyle: { color: p.fgLightest } },
        nameTextStyle: { color: p.fgLight },
      },
    };
  }

  // Registry of live ECharts instances + their option builders, so we
  // can re-apply the palette on color-scheme flip and resize on
  // window resize.
  const _charts = [];
  function registerChart(instance, rebuild) {
    _charts.push({ instance, rebuild });
  }

  function repaintAllForScheme() {
    for (const entry of _charts) {
      try {
        // Disposing and rebuilding is simpler than diffing every
        // sub-option for theme baseline. The data pipeline is cheap.
        entry.rebuild();
      } catch (err) {
        console.warn('[bench-charts] re-render failed', err);
      }
    }
  }

  function resizeAll() {
    for (const entry of _charts) {
      try { entry.instance.resize(); } catch (_) { /* noop */ }
    }
  }

  function clearRegisteredCharts() {
    for (const entry of _charts) {
      try {
        if (entry.instance && typeof entry.instance.isDisposed === 'function' && !entry.instance.isDisposed()) {
          entry.instance.dispose();
        }
      } catch (_) { /* noop */ }
    }
    _charts.length = 0;
  }

  // ── module: data ────────────────────────────────────────────────────

  function isMeasurementSlug(slug) {
    if (typeof slug !== 'string') return false;
    if (slug.startsWith('_')) return false;
    if (slug === 'meta') return false;
    return true;
  }

  function groupByTopology(bmf) {
    const byTopology = new Map();
    for (const slug in bmf) {
      if (!Object.prototype.hasOwnProperty.call(bmf, slug)) continue;
      if (!isMeasurementSlug(slug)) continue;
      const measureMap = bmf[slug];
      if (!measureMap || typeof measureMap !== 'object') continue;
      const m = measureMap[CHART_MEASURE];
      if (!m || typeof m.value !== 'number' || !Number.isFinite(m.value)) continue;
      const parsed = parseSlug(slug);
      if (!parsed) continue;
      let libsByShape = byTopology.get(parsed.topology);
      if (!libsByShape) {
        libsByShape = new Map();
        byTopology.set(parsed.topology, libsByShape);
      }
      let shapeMap = libsByShape.get(parsed.library);
      if (!shapeMap) {
        shapeMap = new Map();
        libsByShape.set(parsed.library, shapeMap);
      }
      shapeMap.set(parsed.shape, {
        value: m.value,
        lower: typeof m.lower_value === 'number' ? m.lower_value : null,
        upper: typeof m.upper_value === 'number' ? m.upper_value : null,
        slug: slug,
        p: parsed.p,
        c: parsed.c,
      });
    }
    return byTopology;
  }

  // ── module: hero selection ──────────────────────────────────────────

  function pickHeroShape(byTopology) {
    if (_activeHeroShape) {
      const topo = (_activeHeroShape === '1p1c') ? 'spsc' :
                   (_activeHeroShape === '4p1c') ? 'mpsc' : 'mpmc';
      return { topology: topo, shape: _activeHeroShape };
    }
    for (const pref of HERO_SHAPE_PREFERENCE) {
      const inTopology = byTopology.get(pref.topology);
      if (!inTopology) continue;
      let hasLfq = false, hasAlt = false;
      for (const [library, shapeMap] of inTopology.entries()) {
        const m = shapeMap.get(pref.shape);
        if (!m || typeof m.value !== 'number') continue;
        if (isLockfreequeues(library)) hasLfq = true;
        else hasAlt = true;
        if (hasLfq && hasAlt) return pref;
      }
    }
    return findFallbackHeroShape(byTopology);
  }

  function findFallbackHeroShape(byTopology) {
    let best = null, bestScore = 0;
    for (const [topology, libsByShape] of byTopology) {
      if (!isBoundedTopology(topology)) continue;
      const byShape = new Map();
      for (const [library, shapeMap] of libsByShape) {
        for (const [shape, mv] of shapeMap) {
          if (!mv || typeof mv.value !== 'number') continue;
          if (!byShape.has(shape)) byShape.set(shape, new Map());
          byShape.get(shape).set(library, mv);
        }
      }
      for (const [shape, libs] of byShape) {
        let lfq = 0, alt = 0;
        for (const libName of libs.keys()) {
          if (libName.startsWith('lockfree_')) lfq++;
          else alt++;
        }
        if (lfq >= 1 && alt >= 1) {
          const score = lfq + alt;
          if (score > bestScore) {
            bestScore = score;
            best = { topology, shape };
          }
        }
      }
    }
    return best;
  }

  // ── module: hero panel (ECharts horizontal bar) ─────────────────────

  function renderHero(host, byTopology) {
    host.innerHTML = '';
    const pick = pickHeroShape(byTopology);
    if (!pick) {
      host.appendChild(el('h3', { class: 'bench-hero-heading' },
        'Throughput at a glance'));
      host.appendChild(el('p', { class: 'bench-hero-empty' },
        'No comparable cross-library data at any shape — see throughput panels below.'));
      return;
    }
    const inTopology = byTopology.get(pick.topology);
    const rows = [];
    for (const [library, shapeMap] of inTopology.entries()) {
      if (!matchesEcosystem(library)) continue;
      const mv = shapeMap.get(pick.shape);
      if (!mv || typeof mv.value !== 'number') continue;
      rows.push({
        library, value: mv.value, lower: mv.lower, upper: mv.upper,
        slug: mv.slug,
      });
    }
    if (rows.length === 0) {
      host.appendChild(el('p', { class: 'bench-hero-empty' },
        'No data matching the selected ecosystem at the chosen hero shape.'));
      return;
    }

    // Order: lockfreequeues first (by value desc), then alts (by value desc).
    rows.sort((a, b) => {
      const aLfq = isLockfreequeues(a.library) ? 0 : 1;
      const bLfq = isLockfreequeues(b.library) ? 0 : 1;
      if (aLfq !== bLfq) return aLfq - bLfq;
      return b.value - a.value;
    });

    let baselineVal = null;
    if (_activeDisplayMode === 'relative') {
      const baseRow = rows.find((r) => r.library === 'nim_channels' || r.library === 'nim_channel');
      if (baseRow && baseRow.value > 0) {
        baselineVal = baseRow.value;
      }
    }

    const hasAlt = rows.some((r) => !isLockfreequeues(r.library));
    const modeDesc = baselineVal ? ' — speedup vs stdlib' : '';
    const headingText = topologyLabel(pick.topology) + ' ' + pick.shape +
      (hasAlt ? ' — lockfree vs alternatives' : ' — lockfree throughput') + modeDesc;
    host.appendChild(el('h3', { class: 'bench-hero-heading' }, headingText));

    if (typeof window.echarts !== 'object' || !window.echarts.init) {
      // Fallback: hand-rendered DOM bars so the headline still reads.
      renderHeroDomFallback(host, rows, pick);
      return;
    }

    const mount = el('div', { class: 'bench-chart-plot bench-chart-plot-hero' });
    host.appendChild(mount);
    const sawBlocking = rows.some((r) => isBlocking(r.library));
    if (sawBlocking) {
      host.appendChild(el('p', { class: 'bench-hero-footnote' },
        'Dotted-edge bars mark libraries that block on full; throughput ' +
        'reflects blocking semantics, not the non-blocking try_push path.'));
    }

    const build = () => {
      const inst = window.echarts.init(
        mount, isLightScheme() ? null : 'dark',
        { renderer: 'canvas' }
      );
      const categories = rows.map((r) => r.library);
      const values = rows.map((r) => {
        const displayVal = baselineVal ? (r.value / baselineVal) : r.value;
        return {
          value: displayVal,
          itemStyle: {
            color: getColor(r.library),
            borderColor: getColor(r.library),
            borderType: isBlocking(r.library) ? 'dashed' : 'solid',
            borderWidth: isBlocking(r.library) ? 2 : 0,
            opacity: isBlocking(r.library) ? 0.55 : 1,
          },
          _row: r,
          _displayVal: displayVal,
        };
      });
      const opt = Object.assign({}, buildPaletteOpt(), {
        grid: { left: 160, right: 80, top: 16, bottom: 36, containLabel: true },
        tooltip: Object.assign({}, buildPaletteOpt().tooltip, {
          trigger: 'axis',
          axisPointer: { type: 'shadow' },
          formatter: (params) => {
            if (!params || !params.length) return '';
            const p = params[0];
            const r = p.data && p.data._row;
            if (!r) return '';
            let line = '<strong>' + escapeHtml(r.library) + '</strong><br>' +
              r.value.toFixed(1) + ' ops/ms';
            if (baselineVal) {
              const speedup = (r.value / baselineVal).toFixed(1);
              line += ' <strong>(' + speedup + 'x vs stdlib)</strong>';
            }
            if (r.lower != null && r.upper != null) {
              const stddev = (r.upper - r.lower) / 2;
              line += ' (±' + stddev.toFixed(1) + ')';
            }
            line += '<br>' + escapeHtml(topologyLabel(pick.topology)) +
              ' ' + escapeHtml(pick.shape);
            if (isBlocking(r.library)) line += ' (blocking)';
            return line;
          },
        }),
        xAxis: Object.assign({}, buildPaletteOpt().xAxis, {
          type: 'value',
          name: baselineVal ? 'relative speedup (x vs stdlib Channel)' : 'throughput (ops/ms)',
          nameLocation: 'middle',
          nameGap: 28,
        }),
        yAxis: Object.assign({}, buildPaletteOpt().yAxis, {
          type: 'category',
          data: categories,
          inverse: true,
        }),
        series: [{
          type: 'bar',
          data: values,
          barCategoryGap: '30%',
          label: {
            show: true, position: 'right',
            formatter: (p) => baselineVal ? p.value.toFixed(1) + 'x' : p.value.toFixed(1),
            color: readPalette().fg,
          },
        }],
      });
      inst.setOption(opt);
      return inst;
    };
    const inst = build();
    registerChart(inst, () => {
      inst.dispose();
      const fresh = build();
      // Swap registry entry's instance so subsequent rebuilds use the
      // current one.
      const idx = _charts.findIndex((c) => c.instance === inst);
      if (idx >= 0) _charts[idx].instance = fresh;
    });
  }

  // DOM-bar fallback (used only when ECharts global is missing).
  function renderHeroDomFallback(host, rows, pick) {
    const max = Math.max.apply(null, rows.map((r) => r.value));
    const list = el('ol', { class: 'bench-hero-bars' });
    for (const r of rows) {
      const pct = max > 0 ? (r.value / max * 100) : 0;
      const blocking = isBlocking(r.library);
      const color = getColor(r.library);
      const barClass = 'bench-hero-bar' +
        (blocking ? ' bench-hero-bar-blocking' : '');
      const barStyle = blocking
        ? 'width: ' + pct.toFixed(1) + '%; color: ' + color + ';'
        : 'width: ' + pct.toFixed(1) + '%; background: ' + color + ';';
      list.appendChild(el('li', {
        class: 'bench-hero-row',
        'data-library': r.library,
        'data-slug': r.slug,
      },
        el('span', { class: 'bench-hero-label' }, r.library),
        el('span', { class: barClass, style: barStyle }),
        el('span', { class: 'bench-hero-value' },
          r.value.toFixed(1) + ' ops/ms')
      ));
    }
    host.appendChild(list);
    host.appendChild(el('p', { class: 'bench-hero-axis-caption' },
      'throughput (ops/ms) — ' + topologyLabel(pick.topology) + ' ' + pick.shape));
  }

  // ── module: throughput / latency shared controls ────────────────────

  function buildControls(panelId, initialLogScale, onLogToggle) {
    const wrap = el('div', { class: 'bench-chart-controls' });
    const id = 'bench-log-scale-' + panelId;
    const cb = el('input', { type: 'checkbox', id });
    cb.checked = initialLogScale;
    cb.addEventListener('change', () => onLogToggle(cb.checked));
    const lbl = el('label', { for: id }, 'Log-scale Y axis');
    wrap.appendChild(el('span', { class: 'bench-control-item' }, cb, lbl));
    return wrap;
  }

  // Common throughput option builder. `series` is a list of
  // `{ library, points: [{ shape, value, lower, upper }], _shapeMap }`.
  function buildThroughputOption(series, xLabels, logScale, panelLabel, baselineByShape) {
    const isRel = _activeDisplayMode === 'relative' && baselineByShape && baselineByShape.size > 0;
    const echartsSeries = series.map((lib) => {
      const isLfq = isLockfreequeues(lib.library);
      const data = xLabels.map((label) => {
        const p = lib._shapeMap.get(label);
        if (p == null) return null;
        if (isRel) {
          const base = baselineByShape.get(label);
          return (base && base > 0) ? (p.value / base) : null;
        }
        return p.value;
      });
      return {
        name:   displayLabel(lib.library),
        type:   'line',
        data:   data,
        connectNulls: false,
        showSymbol: true,
        symbolSize: isLfq ? 8 : 6,
        emphasis: { focus: 'series' },
        lineStyle: {
          width: isLfq ? 3 : 2,
          type: isBlocking(lib.library) ? 'dashed' : 'solid',
        },
        itemStyle: { color: getColor(lib.library) },
        _library: lib.library,
        _points: lib.points,
      };
    });

    return Object.assign({}, buildPaletteOpt(), {
      grid: { left: 50, right: 24, top: 16, bottom: '22%', containLabel: false },
      tooltip: Object.assign({}, buildPaletteOpt().tooltip, {
        trigger: 'axis',
        axisPointer: { type: 'cross' },
        formatter: (params) => {
          if (!params || !params.length) return '';
          const shape = params[0].axisValueLabel || params[0].name;
          const header = panelLabel
            ? escapeHtml(panelLabel) + ' ' + escapeHtml(shape)
            : escapeHtml(shape);
          const lines = ['<strong>' + header + '</strong>'];
          const baseVal = baselineByShape && baselineByShape.get(shape);
          for (const p of params) {
            if (p.value == null) continue;
            const lib = (p.seriesName || '').replace(/ \*$/, '');
            // Find the matching point for stddev.
            const sObj = echartsSeries[p.seriesIndex];
            const point = sObj && sObj._points
              && sObj._points.find((q) => q.shape === shape);
            let line = '<span style="display:inline-block;width:8px;height:8px;'
              + 'border-radius:50%;background:' + p.color
              + ';margin-right:6px;"></span>'
              + escapeHtml(lib) + ': ';
            if (isRel) {
              line += p.value.toFixed(1) + 'x vs stdlib';
              if (point) line += ' (' + point.value.toFixed(1) + ' ops/ms)';
            } else {
              line += p.value.toFixed(1) + ' ops/ms';
              if (baseVal && baseVal > 0) {
                const speedup = (point ? point.value : p.value) / baseVal;
                line += ' (' + speedup.toFixed(1) + 'x vs stdlib)';
              }
              if (point && point.lower != null && point.upper != null) {
                const stddev = (point.upper - point.lower) / 2;
                line += ' (±' + stddev.toFixed(1) + ')';
              }
            }
            if (isBlocking(lib)) line += ' (blocking)';
            lines.push(line);
          }
          return lines.join('<br>');
        },
      }),
      legend: Object.assign({}, buildPaletteOpt().legend, {
        type: 'plain',
        bottom: 0,
        left: 'center',
        width: '100%',
        data: series.map((lib) => displayLabel(lib.library)),
      }),
      xAxis: Object.assign({}, buildPaletteOpt().xAxis, {
        type: 'category',
        data: xLabels,
        name: 'producer/consumer shape (P×C)',
        nameLocation: 'middle',
        nameGap: 32,
      }),
      yAxis: Object.assign({}, buildPaletteOpt().yAxis, {
        type: logScale ? 'log' : 'value',
        name: isRel
          ? 'relative speedup (x vs stdlib Channel)' + (logScale ? ' [log]' : '')
          : 'throughput (ops/ms)' + (logScale ? ' [log]' : ''),
        nameLocation: 'middle',
        nameGap: 44,
        logBase: 10,
      }),
      series: echartsSeries,
    });
  }

  function renderThroughputPanel(host, panel, libsByShape) {
    host.innerHTML = '';
    const heading = el('h4', { class: 'bench-panel-title' }, panel.label);
    appendSourceLink(heading, panel.id);
    host.appendChild(heading);

    if (!libsByShape || libsByShape.size === 0) {
      host.appendChild(el('p', { class: 'bench-chart-empty' },
        'No data for this topology yet.'));
      return;
    }
    if (typeof window.echarts !== 'object' || !window.echarts.init) {
      host.appendChild(el('p', { class: 'bench-chart-error' },
        'Chart unavailable: ECharts library failed to load.'));
      return;
    }

    const baselineByShape = new Map();
    const baseMap = libsByShape.get('nim_channels') || libsByShape.get('nim_channel');
    if (baseMap) {
      for (const [shape, mv] of baseMap) {
        if (mv && typeof mv.value === 'number' && mv.value > 0) {
          baselineByShape.set(shape, mv.value);
        }
      }
    }

    const shapeSet = new Set();
    const series = [];
    for (const [library, shapeMap] of libsByShape) {
      if (!matchesEcosystem(library)) continue;
      const points = [];
      for (const [shape, mv] of shapeMap) {
        if (!mv || typeof mv.value !== 'number' || mv.value <= 0) continue;
        shapeSet.add(shape);
        points.push({
          shape, value: mv.value, lower: mv.lower, upper: mv.upper,
          slug: mv.slug,
        });
      }
      if (points.length === 0) continue;
      series.push({
        library, points,
        _shapeMap: new Map(points.map((p) => [p.shape, p])),
      });
    }
    series.sort((a, b) => a.library.localeCompare(b.library));

    if (series.length === 0) {
      host.appendChild(el('p', { class: 'bench-chart-empty' },
        'No plottable values for this topology.'));
      return;
    }

    const xLabels = sortShapeLabels(shapeSet);
    let logScale = true;

    const controls = buildControls(panel.id, logScale, (next) => {
      logScale = next;
      inst.setOption(buildThroughputOption(series, xLabels, logScale, panel.label, baselineByShape),
        { notMerge: true });
    });
    const mount = el('div', { class: 'bench-chart-plot' });
    host.appendChild(controls);
    host.appendChild(mount);

    let inst = window.echarts.init(
      mount, isLightScheme() ? null : 'dark', { renderer: 'canvas' }
    );
    inst.setOption(buildThroughputOption(series, xLabels, logScale, panel.label, baselineByShape));
    registerChart(inst, () => {
      inst.dispose();
      inst = window.echarts.init(
        mount, isLightScheme() ? null : 'dark', { renderer: 'canvas' }
      );
      inst.setOption(buildThroughputOption(series, xLabels, logScale, panel.label, baselineByShape));
      const idx = _charts.findIndex((c) => c.instance && c.instance.isDisposed
        && c.instance.isDisposed());
      if (idx >= 0) _charts[idx].instance = inst;
    });
  }

  // ── module: latency panel ──────────────────────────────────────────

  const LATENCY_PERCENTILES = Object.freeze([
    { key: 'latency_p50_ns',  label: 'p50'  },
    { key: 'latency_p95_ns',  label: 'p95'  },
    { key: 'latency_p99_ns',  label: 'p99'  },
    { key: 'latency_p999_ns', label: 'p999' },
    { key: 'latency_max_ns',  label: 'max'  },
  ]);

  function collectLatencySeries(bmf) {
    const byLibrary = new Map();
    let hadAny = false;
    const slugs = Object.keys(bmf).filter(isMeasurementSlug).sort();
    for (const slug of slugs) {
      const measureMap = bmf[slug];
      if (!measureMap || typeof measureMap !== 'object') continue;
      const hasLatency = LATENCY_PERCENTILES.some((p) => {
        const m = measureMap[p.key];
        return m && typeof m.value === 'number' && Number.isFinite(m.value);
      });
      if (!hasLatency) continue;
      hadAny = true;
      const parsed = parseSlug(slug);
      if (!parsed) continue;
      if (!matchesEcosystem(parsed.library)) continue;
      if (byLibrary.has(parsed.library)) continue;
      const values = LATENCY_PERCENTILES.map((p) => {
        const m = measureMap[p.key];
        if (!m || typeof m.value !== 'number' || !Number.isFinite(m.value)) {
          return null;
        }
        if (m.value <= 0) return null;
        return m.value;
      });
      byLibrary.set(parsed.library, { library: parsed.library, slug, values });
    }
    const libraries = Array.from(byLibrary.values())
      .sort((a, b) => a.library.localeCompare(b.library));
    return { libraries, hadAny };
  }

  // CONTRACT-TEST-PARSED-START LATENCY_EMPTY_MESSAGE
  const LATENCY_EMPTY_MESSAGE =
    'Latency measurements unavailable in this dataset. Latency data is ' +
    'collected only for bounded 1p1c variants in the bench_latency ' +
    'binary; rerun the bench to populate.';
  // CONTRACT-TEST-PARSED-END LATENCY_EMPTY_MESSAGE

  const LATENCY_PARTIAL_FOOTNOTE =
    "Some libraries don't yet have latency measurements — adapter " +
    'coverage is in progress.';

  function buildLatencyOption(libraries, xLabels) {
    const echartsSeries = libraries.map((lib) => {
      const isLfq = isLockfreequeues(lib.library);
      return {
        name: displayLabel(lib.library),
        type: 'line',
        step: 'end',
        data: lib.values.slice(),
        connectNulls: false,
        showSymbol: true,
        symbolSize: isLfq ? 8 : 6,
        emphasis: { focus: 'series' },
        lineStyle: {
          width: isLfq ? 3 : 2,
          type: isBlocking(lib.library) ? 'dashed' : 'solid',
        },
        itemStyle: { color: getColor(lib.library) },
      };
    });

    return Object.assign({}, buildPaletteOpt(), {
      grid: { left: 50, right: 24, top: 16, bottom: '25%', containLabel: false },
      tooltip: Object.assign({}, buildPaletteOpt().tooltip, {
        trigger: 'axis',
        axisPointer: { type: 'cross' },
        formatter: (params) => {
          if (!params || !params.length) return '';
          const label = params[0].axisValueLabel || params[0].name;
          const lines = ['<strong>' + escapeHtml(label) + '</strong>'];
          for (const p of params) {
            if (p.value == null) continue;
            const lib = (p.seriesName || '').replace(/ \*$/, '');
            let line = '<span style="display:inline-block;width:8px;height:8px;'
              + 'border-radius:50%;background:' + p.color
              + ';margin-right:6px;"></span>'
              + escapeHtml(lib) + ': ' + p.value.toFixed(0) + ' ns';
            if (isBlocking(lib)) line += ' (blocking)';
            lines.push(line);
          }
          return lines.join('<br>');
        },
      }),
      legend: Object.assign({}, buildPaletteOpt().legend, {
        type: 'plain',
        bottom: 0,
        left: 'center',
        width: '100%',
        data: libraries.map((lib) => displayLabel(lib.library)),
      }),
      xAxis: Object.assign({}, buildPaletteOpt().xAxis, {
        type: 'category',
        data: xLabels,
        name: 'percentile',
        nameLocation: 'middle',
        nameGap: 28,
      }),
      yAxis: Object.assign({}, buildPaletteOpt().yAxis, {
        type: 'log',
        logBase: 10,
        name: 'latency (ns) [log]',
        nameLocation: 'middle',
        nameGap: 52,
        axisLabel: Object.assign({}, buildPaletteOpt().yAxis.axisLabel, {
          // Compact scientific notation for large values keeps the
          // y-axis label band narrow on a log scale (e.g. "1e7" instead
          // of "10,000,000"), so grid.left: 50 doesn't clip. Small
          // values pass through unchanged for readability.
          formatter: (value) => {
            if (value >= 10000) return value.toExponential(0).replace('e+', 'e');
            return value.toString();
          },
        }),
      }),
      series: echartsSeries,
    });
  }

  function renderLatencyPanel(host, bmf) {
    if (!host) return;
    host.innerHTML = '';
    // NOTE: heading text is owned by the `#### Latency` markdown in
    // docs/benchmarks.md; do NOT inject a duplicate <h4> here. Locate
    // the markdown-rendered heading and decorate it with the source-
    // code link so the latency panel matches the throughput panels.
    const latencyHeading = findPrecedingHeading(host);
    if (latencyHeading) appendSourceLink(latencyHeading, 'bench-latency');

    if (!bmf || typeof bmf !== 'object') {
      host.appendChild(el('p', { class: 'bench-chart-empty' },
        LATENCY_EMPTY_MESSAGE));
      return;
    }

    const { libraries, hadAny } = collectLatencySeries(bmf);
    if (!hadAny || libraries.length === 0) {
      host.appendChild(el('p', { class: 'bench-chart-empty' },
        LATENCY_EMPTY_MESSAGE));
      return;
    }
    if (typeof window.echarts !== 'object' || !window.echarts.init) {
      host.appendChild(el('p', { class: 'bench-chart-error' },
        'Chart unavailable: ECharts library failed to load.'));
      return;
    }

    const xLabels = LATENCY_PERCENTILES.map((p) => p.label);
    const mount = el('div', { class: 'bench-chart-plot' });
    host.appendChild(mount);

    let inst = window.echarts.init(
      mount, isLightScheme() ? null : 'dark', { renderer: 'canvas' }
    );
    inst.setOption(buildLatencyOption(libraries, xLabels));
    registerChart(inst, () => {
      inst.dispose();
      inst = window.echarts.init(
        mount, isLightScheme() ? null : 'dark', { renderer: 'canvas' }
      );
      inst.setOption(buildLatencyOption(libraries, xLabels));
    });

    const lfqBoundedExpected = [
      'lockfree_spsc', 'lockfree_spmc',
      'lockfree_mpsc', 'lockfree_mpmc',
    ];
    const present = new Set(libraries.map((l) => l.library));
    const lfqHits = lfqBoundedExpected.filter((l) => present.has(l)).length;
    if (lfqHits > 0 && lfqHits < lfqBoundedExpected.length) {
      host.appendChild(el('p', { class: 'bench-hero-footnote' },
        LATENCY_PARTIAL_FOOTNOTE));
    }
  }

  // ── module: fallback chain ──────────────────────────────────────────

  async function loadBMF() {
    const candidates = [
      '../../../assets/bench-results/latest.json',
      '../../assets/bench-results/latest.json',
      '../assets/bench-results/latest.json',
      'assets/bench-results/latest.json'
    ];
    let lastErr = null;
    for (const url of candidates) {
      try {
        const resp = await fetch(url, { cache: 'no-cache' });
        if (resp.ok) {
          const data = await resp.json();
          if (data && data._status === 'fallback') {
            const cause = data._reason
              || (data._merge_outcome
                  ? 'merge_bmf outcome=' + data._merge_outcome
                  : 'snapshot pipeline produced fallback');
            return await tryFixture(cause);
          }
          return { data, status: 'live', reason: null };
        }
      } catch (err) {
        lastErr = err;
      }
    }
    return await tryFixture('latest.json fetch failed: ' +
      (lastErr && lastErr.message ? lastErr.message : 'no response'));
  }

  async function tryFixture(reason) {
    const candidates = [
      '../../../assets/bench-results/example.json',
      '../../assets/bench-results/example.json',
      '../assets/bench-results/example.json',
      'assets/bench-results/example.json'
    ];
    for (const url of candidates) {
      try {
        const resp = await fetch(url, { cache: 'no-cache' });
        if (resp.ok) {
          const data = await resp.json();
          return { data, status: 'fixture', reason };
        }
      } catch (err) {
        // try next candidate
      }
    }
    return {
      data: null, status: 'error',
      reason: reason + '; example.json also unavailable',
    };
  }

  function renderStatusBanner(host, status, reason) {
    if (!host) return;
    if (status === 'live') {
      host.setAttribute('hidden', '');
      host.removeAttribute('data-status');
      host.innerHTML = '';
      return;
    }
    host.removeAttribute('hidden');
    host.setAttribute('data-status', status);
    host.innerHTML = '';
    let message;
    if (status === 'fixture') {
      message =
        'Showing representative data from example.json. Live snapshot ' +
        'was unavailable (' + reason + '). The chart will refresh once ' +
        'the next bench run on devel publishes latest.json.';
    } else if (status === 'error') {
      message =
        'Bench snapshot pending — the most recent attempt to merge ' +
        'benchmark results was unavailable (' + reason +
        '). Live data will appear here on the next successful run.';
    } else {
      message = 'Bench snapshot status: ' + status + ' (' + reason + ').';
    }
    host.appendChild(el('p', null, message));
  }

  function renderAllEmpty(reason) {
    const heroHost = document.getElementById('bench-hero');
    if (heroHost) {
      heroHost.innerHTML = '';
      heroHost.appendChild(el('h3', { class: 'bench-hero-heading' },
        'Throughput at a glance'));
      heroHost.appendChild(el('p', { class: 'bench-hero-empty' },
        'Bench snapshot pending — ' + reason));
    }
    for (const panel of THROUGHPUT_PANELS) {
      const host = document.getElementById(panel.id);
      if (host) {
        host.innerHTML = '';
        const heading = el('h4', { class: 'bench-panel-title' }, panel.label);
        appendSourceLink(heading, panel.id);
        host.appendChild(heading);
        host.appendChild(el('p', { class: 'bench-chart-empty' },
          'Awaiting next bench run.'));
      }
    }
    renderLatencyPanel(document.getElementById('bench-latency'), null);
  }

  // ── module: interactive toolbar & recommender ─────────────────────────

  function renderToolbar(host) {
    if (!host) return;
    host.innerHTML = '';

    // Group 1: Ecosystem
    const ecoChips = ['all', 'nim', 'cpp', 'rust'].map((eco) => {
      const label = eco === 'all' ? 'All' :
                    eco === 'nim' ? 'Nim' :
                    eco === 'cpp' ? 'C++' : 'Rust';
      const btn = el('button', {
        class: 'bench-chip' + (_activeEcosystem === eco ? ' active' : ''),
        type: 'button',
        'data-eco': eco,
      }, label);
      btn.addEventListener('click', () => {
        if (_activeEcosystem === eco) return;
        _activeEcosystem = eco;
        renderToolbar(host);
        rerenderCharts();
      });
      return btn;
    });
    const ecoGroup = el('div', { class: 'bench-filter-group' },
      el('span', { class: 'bench-filter-label' }, 'Ecosystem:'),
      el('div', { class: 'bench-chip-group' }, ...ecoChips)
    );

    // Group 2: View Mode (Absolute Throughput vs Relative Speedup)
    const modeChips = [
      { mode: 'absolute', label: 'Throughput' },
      { mode: 'relative', label: 'Relative Speedup' },
    ].map((item) => {
      const btn = el('button', {
        class: 'bench-chip' + (_activeDisplayMode === item.mode ? ' active' : ''),
        type: 'button',
        'data-mode': item.mode,
      }, item.label);
      btn.addEventListener('click', () => {
        if (_activeDisplayMode === item.mode) return;
        _activeDisplayMode = item.mode;
        renderToolbar(host);
        rerenderCharts();
      });
      return btn;
    });
    const modeGroup = el('div', { class: 'bench-filter-group' },
      el('span', { class: 'bench-filter-label' }, 'View:'),
      el('div', { class: 'bench-chip-group' }, ...modeChips)
    );

    // Group 3: Hero Shape selector
    const shapeChips = [
      { shape: null, label: 'Auto' },
      { shape: '4p4c', label: '4P:4C' },
      { shape: '2p2c', label: '2P:2C' },
      { shape: '4p1c', label: '4P:1C' },
      { shape: '1p1c', label: '1P:1C' },
    ].map((item) => {
      const isActive = _activeHeroShape === item.shape;
      const btn = el('button', {
        class: 'bench-chip' + (isActive ? ' active' : ''),
        type: 'button',
        'data-shape': item.shape || 'auto',
      }, item.label);
      btn.addEventListener('click', () => {
        if (_activeHeroShape === item.shape) return;
        _activeHeroShape = item.shape;
        renderToolbar(host);
        rerenderCharts();
      });
      return btn;
    });
    const shapeGroup = el('div', { class: 'bench-filter-group' },
      el('span', { class: 'bench-filter-label' }, 'Hero Shape:'),
      el('div', { class: 'bench-chip-group' }, ...shapeChips)
    );

    host.appendChild(ecoGroup);
    host.appendChild(modeGroup);
    host.appendChild(shapeGroup);
  }

  function renderRecommender(host) {
    if (!host) return;
    host.innerHTML = '';
    const heading = el('h4', { class: 'bench-panel-title' },
      'Interactive Workload Estimator & Queue Recommender');
    host.appendChild(heading);

    const desc = el('p', { class: 'bench-rec-desc', style: 'margin-bottom: 1em;' },
      'Select your concurrent workload parameters below to find the optimal lockfree queue primitive, progress guarantees, and memory layout.');
    host.appendChild(desc);

    const grid = el('div', { class: 'bench-recommender-grid' });
    const inputsCol = el('div', { class: 'bench-recommender-inputs' });
    const resultCol = el('div', { class: 'bench-recommender-result' });

    let pCount = 4;
    let cCount = 4;
    let isBounded = true;

    // Producer slider
    const pRow = el('div', { class: 'bench-slider-row' });
    const pHeader = el('div', { class: 'bench-slider-header' },
      el('label', null, 'Producer Threads:'),
      el('span', { class: 'bench-slider-val' }, pCount + ' Producers')
    );
    const pInput = el('input', { type: 'range', min: '1', max: '32', value: pCount });
    pRow.appendChild(pHeader);
    pRow.appendChild(pInput);

    // Consumer slider
    const cRow = el('div', { class: 'bench-slider-row' });
    const cHeader = el('div', { class: 'bench-slider-header' },
      el('label', null, 'Consumer Threads:'),
      el('span', { class: 'bench-slider-val' }, cCount + ' Consumers')
    );
    const cInput = el('input', { type: 'range', min: '1', max: '32', value: cCount });
    cRow.appendChild(cHeader);
    cRow.appendChild(cInput);

    // Bound mode toggle
    const bRow = el('div', { class: 'bench-slider-row' });
    const bHeader = el('div', { class: 'bench-slider-header' },
      el('label', null, 'Memory & Capacity Mode:'),
      el('span', { class: 'bench-slider-val' }, 'Bounded (Ring Buffer)')
    );
    const bGroup = el('div', { class: 'bench-chip-group', style: 'margin-top: 4px;' });
    const bBoundedChip = el('button', { class: 'bench-chip active', type: 'button' }, 'Bounded (Ring Buffer)');
    const bUnboundedChip = el('button', { class: 'bench-chip', type: 'button' }, 'Unbounded (Segments)');
    bGroup.appendChild(bBoundedChip);
    bGroup.appendChild(bUnboundedChip);
    bRow.appendChild(bHeader);
    bRow.appendChild(bGroup);

    inputsCol.appendChild(pRow);
    inputsCol.appendChild(cRow);
    inputsCol.appendChild(bRow);

    function updateRec() {
      pHeader.querySelector('.bench-slider-val').textContent = pCount + (pCount === 1 ? ' Producer' : ' Producers');
      cHeader.querySelector('.bench-slider-val').textContent = cCount + (cCount === 1 ? ' Consumer' : ' Consumers');
      bHeader.querySelector('.bench-slider-val').textContent = isBounded ? 'Bounded (Ring Buffer)' : 'Unbounded (Segments)';

      if (isBounded) {
        bBoundedChip.classList.add('active');
        bUnboundedChip.classList.remove('active');
      } else {
        bBoundedChip.classList.remove('active');
        bUnboundedChip.classList.add('active');
      }

      resultCol.innerHTML = '';
      const card = el('div', { class: 'bench-recommendation-card' });

      let recTitle = '';
      const recBadge = 'Recommended Primitive';
      let recDesc = '';
      let progress = '';
      let memory = '';
      let speedup = '';
      let contention = '';

      if (pCount === 1 && cCount === 1) {
        if (isBounded) {
          recTitle = 'newSpscQueue[T](capacity)';
          recDesc = 'Optimal for single producer to single consumer (e.g. audio callbacks, GPU commands, network ingest). Zero atomic RMW overhead on fast path.';
          progress = 'Wait-Free (Push & Pop)';
          memory = 'Fixed ring buffer, 64-byte cache-line padded head/tail';
          speedup = '~4x–5x vs channel';
          contention = 'Zero contention (1P:1C)';
        } else {
          recTitle = 'newUnboundedSpscQueue[T]()';
          recDesc = 'Wait-free single-producer single-consumer with dynamically linked segments. Never blocks on full.';
          progress = 'Wait-Free Push / Pop';
          memory = 'Segmented linked lists';
          speedup = '~3x–4x vs channel';
          contention = 'Zero contention (1P:1C)';
        }
      } else if (pCount > 1 && cCount === 1) {
        if (isBounded) {
          recTitle = 'newMpscQueue[T](capacity)';
          recDesc = 'Multi-producer single-consumer funnel (e.g. logging aggregator, event collector). Lock-free CAS for producers, wait-free consumer.';
          progress = 'Lock-Free Push / Wait-Free Pop';
          memory = 'Fixed ring buffer with sequence counters';
          speedup = '1.8x–3.7x vs system/Channel';
          contention = pCount + 'P competing on head index';
        } else {
          recTitle = 'newUnboundedMpscQueue[T]()';
          recDesc = 'Dynamic multi-producer single-consumer queue. Reclaims retired segment nodes safely via NEBR.';
          progress = 'Lock-Free Push / Pop';
          memory = 'Segmented linked chunks (NEBR)';
          speedup = '1.5x–2.5x vs channel';
          contention = pCount + 'P competing on head';
        }
      } else if (pCount === 1 && cCount > 1) {
        if (isBounded) {
          recTitle = 'newSpmcQueue[T](capacity)';
          recDesc = 'Single-producer worker pool dispatcher. Wait-free producer avoids stalls when feeding worker threads.';
          progress = 'Wait-Free Push / Lock-Free Pop';
          memory = 'Fixed ring buffer with sequence counters';
          speedup = 'Wait-free producer (stdlib has no SPMC)';
          contention = cCount + 'C competing on tail index';
        } else {
          recTitle = 'newUnboundedSpmcQueue[T]()';
          recDesc = 'Single-producer multi-consumer worker pool with unbounded capacity.';
          progress = 'Wait-Free Push / Lock-Free Pop';
          memory = 'Segmented linked chunks';
          speedup = 'stdlib has no SPMC';
          contention = cCount + 'C competing on tail';
        }
      } else {
        if (isBounded) {
          recTitle = 'newMpmcQueue[T](capacity)';
          recDesc = 'General multi-producer multi-consumer work stealing & job processing. Bounded ring buffer with Vyukov turn counters.';
          progress = 'Lock-Free (Push & Pop)';
          memory = 'Cache-line aligned slots, power-of-2 capacity';
          speedup = '9.0x–10.6x vs system/Channel (at 4p4c)';
          contention = pCount + 'P / ' + cCount + 'C full concurrent contention';
        } else {
          recTitle = 'newUnboundedMpmcQueue[T]()';
          recDesc = 'Strict LCRQ (Linked Concurrent Ring Queue) with NEBR epoch reclamation. High-throughput unbounded MPMC that never blocks on full.';
          progress = 'Lock-Free (Strict LCRQ)';
          memory = 'Ring buffer segments in linked list + NEBR manager';
          speedup = '5.0x–6.5x vs system/Channel';
          contention = pCount + 'P / ' + cCount + 'C double-word CAS contention';
        }
      }

      card.appendChild(el('span', { class: 'bench-rec-badge' }, recBadge));
      card.appendChild(el('div', { class: 'bench-rec-title' }, el('code', null, recTitle)));
      card.appendChild(el('p', { class: 'bench-rec-desc' }, recDesc));

      const specs = el('div', { class: 'bench-rec-specs' },
        el('div', { class: 'bench-rec-spec-item' },
          el('strong', null, 'Progress Guarantee'),
          el('span', null, progress)
        ),
        el('div', { class: 'bench-rec-spec-item' },
          el('strong', null, 'Contention Profile'),
          el('span', null, contention)
        ),
        el('div', { class: 'bench-rec-spec-item' },
          el('strong', null, 'Speedup vs stdlib'),
          el('span', null, speedup)
        ),
        el('div', { class: 'bench-rec-spec-item' },
          el('strong', null, 'Memory Layout'),
          el('span', null, memory)
        )
      );
      card.appendChild(specs);
      resultCol.appendChild(card);
    }

    pInput.addEventListener('input', (e) => {
      pCount = parseInt(e.target.value, 10);
      updateRec();
    });
    cInput.addEventListener('input', (e) => {
      cCount = parseInt(e.target.value, 10);
      updateRec();
    });
    bBoundedChip.addEventListener('click', () => {
      isBounded = true;
      updateRec();
    });
    bUnboundedChip.addEventListener('click', () => {
      isBounded = false;
      updateRec();
    });

    grid.appendChild(inputsCol);
    grid.appendChild(resultCol);
    host.appendChild(grid);
    updateRec();
  }

  function rerenderCharts() {
    if (!_currentBmfResult || !_currentBmfResult.data) return;
    clearRegisteredCharts();
    const heroHost = document.getElementById('bench-hero');
    const byTopology = groupByTopology(_currentBmfResult.data);
    if (heroHost) renderHero(heroHost, byTopology);

    for (const panel of THROUGHPUT_PANELS) {
      const host = document.getElementById(panel.id);
      if (!host) continue;
      const merged = new Map();
      for (const [topology, libsByShape] of byTopology) {
        if (!panel.includes(topology)) continue;
        for (const [library, shapeMap] of libsByShape) {
          let dest = merged.get(library);
          if (!dest) { dest = new Map(); merged.set(library, dest); }
          for (const [shape, mv] of shapeMap) dest.set(shape, mv);
        }
      }
      renderThroughputPanel(host, panel, merged);
    }

    renderLatencyPanel(
      document.getElementById('bench-latency'),
      _currentBmfResult.data || null
    );

    requestAnimationFrame(() => {
      resizeAll();
    });
  }

  // ── module: bootstrap ───────────────────────────────────────────────

  async function render() {
    const heroHost = document.getElementById('bench-hero');
    const statusHost = document.getElementById('bench-status');
    const toolbarHost = document.getElementById('bench-toolbar');
    const recommenderHost = document.getElementById('bench-recommender');
    const hasAnyHost = heroHost || toolbarHost || recommenderHost ||
      THROUGHPUT_PANELS.some((p) => document.getElementById(p.id)) ||
      document.getElementById('bench-latency');
    if (!hasAnyHost) return;

    if (toolbarHost) renderToolbar(toolbarHost);
    if (recommenderHost) renderRecommender(recommenderHost);

    renderLatencyPanel(document.getElementById('bench-latency'), null);

    const result = await loadBMF();
    _currentBmfResult = result;
    if (result.status === 'error') {
      renderStatusBanner(statusHost, 'error', result.reason);
      renderAllEmpty(result.reason);
      return;
    }

    renderStatusBanner(statusHost, result.status, result.reason);
    rerenderCharts();

    // After initial layout settles, resize all charts to fill their
    // containers. ECharts auto-sizes at init only if the container has
    // its final dimensions at that moment; with mkdocs Material, layout
    // can shift after the script runs (sidebar/nav fonts settle, etc.).
    requestAnimationFrame(() => {
      resizeAll();
      // A second pass after a short tick catches any late reflow from
      // font loading or theme palette readback.
      setTimeout(resizeAll, 50);
    });

    if (window.location.hash) {
      const id = window.location.hash.slice(1);
      const node = document.getElementById(id);
      if (node) {
        requestAnimationFrame(() => {
          node.scrollIntoView({ behavior: 'smooth', block: 'start' });
        });
      }
    }
  }

  // Window resize: ECharts requires explicit instance.resize().
  // Debounce so a drag doesn't fire dozens of resizes per second.
  let _resizeTimer = null;
  window.addEventListener('resize', () => {
    if (_resizeTimer) clearTimeout(_resizeTimer);
    _resizeTimer = setTimeout(resizeAll, 100);
  });

  // mkdocs Material color-scheme flips `data-md-color-scheme` on
  // `<body>`. We watch for that and re-paint every chart with the
  // matching ECharts baseline theme + Material palette.
  if (typeof MutationObserver !== 'undefined') {
    const mo = new MutationObserver((records) => {
      for (const r of records) {
        if (r.type === 'attributes' &&
            (r.attributeName === 'data-md-color-scheme' ||
             r.attributeName === 'data-md-color-primary')) {
          repaintAllForScheme();
          return;
        }
      }
    });
    mo.observe(document.body, { attributes: true });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', render);
  } else {
    render();
  }
})();
