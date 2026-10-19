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
    // lockfree queue family (bounded) — high-contrast brand indigo
    lockfree_spsc:           '#6366f1',
    lockfree_spmc:           '#6366f1',
    lockfree_mpsc:           '#6366f1',
    lockfree_mpmc:           '#6366f1',
    // lockfree queue family (unbounded) — lighter brand indigo
    lockfree_unbounded_spsc: '#818cf8',
    lockfree_unbounded_spmc: '#818cf8',
    lockfree_unbounded_mpsc: '#818cf8',
    lockfree_unbounded_mpmc: '#818cf8',
    // associative maps & sets
    ctrie:                      '#6366f1',
    btable:                     '#4f46e5',
    skiplist:                   '#00897b',
    skiplist_set:               '#00695c',
    locked_table:               '#78909c',
    locked_set:                 '#607d8b',
    dashmap:                    '#f4511e',
    flurry:                     '#fb8c00',
    crossbeam_skipmap:          '#d84315',
    crossbeam_skipset:          '#e64a19',
    boost_concurrent_flat_map:  '#0288d1',
    boost_concurrent_flat_set:  '#039be5',
    // stacks, deques & priority queues
    treiber_stack:              '#6366f1',
    bstack:                     '#4f46e5',
    locked_stack:               '#78909c',
    boost_lockfree_stack:       '#00897b',
    chase_lev_deque:            '#6366f1',
    chase_lev_deque_batch:      '#4f46e5',
    crossbeam_deque:            '#f4511e',
    crossbeam_deque_batch:      '#d84315',
    bpriority_queue:            '#6366f1',
    skiplist_pq:                '#00897b',
    locked_pq:                  '#78909c',
    // broadcast ring & topic bus
    broadcast_ring_drop:        '#6366f1',
    broadcast_ring_backoff:     '#0277bd',
    topic_bus_drop:             '#4f46e5',
    topic_bus_backoff:          '#01579b',
    tokio_broadcast:            '#f4511e',
    rust_bus:                   '#fb8c00',
    // rate limiting & streaming
    token_bucket:               '#6366f1',
    leaky_bucket:               '#4f46e5',
    governor_gcra:              '#f4511e',
    stream_ring:                '#6366f1',
    rtrb_stream:                '#d84315',
    boost_spsc_stream:          '#00897b',
    // synchronous rendezvous (0-buffer channel)
    rendezvous_channel:         '#6366f1',
    nim_channel_sync:           '#546e7a',
    crossbeam_rendezvous:       '#f4511e',
    flume_rendezvous:           '#d84315',
    kanal_rendezvous:           '#c2185b',
    // work-stealing taskpool
    taskpool:                   '#6366f1',
    locked_task_queue:          '#78909c',
    rayon_pool:                 '#f4511e',
    // safe memory reclamation (NEBR / epoch)
    nebr:                       '#6366f1',
    arc_atomic_rc:              '#818cf8',
    mutex_guard:                '#78909c',
    deferred_mutex_free:        '#546e7a',
    crossbeam_epoch:            '#f4511e',
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
    flume_unbounded:                 '#d84315',
    kanal:                           '#c2185b',
    kanal_unbounded:                 '#c2185b',
    liblfds:                         '#455a64',
  });
  // CONTRACT-TEST-PARSED-END LIBRARY_COLORS

  // CONTRACT-TEST-PARSED-START BLOCKING_LIBRARIES
  const BLOCKING_LIBRARIES = [
    'threading_channels', 'nim_channel', 'nim_channels', 'nim_channel_sync',
    'locked_table', 'locked_set', 'locked_stack', 'locked_pq', 'locked_task_queue',
    'broadcast_ring_backoff', 'topic_bus_backoff',
    'mutex_guard', 'deferred_mutex_free',
  ];
  // CONTRACT-TEST-PARSED-END BLOCKING_LIBRARIES
  const BLOCKING_SET = new Set(BLOCKING_LIBRARIES);

  const LOCKFREE_FAMILY = [
    'lockfree_spsc', 'lockfree_spmc',
    'lockfree_mpsc', 'lockfree_mpmc',
    'lockfree_unbounded_spsc', 'lockfree_unbounded_spmc',
    'lockfree_unbounded_mpsc', 'lockfree_unbounded_mpmc',
    'ctrie', 'btable', 'skiplist', 'skiplist_set',
    'treiber_stack', 'bstack', 'chase_lev_deque', 'chase_lev_deque_batch',
    'bpriority_queue', 'skiplist_pq',
    'broadcast_ring_drop', 'broadcast_ring_backoff',
    'topic_bus_drop', 'topic_bus_backoff',
    'token_bucket', 'leaky_bucket', 'stream_ring',
    'rendezvous_channel', 'taskpool', 'nebr',
  ];
  const LFQ_FAMILY_SET = new Set(LOCKFREE_FAMILY);

  const LIBRARY_ECOSYSTEMS = Object.freeze({
    // Nim native & stdlib
    lockfree_spsc: 'nim', lockfree_spmc: 'nim', lockfree_mpsc: 'nim', lockfree_mpmc: 'nim',
    lockfree_unbounded_spsc: 'nim', lockfree_unbounded_spmc: 'nim',
    lockfree_unbounded_mpsc: 'nim', lockfree_unbounded_mpmc: 'nim',
    nim_channel: 'nim', nim_channels: 'nim', nim_channel_sync: 'nim',
    threading_channels: 'nim', loony: 'nim',
    ctrie: 'nim', btable: 'nim', skiplist: 'nim', skiplist_set: 'nim',
    locked_table: 'nim', locked_set: 'nim',
    treiber_stack: 'nim', bstack: 'nim', locked_stack: 'nim',
    chase_lev_deque: 'nim', chase_lev_deque_batch: 'nim',
    bpriority_queue: 'nim', skiplist_pq: 'nim', locked_pq: 'nim',
    broadcast_ring_drop: 'nim', broadcast_ring_backoff: 'nim',
    topic_bus_drop: 'nim', topic_bus_backoff: 'nim',
    token_bucket: 'nim', leaky_bucket: 'nim', stream_ring: 'nim',
    rendezvous_channel: 'nim',
    taskpool: 'nim', locked_task_queue: 'nim',
    nebr: 'nim', arc_atomic_rc: 'nim', mutex_guard: 'nim', deferred_mutex_free: 'nim',
    // C++
    moodycamel: 'cpp', boost_lockfree_queue: 'cpp', boost_lockfree_spsc: 'cpp',
    boost_lockfree_stack: 'cpp', boost_concurrent_flat_map: 'cpp',
    boost_concurrent_flat_set: 'cpp', boost_spsc_stream: 'cpp',
    atomic_queue: 'cpp', rigtorp_mpmc: 'cpp', rigtorp_spsc: 'cpp',
    // Rust
    crossbeam_array_queue: 'rust', crossbeam_seg_queue: 'rust',
    flume: 'rust', flume_unbounded: 'rust', kanal: 'rust', kanal_unbounded: 'rust',
    dashmap: 'rust', flurry: 'rust',
    crossbeam_skipmap: 'rust', crossbeam_skipset: 'rust',
    crossbeam_deque: 'rust', crossbeam_deque_batch: 'rust',
    tokio_broadcast: 'rust', rust_bus: 'rust',
    governor_gcra: 'rust', rtrb_stream: 'rust',
    crossbeam_rendezvous: 'rust', flume_rendezvous: 'rust', kanal_rendezvous: 'rust',
    rayon_pool: 'rust', crossbeam_epoch: 'rust',
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
    pqueue_mpmc: 'MPMC Priority Queue',
    read_heavy: 'Read-Heavy (90/10)',
    balanced: 'Balanced (50/50)',
    write_heavy: 'Write-Heavy (10/90)',
    set_mixed: 'Set Mixed (80/10/10)',
    mixed: 'Set Mixed (80/10/10)',
    set_algebra: 'Set Algebra (Union/Intersection)',
    snapshot_iter: 'Wait-Free Snapshot Iteration',
    work_stealing: 'Work-Stealing',
    work_stealing_batch: 'Work-Stealing (Batch)',
    fanout: '1-to-N Fan-Out',
    topic_bus: 'TopicBus Pub/Sub Routing',
    contention: 'Contention',
    spsc_chunk: 'SPSC Chunk Streaming',
    rendezvous_handoff: '0-Buffer Synchronous Handoff',
    rendezvous_rpc: 'Synchronous 1:1 RPC Round-Trip',
    taskpool_parfor: 'TaskPool parallelFor',
    parallel_for: 'TaskPool parallelFor',
    taskpool_forkjoin: 'TaskPool Recursive Fork/Join',
    fork_join: 'TaskPool Recursive Fork/Join',
    taskpool_spawnsync: 'TaskPool Spawn/Sync Batch',
    spawn_sync: 'TaskPool Spawn/Sync Batch',
    smr_pin_unpin: 'SMR Critical-Section Pin/Unpin',
    pin_unpin: 'SMR Critical-Section Pin/Unpin',
    smr_retire_reclaim: 'SMR Retire/Reclaim + Neutralization',
    retire_reclaim: 'SMR Retire/Reclaim + Neutralization',
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
    { id: 'bench-sets-mixed',                label: 'ConcurrentSet Mixed (80/10/10)',
      includes: (topology) => topology === 'set_mixed'
                              || topology === 'mixed' },
    { id: 'bench-sets-algebra',              label: 'ConcurrentSet Algebra (Union/Intersection)',
      includes: (topology) => topology === 'set_algebra' },
    { id: 'bench-maps-snapshot',             label: 'Wait-Free Snapshot Iteration',
      includes: (topology) => topology === 'snapshot_iter' },
    // Stacks, Deques & Priority Queues
    { id: 'bench-stacks-mpmc',               label: 'MPMC Stack Contention',
      includes: (topology) => topology === 'stack_mpmc' },
    { id: 'bench-deques-work-stealing',      label: 'Work-Stealing Deque',
      includes: (topology) => topology === 'work_stealing'
                              || topology === 'work_stealing_batch' },
    { id: 'bench-pqueue-mpmc',               label: 'MPMC Priority Queue Contention',
      includes: (topology) => topology === 'pqueue_mpmc' },
    // Broadcast Ring & TopicBus
    { id: 'bench-broadcast-fanout',          label: '1-to-N Multicast Fan-Out',
      includes: (topology) => topology === 'fanout' },
    { id: 'bench-broadcast-topicbus',        label: 'TopicBus Multi-Topic Routing',
      includes: (topology) => topology === 'topic_bus' },
    // Rate Limiting & Streaming
    { id: 'bench-tokenbucket-contention',    label: 'Rate Limiter Contention',
      includes: (topology) => topology === 'contention' },
    { id: 'bench-streambuffer-throughput',   label: 'StreamRing SPSC Bandwidth',
      includes: (topology) => topology === 'spsc_chunk' },
    // Rendezvous (0-buffer Synchronous Channel)
    { id: 'bench-rendezvous-handoff',        label: '0-Buffer Synchronous Handoff',
      includes: (topology) => topology === 'rendezvous_handoff' },
    { id: 'bench-rendezvous-rpc',            label: 'Synchronous 1:1 RPC Throughput',
      includes: (topology) => topology === 'rendezvous_rpc' },
    // Work-Stealing TaskPool
    { id: 'bench-taskpool-parfor',           label: 'TaskPool parallelFor Throughput',
      includes: (topology) => topology === 'taskpool_parfor'
                              || topology === 'parallel_for' },
    { id: 'bench-taskpool-forkjoin',         label: 'TaskPool Recursive Fork/Join (fib)',
      includes: (topology) => topology === 'taskpool_forkjoin'
                              || topology === 'fork_join' },
    { id: 'bench-taskpool-spawnsync',        label: 'TaskPool Spawn/Sync Batch',
      includes: (topology) => topology === 'taskpool_spawnsync'
                              || topology === 'spawn_sync' },
    // Safe Memory Reclamation (NEBR)
    { id: 'bench-smr-pin-unpin',             label: 'Critical-Section Pin/Unpin Throughput',
      includes: (topology) => topology === 'smr_pin_unpin'
                              || topology === 'pin_unpin' },
    { id: 'bench-smr-retire-reclaim',        label: 'Retire/Reclaim & Stalled-Thread Neutralization',
      includes: (topology) => topology === 'smr_retire_reclaim'
                              || topology === 'retire_reclaim' },
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
    'bench-sets-mixed':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_maps.nim',
    'bench-sets-algebra':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_maps.nim',
    'bench-maps-snapshot':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_maps.nim',
    'bench-stacks-mpmc':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_stacks_deques.nim',
    'bench-deques-work-stealing':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_stacks_deques.nim',
    'bench-pqueue-mpmc':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_stacks_deques.nim',
    'bench-broadcast-fanout':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_broadcast.nim',
    'bench-broadcast-topicbus':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_broadcast.nim',
    'bench-tokenbucket-contention':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_ratelimit_streaming.nim',
    'bench-streambuffer-throughput':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_ratelimit_streaming.nim',
    'bench-rendezvous-handoff':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_rendezvous.nim',
    'bench-rendezvous-rpc':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_rendezvous.nim',
    'bench-rendezvous-latency':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_rendezvous.nim',
    'bench-taskpool-parfor':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_taskpool.nim',
    'bench-taskpool-forkjoin':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_taskpool.nim',
    'bench-taskpool-spawnsync':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_taskpool.nim',
    'bench-smr-pin-unpin':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_smr_nebr.nim',
    'bench-smr-retire-reclaim':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_smr_nebr.nim',
    'bench-smr-latency':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_smr_nebr.nim',
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

  // ── module: directionality badge helper ────────────────────────────

  const THROUGHPUT_BADGE_TEXT = 'Throughput: Higher is better ↑';
  const LATENCY_BADGE_TEXT    = 'Latency: Lower is better ↓';

  function buildDirectionBadge(kind) {
    const isLatency = kind === 'latency';
    return el('span', {
      class: 'bench-direction-badge ' +
        (isLatency ? 'bench-direction-lower' : 'bench-direction-higher'),
    }, isLatency ? LATENCY_BADGE_TEXT : THROUGHPUT_BADGE_TEXT);
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
    const headerRow = el('div', { class: 'bench-panel-header-row' },
      el('h3', { class: 'bench-hero-heading' }, headingText),
      buildDirectionBadge('throughput')
    );
    host.appendChild(headerRow);

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
      const pal = readPalette();
      const categories = rows.map((r) => r.library);
      const values = rows.map((r) => {
        const isLfq = isLockfreequeues(r.library);
        const displayVal = baselineVal ? (r.value / baselineVal) : r.value;
        return {
          value: displayVal,
          itemStyle: {
            color: getColor(r.library),
            borderColor: isLfq ? '#6366f1' : getColor(r.library),
            borderType: isBlocking(r.library) ? 'dashed' : 'solid',
            borderWidth: isLfq ? 3 : (isBlocking(r.library) ? 2 : 0),
            opacity: isBlocking(r.library) ? 0.55 : 1,
          },
          label: {
            fontWeight: isLfq ? 'bold' : 'normal',
            color: isLfq ? '#6366f1' : pal.fg,
          },
          _row: r,
          _displayVal: displayVal,
        };
      });
      const opt = Object.assign({}, buildPaletteOpt(), {
        grid: { left: 170, right: 90, top: 20, bottom: 44, containLabel: true },
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
              ' ' + escapeHtml(pick.shape) + ' — ' + THROUGHPUT_BADGE_TEXT;
            if (isBlocking(r.library)) line += ' (blocking)';
            return line;
          },
        }),
        xAxis: Object.assign({}, buildPaletteOpt().xAxis, {
          type: 'value',
          name: (baselineVal ? 'Relative speedup (x vs stdlib Channel)' : 'Throughput (ops/ms)') +
            ' — ' + THROUGHPUT_BADGE_TEXT,
          nameLocation: 'middle',
          nameGap: 30,
        }),
        yAxis: Object.assign({}, buildPaletteOpt().yAxis, {
          type: 'category',
          data: categories,
          inverse: true,
          axisLabel: Object.assign({}, buildPaletteOpt().yAxis.axisLabel, {
            formatter: (val) => isLockfreequeues(val) ? '{lfq|' + val + '}' : val,
            rich: {
              lfq: {
                fontWeight: 'bold',
                color: '#6366f1',
              },
            },
          }),
        }),
        series: [{
          type: 'bar',
          data: values,
          barCategoryGap: '30%',
          label: {
            show: true, position: 'right',
            fontWeight: 'bold',
            formatter: (p) => baselineVal ? p.value.toFixed(1) + 'x' : p.value.toFixed(1),
            color: pal.fg,
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
        el('span', {
          class: 'bench-hero-label',
          style: isLockfreequeues(r.library) ? 'font-weight: bold;' : '',
        }, r.library),
        el('span', { class: barClass, style: barStyle }),
        el('span', { class: 'bench-hero-value' },
          r.value.toFixed(1) + ' ops/ms')
      ));
    }
    host.appendChild(list);
    host.appendChild(el('p', { class: 'bench-hero-axis-caption' },
      'throughput (ops/ms) — ' + topologyLabel(pick.topology) + ' ' + pick.shape +
      ' (' + THROUGHPUT_BADGE_TEXT + ')'));
  }

  // ── module: throughput / latency shared controls ────────────────────

  function buildControls(panelId, initialLogScale, onLogToggle) {
    const wrap = el('div', { class: 'bench-chart-controls' });
    wrap.appendChild(buildDirectionBadge('throughput'));
    const id = 'bench-log-scale-' + panelId;
    const cb = el('input', { type: 'checkbox', id });
    cb.checked = initialLogScale;
    cb.addEventListener('change', () => onLogToggle(cb.checked));
    const lbl = el('label', { for: id }, 'Log-scale Y axis');
    wrap.appendChild(el('span', { class: 'bench-control-item' }, cb, lbl));
    return wrap;
  }

  // Ranked Bar Chart builder for SPSC / single-point topologies (`type: 'bar'`).
  // Replaces disconnected single-point line dots with a clear ranked bar chart
  // comparing contenders side-by-side in descending throughput order.
  function buildRankedBarThroughputOption(series, xLabels, logScale, panelLabel, baselineByShape) {
    const pal = readPalette();
    const shape = xLabels[0] || '1p1c';
    const isRel = _activeDisplayMode === 'relative' && baselineByShape && baselineByShape.size > 0;
    const baseVal = baselineByShape && baselineByShape.get(shape);

    const ranked = series
      .map((lib) => {
        const pt = lib._shapeMap.get(shape) || lib.points[0] || null;
        const rawVal = pt ? pt.value : 0;
        const displayVal = (isRel && baseVal && baseVal > 0) ? (rawVal / baseVal) : rawVal;
        return {
          library: lib.library,
          point: pt,
          rawVal,
          displayVal,
        };
      })
      .filter((r) => r.displayVal > 0)
      .sort((a, b) => b.displayVal - a.displayVal);

    const categories = ranked.map((r) => displayLabel(r.library));
    const barData = ranked.map((r) => {
      const isLfq = isLockfreequeues(r.library);
      return {
        value: r.displayVal,
        itemStyle: {
          color: getColor(r.library),
          borderColor: isLfq ? '#6366f1' : getColor(r.library),
          borderType: isBlocking(r.library) ? 'dashed' : 'solid',
          borderWidth: isLfq ? 3 : (isBlocking(r.library) ? 2 : 0),
          opacity: isBlocking(r.library) ? 0.65 : 1,
        },
        label: {
          show: true,
          position: 'top',
          fontWeight: isLfq ? 'bold' : 'normal',
          color: isLfq ? '#6366f1' : pal.fg,
          formatter: () => isRel ? r.displayVal.toFixed(1) + 'x' : r.rawVal.toFixed(0),
        },
        _entry: r,
      };
    });

    return Object.assign({}, buildPaletteOpt(), {
      title: {
        subtext: THROUGHPUT_BADGE_TEXT,
        right: 16,
        top: 0,
        subtextStyle: {
          color: pal.fgLight,
          fontSize: 12,
          fontWeight: 'bold',
        },
      },
      grid: { left: 68, right: 28, top: 44, bottom: 78, containLabel: true },
      tooltip: Object.assign({}, buildPaletteOpt().tooltip, {
        trigger: 'axis',
        axisPointer: { type: 'shadow' },
        formatter: (params) => {
          if (!params || !params.length) return '';
          const p = params[0];
          const entry = p.data && p.data._entry;
          if (!entry) return '';
          const pt = entry.point;
          let line = '<strong>' + escapeHtml(entry.library) + '</strong> (' +
            escapeHtml(panelLabel || 'SPSC') + ' ' + escapeHtml(shape) + ')<br>' +
            entry.rawVal.toFixed(1) + ' ops/ms';
          if (baseVal && baseVal > 0) {
            line += ' <strong>(' + (entry.rawVal / baseVal).toFixed(1) + 'x vs stdlib)</strong>';
          }
          if (pt && pt.lower != null && pt.upper != null) {
            const stddev = (pt.upper - pt.lower) / 2;
            line += ' (±' + stddev.toFixed(1) + ')';
          }
          if (isBlocking(entry.library)) line += ' (blocking)';
          line += '<br><span style="opacity:0.8;">' + THROUGHPUT_BADGE_TEXT + '</span>';
          return line;
        },
      }),
      xAxis: Object.assign({}, buildPaletteOpt().xAxis, {
        type: 'category',
        data: categories,
        name: 'Contender library (' + shape + ', ranked by throughput)',
        nameLocation: 'middle',
        nameGap: 48,
        axisLabel: Object.assign({}, buildPaletteOpt().xAxis.axisLabel, {
          interval: 0,
          rotate: categories.length > 5 ? 20 : 0,
          formatter: (val) => {
            const rawLib = String(val).replace(/ \*$/, '');
            return isLockfreequeues(rawLib) ? '{lfq|' + val + '}' : val;
          },
          rich: {
            lfq: {
              fontWeight: 'bold',
              color: '#6366f1',
            },
          },
        }),
      }),
      yAxis: Object.assign({}, buildPaletteOpt().yAxis, {
        type: logScale ? 'log' : 'value',
        name: (isRel
          ? 'Relative speedup (x vs stdlib Channel)'
          : 'Throughput (ops/ms)') + (logScale ? ' [log]' : '') + ' — Higher is better ↑',
        nameLocation: 'middle',
        nameGap: 52,
        logBase: 10,
      }),
      series: [{
        name: panelLabel || 'SPSC',
        type: 'bar',
        barMaxWidth: 48,
        data: barData,
      }],
    });
  }

  // Common throughput option builder. `series` is a list of
  // `{ library, points: [{ shape, value, lower, upper }], _shapeMap }`.
  function buildThroughputOption(series, xLabels, logScale, panelLabel, baselineByShape, panelId) {
    if (panelId === 'bench-throughput-spsc' || xLabels.length === 1) {
      return buildRankedBarThroughputOption(series, xLabels, logScale, panelLabel, baselineByShape);
    }

    const pal = readPalette();
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
        symbolSize: isLfq ? 9 : 6,
        z: isLfq ? 4 : 2,
        emphasis: { focus: 'series' },
        lineStyle: {
          width: isLfq ? 3 : 2,
          type: isBlocking(lib.library) ? 'dashed' : 'solid',
        },
        label: {
          fontWeight: isLfq ? 'bold' : 'normal',
        },
        itemStyle: { color: getColor(lib.library) },
        _library: lib.library,
        _points: lib.points,
      };
    });

    // Dynamically reserve enough bottom margin so the X-axis title and
    // multi-row MPMC legend never collide.
    const legendRows = Math.max(1, Math.ceil(series.length / 4));
    const bottomPx = Math.max(98, 58 + legendRows * 26);

    return Object.assign({}, buildPaletteOpt(), {
      title: {
        subtext: THROUGHPUT_BADGE_TEXT,
        right: 16,
        top: 0,
        subtextStyle: {
          color: pal.fgLight,
          fontSize: 12,
          fontWeight: 'bold',
        },
      },
      grid: { left: 68, right: 28, top: 36, bottom: bottomPx, containLabel: true },
      tooltip: Object.assign({}, buildPaletteOpt().tooltip, {
        trigger: 'axis',
        axisPointer: { type: 'cross' },
        formatter: (params) => {
          if (!params || !params.length) return '';
          const shape = params[0].axisValueLabel || params[0].name;
          const header = panelLabel
            ? escapeHtml(panelLabel) + ' ' + escapeHtml(shape)
            : escapeHtml(shape);
          const lines = ['<strong>' + header + '</strong> <span style="opacity:0.8;">(' + THROUGHPUT_BADGE_TEXT + ')</span>'];
          const baseVal = baselineByShape && baselineByShape.get(shape);
          for (const p of params) {
            if (p.value == null) continue;
            const lib = (p.seriesName || '').replace(/ \*$/, '');
            const isLfq = isLockfreequeues(lib);
            // Find the matching point for stddev.
            const sObj = echartsSeries[p.seriesIndex];
            const point = sObj && sObj._points
              && sObj._points.find((q) => q.shape === shape);
            const libHtml = isLfq
              ? '<strong>' + escapeHtml(lib) + '</strong>'
              : escapeHtml(lib);
            let line = '<span style="display:inline-block;width:8px;height:8px;'
              + 'border-radius:50%;background:' + p.color
              + ';margin-right:6px;"></span>'
              + libHtml + ': ';
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
        bottom: 4,
        left: 'center',
        width: '96%',
        itemGap: 14,
        padding: [8, 8, 4, 8],
        formatter: (name) => {
          const rawLib = String(name).replace(/ \*$/, '');
          return isLockfreequeues(rawLib) ? '{lfq|' + name + '}' : name;
        },
        textStyle: Object.assign({}, buildPaletteOpt().legend.textStyle, {
          rich: {
            lfq: {
              fontWeight: 'bold',
              color: pal.fg,
            },
          },
        }),
        data: series.map((lib) => displayLabel(lib.library)),
      }),
      xAxis: Object.assign({}, buildPaletteOpt().xAxis, {
        type: 'category',
        data: xLabels,
        name: 'producer/consumer shape (P×C)',
        nameLocation: 'middle',
        nameGap: 28,
      }),
      yAxis: Object.assign({}, buildPaletteOpt().yAxis, {
        type: logScale ? 'log' : 'value',
        name: (isRel
          ? 'Relative speedup (x vs stdlib Channel)'
          : 'Throughput (ops/ms)') + (logScale ? ' [log]' : '') + ' — Higher is better ↑',
        nameLocation: 'middle',
        nameGap: 52,
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
    const baseMap = libsByShape.get('nim_channels')
      || libsByShape.get('nim_channel')
      || libsByShape.get('nim_channel_sync')
      || libsByShape.get('locked_table')
      || libsByShape.get('locked_set')
      || libsByShape.get('locked_stack')
      || libsByShape.get('locked_task_queue')
      || libsByShape.get('mutex_guard')
      || libsByShape.get('deferred_mutex_free');
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
    series.sort((a, b) => {
      const aLfq = isLockfreequeues(a.library) ? 0 : 1;
      const bLfq = isLockfreequeues(b.library) ? 0 : 1;
      if (aLfq !== bLfq) return aLfq - bLfq;
      return a.library.localeCompare(b.library);
    });

    if (series.length === 0) {
      host.appendChild(el('p', { class: 'bench-chart-empty' },
        'No plottable values for this topology.'));
      return;
    }

    const xLabels = sortShapeLabels(shapeSet);
    let logScale = true;

    const controls = buildControls(panel.id, logScale, (next) => {
      logScale = next;
      inst.setOption(buildThroughputOption(series, xLabels, logScale, panel.label, baselineByShape, panel.id),
        { notMerge: true });
    });
    const mount = el('div', { class: 'bench-chart-plot' });
    host.appendChild(controls);
    host.appendChild(mount);

    let inst = window.echarts.init(
      mount, isLightScheme() ? null : 'dark', { renderer: 'canvas' }
    );
    inst.setOption(buildThroughputOption(series, xLabels, logScale, panel.label, baselineByShape, panel.id));
    registerChart(inst, () => {
      inst.dispose();
      inst = window.echarts.init(
        mount, isLightScheme() ? null : 'dark', { renderer: 'canvas' }
      );
      inst.setOption(buildThroughputOption(series, xLabels, logScale, panel.label, baselineByShape, panel.id));
      const idx = _charts.findIndex((c) => c.instance && c.instance.isDisposed
        && c.instance.isDisposed());
      if (idx >= 0) _charts[idx].instance = inst;
    });
  }

  // ── module: latency panel ──────────────────────────────────────────

  const LATENCY_PERCENTILES = Object.freeze([
    { key: 'latency_p50_ns',  label: 'p50 (ns)'  },
    { key: 'latency_p95_ns',  label: 'p95 (ns)'  },
    { key: 'latency_p99_ns',  label: 'p99 (ns)'  },
    { key: 'latency_p999_ns', label: 'p999 (ns)' },
    { key: 'latency_max_ns',  label: 'max (ns)'  },
  ]);

  function collectLatencySeries(bmf, topologyFilter) {
    const byLibrary = new Map();
    let hadAny = false;
    const slugs = Object.keys(bmf).filter(isMeasurementSlug).sort();
    for (const slug of slugs) {
      const measureMap = bmf[slug];
      if (!measureMap || typeof measureMap !== 'object') continue;
      const parsed = parseSlug(slug);
      if (!parsed) continue;
      if (topologyFilter && !topologyFilter(parsed.topology)) continue;
      const hasLatency = LATENCY_PERCENTILES.some((p) => {
        const m = measureMap[p.key];
        return m && typeof m.value === 'number' && Number.isFinite(m.value);
      });
      if (!hasLatency) continue;
      hadAny = true;
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
      .sort((a, b) => {
        const aLfq = isLockfreequeues(a.library) ? 0 : 1;
        const bLfq = isLockfreequeues(b.library) ? 0 : 1;
        if (aLfq !== bLfq) return aLfq - bLfq;
        return a.library.localeCompare(b.library);
      });
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

  function buildLatencyControls(panelId, initialMode, initialLogScale, onChange) {
    const wrap = el('div', { class: 'bench-chart-controls' });
    wrap.appendChild(buildDirectionBadge('latency'));

    let mode = initialMode || 'ladder';
    let logScale = initialLogScale !== false;

    const modeGroup = el('div', { class: 'bench-chip-group' });
    const ladderBtn = el('button', {
      class: 'bench-chip' + (mode === 'ladder' ? ' active' : ''),
      type: 'button',
    }, 'Percentile Ladder');
    const barBtn = el('button', {
      class: 'bench-chip' + (mode === 'bar' ? ' active' : ''),
      type: 'button',
    }, 'Grouped Bars');

    ladderBtn.addEventListener('click', () => {
      if (mode === 'ladder') return;
      mode = 'ladder';
      ladderBtn.classList.add('active');
      barBtn.classList.remove('active');
      onChange(mode, logScale);
    });
    barBtn.addEventListener('click', () => {
      if (mode === 'bar') return;
      mode = 'bar';
      barBtn.classList.add('active');
      ladderBtn.classList.remove('active');
      onChange(mode, logScale);
    });
    modeGroup.appendChild(ladderBtn);
    modeGroup.appendChild(barBtn);
    wrap.appendChild(modeGroup);

    const id = 'bench-lat-log-scale-' + panelId;
    const cb = el('input', { type: 'checkbox', id });
    cb.checked = logScale;
    cb.addEventListener('change', () => {
      logScale = cb.checked;
      onChange(mode, logScale);
    });
    const lbl = el('label', { for: id }, 'Log-scale Y axis');
    wrap.appendChild(el('span', { class: 'bench-control-item' }, cb, lbl));
    return wrap;
  }

  function buildLatencyOption(libraries, xLabels, chartMode, logScale) {
    const pal = readPalette();
    const useBar = chartMode === 'bar';
    const useLog = logScale !== false;

    const echartsSeries = libraries.map((lib) => {
      const isLfq = isLockfreequeues(lib.library);
      if (useBar) {
        return {
          name: displayLabel(lib.library),
          type: 'bar',
          barMaxWidth: 28,
          data: lib.values.slice(),
          emphasis: { focus: 'series' },
          label: {
            fontWeight: isLfq ? 'bold' : 'normal',
          },
          itemStyle: {
            color: getColor(lib.library),
            borderColor: isLfq ? '#6366f1' : getColor(lib.library),
            borderType: isBlocking(lib.library) ? 'dashed' : 'solid',
            borderWidth: isLfq ? 2 : (isBlocking(lib.library) ? 1.5 : 0),
          },
        };
      }
      return {
        name: displayLabel(lib.library),
        type: 'line',
        step: 'end',
        data: lib.values.slice(),
        connectNulls: false,
        showSymbol: true,
        symbolSize: isLfq ? 9 : 6,
        z: isLfq ? 4 : 2,
        emphasis: { focus: 'series' },
        label: {
          fontWeight: isLfq ? 'bold' : 'normal',
        },
        lineStyle: {
          width: isLfq ? 3 : 2,
          type: isBlocking(lib.library) ? 'dashed' : 'solid',
        },
        itemStyle: { color: getColor(lib.library) },
      };
    });

    const legendRows = Math.max(1, Math.ceil(libraries.length / 4));
    const bottomPx = Math.max(98, 58 + legendRows * 26);

    return Object.assign({}, buildPaletteOpt(), {
      title: {
        subtext: LATENCY_BADGE_TEXT,
        right: 16,
        top: 0,
        subtextStyle: {
          color: pal.fgLight,
          fontSize: 12,
          fontWeight: 'bold',
        },
      },
      grid: { left: 68, right: 28, top: 36, bottom: bottomPx, containLabel: true },
      tooltip: Object.assign({}, buildPaletteOpt().tooltip, {
        trigger: 'axis',
        axisPointer: { type: useBar ? 'shadow' : 'cross' },
        formatter: (params) => {
          if (!params || !params.length) return '';
          const label = params[0].axisValueLabel || params[0].name;
          const lines = ['<strong>' + escapeHtml(label) + '</strong> <span style="opacity:0.8;">(' + LATENCY_BADGE_TEXT + ')</span>'];
          for (const p of params) {
            if (p.value == null) continue;
            const lib = (p.seriesName || '').replace(/ \*$/, '');
            const isLfq = isLockfreequeues(lib);
            const libHtml = isLfq
              ? '<strong>' + escapeHtml(lib) + '</strong>'
              : escapeHtml(lib);
            let line = '<span style="display:inline-block;width:8px;height:8px;'
              + 'border-radius:50%;background:' + p.color
              + ';margin-right:6px;"></span>'
              + libHtml + ': ' + p.value.toFixed(0) + ' ns';
            if (isBlocking(lib)) line += ' (blocking)';
            lines.push(line);
          }
          return lines.join('<br>');
        },
      }),
      legend: Object.assign({}, buildPaletteOpt().legend, {
        type: 'plain',
        bottom: 4,
        left: 'center',
        width: '96%',
        itemGap: 14,
        padding: [8, 8, 4, 8],
        formatter: (name) => {
          const rawLib = String(name).replace(/ \*$/, '');
          return isLockfreequeues(rawLib) ? '{lfq|' + name + '}' : name;
        },
        textStyle: Object.assign({}, buildPaletteOpt().legend.textStyle, {
          rich: {
            lfq: {
              fontWeight: 'bold',
              color: pal.fg,
            },
          },
        }),
        data: libraries.map((lib) => displayLabel(lib.library)),
      }),
      xAxis: Object.assign({}, buildPaletteOpt().xAxis, {
        type: 'category',
        data: xLabels,
        name: 'Latency percentile (ns)',
        nameLocation: 'middle',
        nameGap: 28,
      }),
      yAxis: Object.assign({}, buildPaletteOpt().yAxis, {
        type: useLog ? 'log' : 'value',
        logBase: 10,
        name: 'Latency (ns)' + (useLog ? ' [log]' : '') + ' — Lower is better ↓',
        nameLocation: 'middle',
        nameGap: 56,
        axisLabel: Object.assign({}, buildPaletteOpt().yAxis.axisLabel, {
          formatter: (value) => {
            if (value >= 10000) return value.toExponential(0).replace('e+', 'e') + ' ns';
            return value.toString() + ' ns';
          },
        }),
      }),
      series: echartsSeries,
    });
  }

  function renderLatencyPanel(host, bmf, panelId, topologyFilter) {
    if (!host) return;
    host.innerHTML = '';
    const effectivePanelId = panelId || 'bench-latency';
    // NOTE: heading text is owned by the `#### Latency` markdown in
    // docs/benchmarks.md; do NOT inject a duplicate <h4> here. Locate
    // the markdown-rendered heading and decorate it with the source-
    // code link so the latency panel matches the throughput panels.
    const latencyHeading = findPrecedingHeading(host);
    if (latencyHeading) appendSourceLink(latencyHeading, effectivePanelId);

    if (!bmf || typeof bmf !== 'object') {
      host.appendChild(el('p', { class: 'bench-chart-empty' },
        LATENCY_EMPTY_MESSAGE));
      return;
    }

    const { libraries, hadAny } = collectLatencySeries(bmf, topologyFilter);
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
    let chartMode = 'ladder';
    let logScale = true;

    const controls = buildLatencyControls(effectivePanelId, chartMode, logScale, (nextMode, nextLog) => {
      chartMode = nextMode;
      logScale = nextLog;
      inst.setOption(buildLatencyOption(libraries, xLabels, chartMode, logScale), { notMerge: true });
    });
    const mount = el('div', { class: 'bench-chart-plot' });
    host.appendChild(controls);
    host.appendChild(mount);

    let inst = window.echarts.init(
      mount, isLightScheme() ? null : 'dark', { renderer: 'canvas' }
    );
    inst.setOption(buildLatencyOption(libraries, xLabels, chartMode, logScale));
    registerChart(inst, () => {
      inst.dispose();
      inst = window.echarts.init(
        mount, isLightScheme() ? null : 'dark', { renderer: 'canvas' }
      );
      inst.setOption(buildLatencyOption(libraries, xLabels, chartMode, logScale));
      const idx = _charts.findIndex((c) => c.instance && c.instance.isDisposed
        && c.instance.isDisposed());
      if (idx >= 0) _charts[idx].instance = inst;
    });

    if (effectivePanelId === 'bench-latency') {
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
    renderLatencyPanel(document.getElementById('bench-latency'), null, 'bench-latency');
    renderLatencyPanel(document.getElementById('bench-rendezvous-latency'), null, 'bench-rendezvous-latency');
    renderLatencyPanel(document.getElementById('bench-smr-latency'), null, 'bench-smr-latency');
  }

  // ── module: interactive toolbar ─────────────────────────────────────

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
      _currentBmfResult.data || null,
      'bench-latency',
      (t) => t === 'spsc' || t === 'spmc' || t === 'mpsc' || t === 'mpmc'
    );
    renderLatencyPanel(
      document.getElementById('bench-rendezvous-latency'),
      _currentBmfResult.data || null,
      'bench-rendezvous-latency',
      (t) => t === 'rendezvous_rpc' || t === 'rendezvous_handoff'
    );
    renderLatencyPanel(
      document.getElementById('bench-smr-latency'),
      _currentBmfResult.data || null,
      'bench-smr-latency',
      (t) => t === 'smr_pin_unpin' || t === 'smr_retire_reclaim' || t === 'pin_unpin' || t === 'retire_reclaim'
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
    const hasAnyHost = heroHost || toolbarHost ||
      THROUGHPUT_PANELS.some((p) => document.getElementById(p.id)) ||
      document.getElementById('bench-latency') ||
      document.getElementById('bench-rendezvous-latency') ||
      document.getElementById('bench-smr-latency');
    if (!hasAnyHost) return;

    if (toolbarHost) renderToolbar(toolbarHost);

    renderLatencyPanel(document.getElementById('bench-latency'), null, 'bench-latency');
    renderLatencyPanel(document.getElementById('bench-rendezvous-latency'), null, 'bench-rendezvous-latency');
    renderLatencyPanel(document.getElementById('bench-smr-latency'), null, 'bench-smr-latency');

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
