/* lockfree bench charts — Observable Plot (@observablehq/plot) pure SVG engine.
 *
 * Loads the merged Bencher Metric Format (BMF) snapshot from
 * `../assets/bench-results/latest.json` (with fallback to `example.json`).
 *
 * Rendering: Observable Plot 0.6.17 + D3 7.9.0 (vendored UMD bundles).
 * Renders responsive, pure-SVG figures with automatic flow legends and
 * margins that inherit Material for MkDocs CSS variables for instant
 * light/dark theme switching and zero axis/legend overlap.
 *
 * Page architecture (multi-panel):
 *   #bench-hero                       — Ranked horizontal bar (Plot.barX)
 *   #bench-throughput-spsc            — Ranked horizontal bar (Plot.barX)
 *   #bench-throughput-mpsc            — Multi-series line + dot (Plot.line + Plot.dot)
 *   #bench-throughput-mpmc-bounded    — Multi-series line + dot (Plot.line + Plot.dot)
 *   #bench-throughput-mpmc-unbounded  — Multi-series line + dot (Plot.line + Plot.dot)
 *   #bench-latency                    — Percentile ladder / grouped bars (ns)
 *   #bench-status                     — Banner injected on fallback
 */

(function () {
  'use strict';

  // ── module: constants ───────────────────────────────────────────────
  const CHART_MEASURE = 'throughput_ops_ms';
  const LOCKFREE_PRIMARY_COLOR = '#6366f1';

  // CONTRACT-TEST-PARSED-START LIBRARY_COLORS
  const LIBRARY_COLORS = Object.freeze({
    // lockfree queue family (bounded) — distinct chromatic palette
    lockfree_spsc:           '#6366f1',
    lockfree_spmc:           '#0891b2',
    lockfree_mpsc:           '#7c3aed',
    lockfree_mpmc:           '#2563eb',
    lockfree_bqueue128:      '#06b6d4',
    lockfree_cabi:           '#0284c7',
    // lockfree queue family (unbounded) — corresponding lighter tints
    lockfree_unbounded_spsc: '#818cf8',
    lockfree_unbounded_spmc: '#22d3ee',
    lockfree_unbounded_mpsc: '#a78bfa',
    lockfree_unbounded_mpmc: '#60a5fa',
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
    tagged_stack:               '#06b6d4',
    locked_stack:               '#78909c',
    boost_lockfree_stack:       '#00897b',
    chase_lev_deque:            '#6366f1',
    chase_lev_deque_batch:      '#4f46e5',
    crossbeam_deque:            '#f4511e',
    crossbeam_deque_batch:      '#d84315',
    bpriority_queue:            '#6366f1',
    skiplist_pq:                '#00897b',
    locked_pq:                  '#78909c',
    // disjoint-set / union-find
    disjoint_set:               '#6366f1',
    locked_disjoint_set:        '#78909c',
    // broadcast ring & topic bus
    broadcast_ring_drop:        '#6366f1',
    broadcast_ring_backoff:     '#0277bd',
    topic_bus_drop:             '#4f46e5',
    topic_bus_backoff:          '#01579b',
    tokio_broadcast:            '#f4511e',
    rust_bus:                   '#fb8c00',
    // rate limiting & streaming
    token_bucket:               '#6366f1',
    token_bucket64:             '#818cf8',
    leaky_bucket:               '#4f46e5',
    leaky_bucket64:             '#a78bfa',
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
    'locked_disjoint_set',
    'broadcast_ring_backoff', 'topic_bus_backoff',
    'mutex_guard', 'deferred_mutex_free',
  ];
  // CONTRACT-TEST-PARSED-END BLOCKING_LIBRARIES
  const BLOCKING_SET = new Set(BLOCKING_LIBRARIES);

  const LOCKFREE_FAMILY = [
    'lockfree_spsc', 'lockfree_spmc',
    'lockfree_mpsc', 'lockfree_mpmc',
    'lockfree_cabi',
    'lockfree_unbounded_spsc', 'lockfree_unbounded_spmc',
    'lockfree_unbounded_mpsc', 'lockfree_unbounded_mpmc',
    'ctrie', 'btable', 'skiplist', 'skiplist_set',
    'disjoint_set',
    'treiber_stack', 'bstack', 'tagged_stack', 'chase_lev_deque', 'chase_lev_deque_batch',
    'bpriority_queue', 'skiplist_pq',
    'broadcast_ring_drop', 'broadcast_ring_backoff',
    'topic_bus_drop', 'topic_bus_backoff',
    'token_bucket', 'token_bucket64', 'leaky_bucket', 'leaky_bucket64', 'stream_ring',
    'rendezvous_channel', 'taskpool', 'nebr',
  ];
  const LFQ_FAMILY_SET = new Set(LOCKFREE_FAMILY);

  const LIBRARY_ECOSYSTEMS = Object.freeze({
    // Nim native & stdlib
    lockfree_spsc: 'nim', lockfree_spmc: 'nim', lockfree_mpsc: 'nim', lockfree_mpmc: 'nim',
    lockfree_cabi: 'c',
    lockfree_unbounded_spsc: 'nim', lockfree_unbounded_spmc: 'nim',
    lockfree_unbounded_mpsc: 'nim', lockfree_unbounded_mpmc: 'nim',
    nim_channel: 'nim', nim_channels: 'nim', nim_channel_sync: 'nim',
    threading_channels: 'nim', loony: 'nim',
    ctrie: 'nim', btable: 'nim', skiplist: 'nim', skiplist_set: 'nim',
    disjoint_set: 'nim', locked_disjoint_set: 'nim',
    locked_table: 'nim', locked_set: 'nim',
    treiber_stack: 'nim', bstack: 'nim', tagged_stack: 'nim', locked_stack: 'nim',
    chase_lev_deque: 'nim', chase_lev_deque_batch: 'nim',
    bpriority_queue: 'nim', skiplist_pq: 'nim', locked_pq: 'nim',
    broadcast_ring_drop: 'nim', broadcast_ring_backoff: 'nim',
    topic_bus_drop: 'nim', topic_bus_backoff: 'nim',
    token_bucket: 'nim', token_bucket64: 'nim', leaky_bucket: 'nim', leaky_bucket64: 'nim', stream_ring: 'nim',
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
  let _activeEnvironment = null; // environment ID key if multi-environment
  let _currentBmfResult = null;
  const _rebuildCallbacks = [];

  function getEnvironments() {
    if (!_currentBmfResult || !_currentBmfResult.data) return null;
    const meta = _currentBmfResult.data.meta;
    if (meta && meta.environments && typeof meta.environments === 'object') {
      return meta.environments;
    }
    return null;
  }

  function getActiveHost() {
    const envs = getEnvironments();
    if (envs) {
      if (!_activeEnvironment || !envs[_activeEnvironment]) {
        _activeEnvironment = Object.keys(envs)[0];
      }
      return (envs[_activeEnvironment] && envs[_activeEnvironment].host) || {};
    }
    if (_currentBmfResult && _currentBmfResult.data && _currentBmfResult.data.meta) {
      return _currentBmfResult.data.meta.host || {};
    }
    return {};
  }

  function getActiveBenchmarkData() {
    const envs = getEnvironments();
    if (envs) {
      if (!_activeEnvironment || !envs[_activeEnvironment]) {
        _activeEnvironment = Object.keys(envs)[0];
      }
      const envObj = envs[_activeEnvironment];
      return (envObj && (envObj.benchmarks || envObj.data)) || {};
    }
    if (_currentBmfResult && _currentBmfResult.data) {
      return _currentBmfResult.data;
    }
    return {};
  }

  function matchesEcosystem(library) {
    if (_activeEcosystem === 'all') return true;
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
    disjoint_set_find: 'DisjointSet find (Read Contention)',
    disjoint_set_union: 'DisjointSet union & sameSet (Graph Edge Stream)',
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
    // Concurrent Disjoint-Set (Union-Find)
    { id: 'bench-disjoint-set-find',         label: 'DisjointSet find Contention',
      includes: (topology) => topology === 'disjoint_set_find' },
    { id: 'bench-disjoint-set-union',        label: 'DisjointSet union & sameSet Edge Stream',
      includes: (topology) => topology === 'disjoint_set_union' },
  ];

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
    'bench-disjoint-set-find':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_disjoint_set.nim',
    'bench-disjoint-set-union':
      'https://github.com/elijahr/lockfree/blob/main/benchmarks/nim/bench_disjoint_set.nim',
  });

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

  function findPrecedingHeading(panelNode) {
    let node = panelNode;
    for (let hop = 0; hop < 4 && node; hop += 1) {
      let sib = node.previousElementSibling;
      while (sib) {
        if (/^H[1-6]$/.test(sib.tagName)) return sib;
        if (sib.tagName !== 'SCRIPT' && sib.tagName !== 'NOSCRIPT') {
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
    if (typeof library !== 'string') return false;
    return LFQ_FAMILY_SET.has(library) || library.startsWith('lockfree_') || library.startsWith('lockfree.');
  }
  const isLockfreequeues = isLockfree;

  const CONTENDER_METADATA = Object.freeze({
    // lockfree queue family (bounded)
    lockfree_spsc:           { name: 'lockfree.spsc.SPSCQueue',                 lang: 'Nim' },
    lockfree_spmc:           { name: 'lockfree.spmc.SPMCQueue',                 lang: 'Nim' },
    lockfree_mpsc:           { name: 'lockfree.mpsc.MPSCQueue',                 lang: 'Nim' },
    lockfree_mpmc:           { name: 'lockfree.bqueue.BQueue',                  lang: 'Nim' },
    lockfree_bqueue128:      { name: 'lockfree.bqueue128.BQueue128',            lang: 'Nim' },
    lockfree_cabi:           { name: 'lockfree.cabi.BQueue',                    lang: 'C-ABI' },

    // lockfree queue family (unbounded)
    lockfree_unbounded_spsc: { name: 'lockfree.uqueue.Queue (SPSC)',            lang: 'Nim' },
    lockfree_unbounded_spmc: { name: 'lockfree.uqueue.Queue (SPMC)',            lang: 'Nim' },
    lockfree_unbounded_mpsc: { name: 'lockfree.uqueue.Queue (MPSC)',            lang: 'Nim' },
    lockfree_unbounded_mpmc: { name: 'lockfree.uqueue.Queue',                   lang: 'Nim' },

    // legacy aliases for backward compatibility with older snapshots
    lockfree_queue_bounded_spsc: { name: 'lockfree.spsc.SPSCQueue',             lang: 'Nim' },
    lockfree_queue_bounded_spmc: { name: 'lockfree.spmc.SPMCQueue',             lang: 'Nim' },
    lockfree_queue_bounded_mpsc: { name: 'lockfree.mpsc.MPSCQueue',             lang: 'Nim' },
    lockfree_queue_bounded_mpmc: { name: 'lockfree.bqueue.BQueue',              lang: 'Nim' },

    // associative maps & sets
    ctrie:                      { name: 'lockfree.ctrie.CTrie',                 lang: 'Nim' },
    btable:                     { name: 'lockfree.btable.BTable',               lang: 'Nim' },
    skiplist:                   { name: 'lockfree.skiplist.SkipList',           lang: 'Nim' },
    skiplist_set:               { name: 'lockfree.skiplist.SkipListSet',        lang: 'Nim' },
    locked_table:               { name: 'std.tables.Table (Lock)',              lang: 'Nim' },
    locked_set:                 { name: 'std.sets.HashSet (Lock)',              lang: 'Nim' },
    dashmap:                    { name: 'dashmap::DashMap',                     lang: 'Rust' },
    flurry:                     { name: 'flurry::HashMap',                      lang: 'Rust' },
    crossbeam_skipmap:          { name: 'crossbeam_skiplist::SkipMap',          lang: 'Rust' },
    crossbeam_skipset:          { name: 'crossbeam_skiplist::SkipSet',          lang: 'Rust' },
    boost_concurrent_flat_map:  { name: 'boost::unordered::concurrent_flat_map', lang: 'C++' },
    boost_concurrent_flat_set:  { name: 'boost::unordered::concurrent_flat_set', lang: 'C++' },

    // stacks, deques & priority queues
    treiber_stack:              { name: 'lockfree.treiber_stack.TreiberStack',  lang: 'Nim' },
    bstack:                     { name: 'lockfree.bstack.BStack',               lang: 'Nim' },
    tagged_stack:               { name: 'lockfree.stack128.TaggedStack',        lang: 'Nim' },
    locked_stack:               { name: 'std.deques.Deque (Lock)',              lang: 'Nim' },
    boost_lockfree_stack:       { name: 'boost::lockfree::stack',               lang: 'C++' },
    chase_lev_deque:            { name: 'lockfree.chase_lev.ChaseLevDeque',     lang: 'Nim' },
    chase_lev_deque_batch:      { name: 'lockfree.chase_lev.ChaseLevDeque (Batch)', lang: 'Nim' },
    crossbeam_deque:            { name: 'crossbeam_deque::Injector',            lang: 'Rust' },
    crossbeam_deque_batch:      { name: 'crossbeam_deque::Injector (Batch)',    lang: 'Rust' },
    bpriority_queue:            { name: 'lockfree.bpriority_queue.BPriorityQueue', lang: 'Nim' },
    skiplist_pq:                { name: 'lockfree.skiplist.SkipListPQ',         lang: 'Nim' },
    locked_pq:                  { name: 'std.heapqueue.HeapQueue (Lock)',       lang: 'Nim' },

    // disjoint-set / union-find
    disjoint_set:               { name: 'lockfree.disjoint_set.DisjointSet',    lang: 'Nim' },
    locked_disjoint_set:        { name: 'disjoint_set.DisjointSet (Lock)',      lang: 'Nim' },

    // broadcast ring & topic bus
    broadcast_ring_drop:        { name: 'lockfree.broadcast.BroadcastRing (Drop)', lang: 'Nim' },
    broadcast_ring_backoff:     { name: 'lockfree.broadcast.BroadcastRing (Wait)', lang: 'Nim' },
    topic_bus_drop:             { name: 'lockfree.topic_bus.TopicBus (Drop)',   lang: 'Nim' },
    topic_bus_backoff:          { name: 'lockfree.topic_bus.TopicBus (Wait)',   lang: 'Nim' },
    tokio_broadcast:            { name: 'tokio::sync::broadcast',               lang: 'Rust' },
    rust_bus:                   { name: 'bus::Bus',                             lang: 'Rust' },

    // rate limiting & streaming
    token_bucket:               { name: 'lockfree.ratelimit.TokenBucket',       lang: 'Nim' },
    token_bucket64:             { name: 'lockfree.ratelimit.TokenBucket64',     lang: 'Nim' },
    leaky_bucket:               { name: 'lockfree.ratelimit.LeakyBucket',       lang: 'Nim' },
    leaky_bucket64:             { name: 'lockfree.ratelimit.LeakyBucket64',     lang: 'Nim' },
    governor_gcra:              { name: 'governor::RateLimiter',                lang: 'Rust' },
    stream_ring:                { name: 'lockfree.streambuffer.StreamRing',     lang: 'Nim' },
    rtrb_stream:                { name: 'rtrb::RingBuffer',                     lang: 'Rust' },
    boost_spsc_stream:          { name: 'boost::lockfree::spsc_queue (Stream)', lang: 'C++' },

    // synchronous rendezvous (0-buffer channel)
    rendezvous_channel:         { name: 'lockfree.rendezvous.RendezvousChannel', lang: 'Nim' },
    nim_channel_sync:           { name: 'system.Channel (Sync)',                lang: 'Nim' },
    crossbeam_rendezvous:       { name: 'crossbeam_channel::bounded(0)',        lang: 'Rust' },
    flume_rendezvous:           { name: 'flume::bounded(0)',                    lang: 'Rust' },
    kanal_rendezvous:           { name: 'kanal::bounded(0)',                    lang: 'Rust' },

    // work-stealing taskpool
    taskpool:                   { name: 'lockfree.taskpool.TaskPool',           lang: 'Nim' },
    locked_task_queue:          { name: 'std.taskpool (Locked)',                lang: 'Nim' },
    rayon_pool:                 { name: 'rayon::ThreadPool',                    lang: 'Rust' },

    // safe memory reclamation (NEBR / epoch)
    nebr:                       { name: 'lockfree.nebr.NEBR',                   lang: 'Nim' },
    arc_atomic_rc:              { name: 'std.sharedptr.AtomicSharedPtr',        lang: 'Nim' },
    mutex_guard:                { name: 'std.locks.Lock Guard',                 lang: 'Nim' },
    deferred_mutex_free:        { name: 'std.deferred.MutexFree',              lang: 'Nim' },
    crossbeam_epoch:            { name: 'crossbeam_epoch::Collector',           lang: 'Rust' },

    // comparison libraries (Queues / Channels)
    crossbeam_array_queue:      { name: 'crossbeam::queue::ArrayQueue',         lang: 'Rust' },
    crossbeam_seg_queue:        { name: 'crossbeam::queue::SegQueue',           lang: 'Rust' },
    moodycamel:                 { name: 'moodycamel::ConcurrentQueue',          lang: 'C++' },
    boost_lockfree_queue:       { name: 'boost::lockfree::queue',               lang: 'C++' },
    boost_lockfree_spsc:        { name: 'boost::lockfree::spsc_queue',          lang: 'C++' },
    loony:                      { name: 'loony.LoonyQueue',                     lang: 'Nim' },
    threading_channels:         { name: 'threading.Chan',                       lang: 'Nim' },
    nim_channel:                { name: 'system.Channel (MPSC)',                lang: 'Nim' },
    nim_channels:               { name: 'system.Channel (MPMC)',                lang: 'Nim' },
    atomic_queue:               { name: 'atomic_queue::AtomicQueue2',           lang: 'C++' },
    rigtorp_mpmc:               { name: 'rigtorp::MPMCQueue',                   lang: 'C++' },
    rigtorp_spsc:               { name: 'rigtorp::SPSCQueue',                   lang: 'C++' },
    flume:                      { name: 'flume::bounded',                       lang: 'Rust' },
    flume_unbounded:            { name: 'flume::unbounded',                     lang: 'Rust' },
    kanal:                      { name: 'kanal::bounded',                       lang: 'Rust' },
    kanal_unbounded:            { name: 'kanal::unbounded',                     lang: 'Rust' },
    liblfds:                    { name: 'liblfds::freelist',                    lang: 'C' },
  });

  function displayLabel(library) {
    const meta = CONTENDER_METADATA[library];
    const name = meta ? meta.name : library;
    const lang = meta ? meta.lang : (LIBRARY_ECOSYSTEMS[library] === 'cpp' ? 'C++' : LIBRARY_ECOSYSTEMS[library] === 'rust' ? 'Rust' : 'Nim');
    const langTag = lang ? ' (' + lang + ')' : '';
    const asterisk = isBlocking(library) ? ' *' : '';
    return name + langTag + asterisk;
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

  function getPlotWidth(container) {
    if (!container) return 760;
    const w = container.clientWidth || (container.parentElement && container.parentElement.clientWidth) || 760;
    return Math.max(340, Math.min(1100, w));
  }

  function hasPlot() {
    return typeof window.Plot === 'object' && typeof window.Plot.plot === 'function';
  }

  // Emphasize `lockfree` labels inside rendered Observable Plot SVG axes and HTML legends
  function emphasizeLockfreeSvgAndLegend(container) {
    if (!container) return;
    const texts = container.querySelectorAll('svg text');
    for (const t of texts) {
      const raw = (t.textContent || '').trim().replace(/ \*$/, '');
      if (raw.startsWith('lockfree.') || isLockfreequeues(raw)) {
        t.setAttribute('font-weight', '700');
        t.style.fontWeight = '700';
      }
    }
    const swatches = container.querySelectorAll('[class*="-swatch"]');
    for (const s of swatches) {
      if (s.className && s.className.includes('swatches')) continue;
      const raw = (s.textContent || '').trim().replace(/ \*$/, '');
      if (raw.startsWith('lockfree.') || isLockfreequeues(raw)) {
        s.style.fontWeight = '700';
      }
    }
  }

  // Interactive Legend: hover highlighting, click-to-toggle, and hide-all / show-all
  function wireInteractivePlot(mount) {
    if (!mount) return null;
    const svg = mount.querySelector('svg');
    if (!svg) return null;

    // Observable Plot generates a container with class `*-swatches` and individual items
    // with class `*-swatch`. We strictly select individual swatches and exclude the container.
    const rawSwatches = Array.from(mount.querySelectorAll('[class*="-swatch"]'))
      .filter((s) => !s.className.includes('swatches') && s.textContent.trim().length > 0);

    if (rawSwatches.length === 0) return null;

    const seriesList = [];
    rawSwatches.forEach((s, idx) => {
      const seriesId = 's-' + idx;
      s.setAttribute('data-series-id', seriesId);
      const label = s.textContent.trim().replace(/ \*$/, '');
      const svgEl = s.querySelector('svg');
      let color = null;
      if (svgEl) {
        color = svgEl.getAttribute('fill') || svgEl.style.fill;
        if (!color) {
          const innerWithFill = svgEl.querySelector('[fill], path, circle');
          if (innerWithFill) color = innerWithFill.getAttribute('fill') || innerWithFill.style.fill;
        }
      }
      if (!color) {
        const bgSpan = s.querySelector('span[style*="background"], [style*="background-color"]');
        if (bgSpan) color = bgSpan.style.backgroundColor;
      }
      if (!color) {
        for (const [lib, meta] of Object.entries(CONTENDER_METADATA)) {
          if (meta.name && label.startsWith(meta.name)) {
            color = getColor(lib);
            break;
          }
        }
      }
      seriesList.push({
        id: seriesId,
        label: label,
        color: (color || '').toLowerCase(),
        el: s,
      });
    });

    // Tag SVG marks with matching data-series-id
    const marks = svg.querySelectorAll('g[aria-label="line"] path, g[aria-label="dot"] path, g[aria-label="dot"] circle, g[aria-label="bar"] rect, g[aria-label="bar"] path');
    for (const m of marks) {
      const stroke = (m.getAttribute('stroke') || (m.parentElement ? m.parentElement.getAttribute('stroke') : '') || '').toLowerCase();
      const fill = (m.getAttribute('fill') || (m.parentElement ? m.parentElement.getAttribute('fill') : '') || '').toLowerCase();
      const titleEl = m.querySelector('title') || (m.parentElement ? m.parentElement.querySelector('title') : null);
      const titleText = titleEl ? titleEl.textContent : '';

      for (const s of seriesList) {
        const colorMatch = s.color && (stroke === s.color || fill === s.color);
        const titleMatch = s.label && titleText && titleText.startsWith(s.label);
        if (colorMatch || titleMatch) {
          m.setAttribute('data-series-id', s.id);
          break;
        }
      }
    }

    // Attach hover and click to each swatch
    for (const s of seriesList) {
      s.el.addEventListener('mouseenter', () => {
        mount.classList.add('bench-has-highlight');
        const targetMarks = svg.querySelectorAll(`[data-series-id="${s.id}"]`);
        for (const tm of targetMarks) {
          tm.classList.add('bench-highlighted');
          if (tm.tagName.toLowerCase() === 'path' && tm.getAttribute('stroke')) {
            tm.setAttribute('data-orig-width', tm.getAttribute('stroke-width') || '2');
            tm.setAttribute('stroke-width', '4.5');
          }
        }
      });

      s.el.addEventListener('mouseleave', () => {
        mount.classList.remove('bench-has-highlight');
        const targetMarks = svg.querySelectorAll(`[data-series-id="${s.id}"]`);
        for (const tm of targetMarks) {
          tm.classList.remove('bench-highlighted');
          const orig = tm.getAttribute('data-orig-width');
          if (orig) {
            tm.setAttribute('stroke-width', orig);
            tm.removeAttribute('data-orig-width');
          }
        }
      });

      s.el.addEventListener('click', (e) => {
        e.stopPropagation();
        const isHidden = s.el.classList.toggle('bench-swatch-disabled');
        const targetMarks = svg.querySelectorAll(`[data-series-id="${s.id}"]`);
        for (const tm of targetMarks) {
          if (isHidden) tm.classList.add('bench-series-hidden');
          else tm.classList.remove('bench-series-hidden');
        }
      });
    }

    return function toggleAll(hiding) {
      for (const s of seriesList) {
        if (hiding) s.el.classList.add('bench-swatch-disabled');
        else s.el.classList.remove('bench-swatch-disabled');

        const targetMarks = svg.querySelectorAll(`[data-series-id="${s.id}"]`);
        for (const tm of targetMarks) {
          if (hiding) tm.classList.add('bench-series-hidden');
          else tm.classList.remove('bench-series-hidden');
        }
      }
    };
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

  // ── module: hero selection & badges ─────────────────────────────────

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

  const THROUGHPUT_BADGE_TEXT = 'Throughput: Higher is better ↑';
  const LATENCY_BADGE_TEXT    = 'Latency: Lower is better ↓';

  function buildDirectionBadge(kind) {
    const isLatency = kind === 'latency';
    return el('span', {
      class: 'bench-direction-badge ' +
        (isLatency ? 'bench-direction-lower' : 'bench-direction-higher'),
    }, isLatency ? LATENCY_BADGE_TEXT : THROUGHPUT_BADGE_TEXT);
  }

  // ── module: hero panel (Observable Plot horizontal bar) ─────────────

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
        library,
        label: displayLabel(library),
        value: mv.value,
        lower: mv.lower,
        upper: mv.upper,
        slug: mv.slug,
        isLfq: isLockfreequeues(library),
        blocking: isBlocking(library),
        color: getColor(library),
      });
    }
    if (rows.length === 0) {
      host.appendChild(el('p', { class: 'bench-hero-empty' },
        'No data matching the selected ecosystem at the chosen hero shape.'));
      return;
    }

    rows.sort((a, b) => b.value - a.value);

    let baselineVal = null;
    if (_activeDisplayMode === 'relative') {
      const baseRow = rows.find((r) => r.library === 'nim_channels' || r.library === 'nim_channel');
      if (baseRow && baseRow.value > 0) {
        baselineVal = baseRow.value;
      }
    }

    for (const r of rows) {
      r.displayVal = baselineVal ? (r.value / baselineVal) : r.value;
      r.valueText = baselineVal
        ? r.displayVal.toFixed(1) + 'x'
        : r.value.toFixed(0) + ' ops/ms';
      let tip = r.library + ' (' + topologyLabel(pick.topology) + ' ' + pick.shape + ')\n' +
        'Throughput: ' + r.value.toFixed(1) + ' ops/ms';
      if (baselineVal) tip += ' (' + (r.value / baselineVal).toFixed(1) + 'x vs stdlib)';
      if (r.lower != null && r.upper != null) {
        tip += ' (±' + ((r.upper - r.lower) / 2).toFixed(1) + ')';
      }
      if (r.blocking) tip += '\nBlocking on full channel';
      r.tipText = tip;
    }

    const hasAlt = rows.some((r) => !r.isLfq);
    const modeDesc = baselineVal ? ' — speedup vs stdlib' : '';
    const headingText = topologyLabel(pick.topology) + ' ' + pick.shape +
      (hasAlt ? ' — lockfree vs alternatives' : ' — lockfree throughput') + modeDesc;
    const headerRow = el('div', { class: 'bench-panel-header-row' },
      el('h3', { class: 'bench-hero-heading' }, headingText),
      buildDirectionBadge('throughput')
    );
    host.appendChild(headerRow);

    if (!hasPlot()) {
      renderHeroDomFallback(host, rows, pick);
      return;
    }

    const mount = el('div', { class: 'bench-chart-plot bench-chart-plot-hero' });
    host.appendChild(mount);

    const sawBlocking = rows.some((r) => r.blocking);
    if (sawBlocking) {
      host.appendChild(el('p', { class: 'bench-hero-footnote' },
        'Asterisk (*) marks libraries that block on full; throughput ' +
        'reflects blocking semantics, not the non-blocking tryPush path.'));
    }

    const draw = () => {
      mount.innerHTML = '';
      const maxLabelChars = Math.max(12, ...rows.map((r) => r.label.length));
      const marginLeft = Math.min(320, Math.max(140, maxLabelChars * 7.8 + 22));
      const fig = window.Plot.plot({
        width: getPlotWidth(mount),
        height: Math.max(220, rows.length * 34 + 68),
        marginLeft: marginLeft,
        marginRight: 96,
        marginTop: 14,
        marginBottom: 42,
        x: {
          grid: true,
          nice: true,
          label: (baselineVal ? 'Relative speedup (x vs stdlib Channel)' : 'Throughput (ops/ms)') +
            ' — ' + THROUGHPUT_BADGE_TEXT,
        },
        y: {
          domain: rows.map((r) => r.label),
          label: null,
        },
        marks: [
          window.Plot.barX(rows, {
            x: 'displayVal',
            y: 'label',
            fill: 'color',
            fillOpacity: (d) => d.blocking ? 0.65 : (d.isLfq ? 1.0 : 0.88),
            stroke: (d) => d.isLfq ? LOCKFREE_PRIMARY_COLOR : d.color,
            strokeWidth: (d) => d.isLfq ? 2.5 : (d.blocking ? 1.5 : 0.5),
            rx: 3,
            title: 'tipText',
            tip: true,
          }),
          window.Plot.text(rows, {
            x: 'displayVal',
            y: 'label',
            text: 'valueText',
            textAnchor: 'start',
            dx: 6,
            fontWeight: (d) => d.isLfq ? 'bold' : 'normal',
          }),
          window.Plot.ruleX([0]),
        ],
      });
      mount.appendChild(fig);
      emphasizeLockfreeSvgAndLegend(mount);
    };

    draw();
    _rebuildCallbacks.push(draw);
  }

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

  // ── module: throughput controls & Plot builders ─────────────────────

  function buildControls(panelId, initialLogScale, onLogToggle, onToggleAll) {
    const wrap = el('div', { class: 'bench-chart-controls' });
    wrap.appendChild(buildDirectionBadge('throughput'));
    const id = 'bench-log-scale-' + panelId;
    const cb = el('input', { type: 'checkbox', id });
    cb.checked = initialLogScale;
    cb.addEventListener('change', () => onLogToggle(cb.checked));
    const lbl = el('label', { for: id }, 'Log-scale axis');
    wrap.appendChild(el('span', { class: 'bench-control-item' }, cb, lbl));
    if (typeof onToggleAll === 'function') {
      const toggleBtn = el('button', { type: 'button', class: 'bench-toggle-all-btn' }, 'Hide All');
      toggleBtn.addEventListener('click', () => {
        const hiding = toggleBtn.textContent === 'Hide All';
        onToggleAll(hiding);
        toggleBtn.textContent = hiding ? 'Show All' : 'Hide All';
      });
      wrap.appendChild(toggleBtn);
    }
    return wrap;
  }

  // Ranked Horizontal Bar Chart builder (`Plot.barX`) for SPSC & single-point panels.
  function buildRankedBarThroughputOption(mount, series, xLabels, logScale, panelLabel, baselineByShape) {
    const shape = xLabels[0] || '1p1c';
    const isRel = _activeDisplayMode === 'relative' && baselineByShape && baselineByShape.size > 0;
    const baseVal = baselineByShape && baselineByShape.get(shape);

    const rankedRaw = series
      .map((lib) => {
        const pt = lib._shapeMap.get(shape) || lib.points[0] || null;
        const rawVal = pt ? pt.value : 0;
        const displayVal = (isRel && baseVal && baseVal > 0) ? (rawVal / baseVal) : rawVal;
        const isLfq = isLockfreequeues(lib.library);
        const blocking = isBlocking(lib.library);
        const label = displayLabel(lib.library);
        let tip = label + ' (' + (panelLabel || 'SPSC') + ' ' + shape + ')\n' +
          'Throughput: ' + rawVal.toFixed(1) + ' ops/ms';
        if (baseVal && baseVal > 0) {
          tip += ' (' + (rawVal / baseVal).toFixed(1) + 'x vs stdlib)';
        }
        if (pt && pt.lower != null && pt.upper != null) {
          tip += ' (±' + ((pt.upper - pt.lower) / 2).toFixed(1) + ')';
        }
        if (blocking) tip += '\nBlocking on full channel';
        return {
          library: lib.library,
          label: label,
          point: pt,
          rawVal,
          displayVal,
          isLfq,
          blocking,
          color: getColor(lib.library),
          valueText: isRel ? displayVal.toFixed(1) + 'x' : rawVal.toFixed(0) + ' ops/ms',
          tipText: tip,
        };
      })
      .filter((r) => r.displayVal > 0)
      .sort((a, b) => b.displayVal - a.displayVal);

    // Deduplicate by display label to ensure unique discrete Y ticks (prevent overlapping bars & text)
    const seenLabels = new Set();
    const ranked = [];
    for (const r of rankedRaw) {
      if (!seenLabels.has(r.label)) {
        seenLabels.add(r.label);
        ranked.push(r);
      }
    }

    const maxLabelChars = Math.max(12, ...ranked.map((r) => r.label.length));
    const marginLeft = Math.min(320, Math.max(140, maxLabelChars * 7.8 + 22));

    return window.Plot.plot({
      width: getPlotWidth(mount),
      height: Math.max(210, ranked.length * 36 + 68),
      marginLeft: marginLeft,
      marginRight: 96,
      marginTop: 14,
      marginBottom: 42,
      x: {
        type: logScale ? 'log' : 'linear',
        grid: true,
        nice: true,
        label: (isRel
          ? 'Relative speedup (x vs stdlib Channel)'
          : 'Throughput (ops/ms)') + (logScale ? ' [log]' : '') + ' — Higher is better ↑',
      },
      y: {
        domain: ranked.map((r) => r.label),
        label: null,
      },
      marks: [
        window.Plot.barX(ranked, {
          x1: logScale ? Math.min(1, ...ranked.map((r) => r.displayVal * 0.5)) : 0,
          x2: 'displayVal',
          y: 'label',
          fill: 'color',
          fillOpacity: (d) => d.blocking ? 0.65 : (d.isLfq ? 1.0 : 0.88),
          stroke: (d) => d.isLfq ? LOCKFREE_PRIMARY_COLOR : d.color,
          strokeWidth: (d) => d.isLfq ? 2.5 : (d.blocking ? 1.5 : 0.5),
          rx: 3,
          title: 'tipText',
          tip: true,
        }),
        window.Plot.text(ranked, {
          x: 'displayVal',
          y: 'label',
          text: 'valueText',
          textAnchor: 'start',
          dx: 6,
          fontWeight: (d) => d.isLfq ? 'bold' : 'normal',
        }),
      ],
    });
  }

  // Multi-shape Throughput Line + Dot builder (`Plot.line` + `Plot.dot`)
  function buildThroughputOption(mount, series, xLabels, logScale, panelLabel, baselineByShape, panelId) {
    if (panelId === 'bench-throughput-spsc' || xLabels.length === 1) {
      return buildRankedBarThroughputOption(mount, series, xLabels, logScale, panelLabel, baselineByShape);
    }

    const isRel = _activeDisplayMode === 'relative' && baselineByShape && baselineByShape.size > 0;
    const points = [];
    const colorDomain = [];
    const colorRange = [];

    for (const lib of series) {
      const label = displayLabel(lib.library);
      const isLfq = isLockfreequeues(lib.library);
      const blocking = isBlocking(lib.library);
      const color = getColor(lib.library);
      colorDomain.push(label);
      colorRange.push(color);

      for (const shape of xLabels) {
        const pt = lib._shapeMap.get(shape);
        if (!pt || typeof pt.value !== 'number' || pt.value <= 0) continue;
        const baseVal = baselineByShape && baselineByShape.get(shape);
        const displayVal = (isRel && baseVal && baseVal > 0) ? (pt.value / baseVal) : pt.value;
        if (displayVal == null || displayVal <= 0) continue;

        let tip = label + ' — ' + (panelLabel || '') + ' (' + shape + ')\n' +
          'Throughput: ' + pt.value.toFixed(1) + ' ops/ms';
        if (baseVal && baseVal > 0) {
          tip += ' (' + (pt.value / baseVal).toFixed(1) + 'x vs stdlib)';
        }
        if (pt.lower != null && pt.upper != null) {
          tip += ' (±' + ((pt.upper - pt.lower) / 2).toFixed(1) + ')';
        }
        if (blocking) tip += '\nBlocking on full channel';

        points.push({
          library: lib.library,
          label: label,
          shape: shape,
          value: displayVal,
          rawVal: pt.value,
          isLfq: isLfq,
          blocking: blocking,
          tipText: tip,
        });
      }
    }

    const otherPoints = points.filter((d) => !d.isLfq);
    const lfqPoints = points.filter((d) => d.isLfq);

    return window.Plot.plot({
      width: getPlotWidth(mount),
      height: 360,
      marginLeft: 72,
      marginRight: 28,
      marginTop: 22,
      marginBottom: 46,
      color: {
        legend: true,
        domain: colorDomain,
        range: colorRange,
      },
      x: {
        type: 'point',
        domain: xLabels,
        grid: true,
        label: 'Producer / consumer contention shape (P×C)',
      },
      y: {
        type: logScale ? 'log' : 'linear',
        grid: true,
        nice: true,
        label: (isRel
          ? 'Relative speedup (x vs stdlib Channel)'
          : 'Throughput (ops/ms)') + (logScale ? ' [log]' : '') + ' — Higher is better ↑',
      },
      marks: [
        window.Plot.line(otherPoints, {
          x: 'shape',
          y: 'value',
          z: 'label',
          stroke: 'label',
          strokeWidth: 2,
          strokeDasharray: (d) => d.blocking ? '5,4' : null,
        }),
        window.Plot.dot(otherPoints, {
          x: 'shape',
          y: 'value',
          fill: 'label',
          r: 3.5,
          title: 'tipText',
          tip: true,
        }),
        window.Plot.line(lfqPoints, {
          x: 'shape',
          y: 'value',
          z: 'label',
          stroke: 'label',
          strokeWidth: 3.5,
        }),
        window.Plot.dot(lfqPoints, {
          x: 'shape',
          y: 'value',
          fill: 'label',
          stroke: '#ffffff',
          strokeWidth: 1,
          r: 5,
          title: 'tipText',
          tip: true,
        }),
      ],
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
    if (!hasPlot()) {
      host.appendChild(el('p', { class: 'bench-chart-error' },
        'Chart unavailable: Observable Plot library failed to load.'));
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
    const isSinglePoint = panel.id === 'bench-throughput-spsc' || xLabels.length === 1;
    let logScale = !isSinglePoint;

    const mount = el('div', { class: 'bench-chart-plot' });
    let toggleAllFn = null;
    const draw = () => {
      mount.innerHTML = '';
      const fig = buildThroughputOption(mount, series, xLabels, logScale, panel.label, baselineByShape, panel.id);
      mount.appendChild(fig);
      emphasizeLockfreeSvgAndLegend(mount);
      toggleAllFn = wireInteractivePlot(mount);
    };

    const controls = buildControls(panel.id, logScale, (next) => {
      logScale = next;
      draw();
    }, isSinglePoint ? null : (hiding) => {
      if (toggleAllFn) toggleAllFn(hiding);
    });
    host.appendChild(controls);
    host.appendChild(mount);

    draw();
    _rebuildCallbacks.push(draw);
  }

  // ── module: latency panel (Observable Plot ladder & grouped bars) ───

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

  function buildLatencyControls(panelId, initialMode, initialLogScale, onChange, onToggleAll) {
    const wrap = el('div', { class: 'bench-chart-controls' });
    wrap.appendChild(buildDirectionBadge('latency'));

    let mode = initialMode || 'ladder';
    let logScale = initialLogScale !== false;

    const modeGroup = el('div', { class: 'bench-chip-group bench-latency-mode-group' });
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

    if (typeof onToggleAll === 'function') {
      const toggleBtn = el('button', { type: 'button', class: 'bench-toggle-all-btn' }, 'Hide All');
      toggleBtn.addEventListener('click', () => {
        const hiding = toggleBtn.textContent === 'Hide All';
        onToggleAll(hiding);
        toggleBtn.textContent = hiding ? 'Show All' : 'Hide All';
      });
      wrap.appendChild(toggleBtn);
    }
    return wrap;
  }

  function buildLatencyOption(mount, libraries, xLabels, chartMode, logScale) {
    const useBar = chartMode === 'bar';
    const useLog = logScale !== false;

    const points = [];
    const colorDomain = [];
    const colorRange = [];

    for (const lib of libraries) {
      const label = displayLabel(lib.library);
      const isLfq = isLockfreequeues(lib.library);
      const blocking = isBlocking(lib.library);
      colorDomain.push(label);
      colorRange.push(getColor(lib.library));

      for (let i = 0; i < xLabels.length; i++) {
        const val = lib.values[i];
        if (val == null || val <= 0) continue;
        const pctLabel = xLabels[i];
        points.push({
          library: lib.library,
          label: label,
          percentile: pctLabel,
          value: val,
          isLfq: isLfq,
          blocking: blocking,
          tipText: label + ' — ' + pctLabel + '\nLatency: ' + val.toFixed(0) + ' ns (' + LATENCY_BADGE_TEXT + ')',
        });
      }
    }

    if (useBar) {
      const minVal = Math.max(1, Math.min(...points.map((d) => d.value)) * 0.5);
      return window.Plot.plot({
        width: getPlotWidth(mount),
        height: 360,
        marginLeft: 74,
        marginRight: 28,
        marginTop: 28,
        marginBottom: 56,
        color: {
          legend: true,
          domain: colorDomain,
          range: colorRange,
        },
        fx: {
          domain: xLabels,
          label: 'Latency percentile (ns)',
          padding: 0.18,
        },
        x: {
          domain: colorDomain,
          axis: null,
        },
        y: {
          type: useLog ? 'log' : 'linear',
          grid: true,
          nice: true,
          label: 'Latency (ns)' + (useLog ? ' [log]' : '') + ' — Lower is better ↓',
        },
        marks: [
          window.Plot.barY(points, {
            fx: 'percentile',
            x: 'label',
            y1: useLog ? minVal : 0,
            y2: 'value',
            fill: 'label',
            stroke: (d) => d.isLfq ? LOCKFREE_PRIMARY_COLOR : null,
            strokeWidth: (d) => d.isLfq ? 2 : 0,
            rx: 2,
            title: 'tipText',
            tip: true,
          }),
        ],
      });
    }

    const otherPoints = points.filter((d) => !d.isLfq);
    const lfqPoints = points.filter((d) => d.isLfq);

    return window.Plot.plot({
      width: getPlotWidth(mount),
      height: 360,
      marginLeft: 74,
      marginRight: 28,
      marginTop: 22,
      marginBottom: 46,
      color: {
        legend: true,
        domain: colorDomain,
        range: colorRange,
      },
      x: {
        type: 'point',
        domain: xLabels,
        grid: true,
        label: 'Latency percentile (ns)',
      },
      y: {
        type: useLog ? 'log' : 'linear',
        grid: true,
        nice: true,
        label: 'Latency (ns)' + (useLog ? ' [log]' : '') + ' — Lower is better ↓',
      },
      marks: [
        window.Plot.line(otherPoints, {
          x: 'percentile',
          y: 'value',
          z: 'label',
          stroke: 'label',
          curve: 'step-after',
          strokeWidth: 2,
          strokeDasharray: (d) => d.blocking ? '5,4' : null,
        }),
        window.Plot.dot(otherPoints, {
          x: 'percentile',
          y: 'value',
          fill: 'label',
          r: 3.5,
          title: 'tipText',
          tip: true,
        }),
        window.Plot.line(lfqPoints, {
          x: 'percentile',
          y: 'value',
          z: 'label',
          stroke: 'label',
          curve: 'step-after',
          strokeWidth: 3.5,
        }),
        window.Plot.dot(lfqPoints, {
          x: 'percentile',
          y: 'value',
          fill: 'label',
          stroke: '#ffffff',
          strokeWidth: 1,
          r: 5,
          title: 'tipText',
          tip: true,
        }),
      ],
    });
  }

  function renderLatencyPanel(host, bmf, panelId, topologyFilter) {
    if (!host) return;
    host.innerHTML = '';
    const effectivePanelId = panelId || 'bench-latency';
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
    if (!hasPlot()) {
      host.appendChild(el('p', { class: 'bench-chart-error' },
        'Chart unavailable: Observable Plot library failed to load.'));
      return;
    }

    const xLabels = LATENCY_PERCENTILES.map((p) => p.label);
    let chartMode = 'ladder';
    let logScale = true;

    const mount = el('div', { class: 'bench-chart-plot' });
    let toggleAllFn = null;
    const draw = () => {
      mount.innerHTML = '';
      const fig = buildLatencyOption(mount, libraries, xLabels, chartMode, logScale);
      mount.appendChild(fig);
      emphasizeLockfreeSvgAndLegend(mount);
      toggleAllFn = wireInteractivePlot(mount);
    };

    const controls = buildLatencyControls(effectivePanelId, chartMode, logScale, (nextMode, nextLog) => {
      chartMode = nextMode;
      logScale = nextLog;
      draw();
    }, (hiding) => {
      if (toggleAllFn) toggleAllFn(hiding);
    });
    host.appendChild(controls);
    host.appendChild(mount);

    draw();
    _rebuildCallbacks.push(draw);

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
      'assets/bench-results/latest.json',
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
      'assets/bench-results/example.json',
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

  // ── module: interactive toolbar & system specs ─────────────────────

  function renderSystemSpecs() {
    const host = getActiveHost();
    const envs = getEnvironments();
    if (!host || (!host.cpu_model && !host.os && !envs)) return null;

    const wrapper = el('div', { class: 'bench-specs-container' });

    // Multi-environment tabs if multiple environments exist
    if (envs && Object.keys(envs).length > 1) {
      const envChips = Object.entries(envs).map(([envKey, envObj]) => {
        const isActive = _activeEnvironment === envKey;
        const btn = el('button', {
          class: 'bench-chip bench-env-chip' + (isActive ? ' active' : ''),
          type: 'button',
          'data-env': envKey,
        }, envObj.label || (envObj.host && envObj.host.cpu_model) || envKey);
        btn.addEventListener('click', () => {
          if (_activeEnvironment === envKey) return;
          _activeEnvironment = envKey;
          const tb = document.getElementById('bench-toolbar');
          if (tb) renderToolbar(tb);
          rerenderCharts();
        });
        return btn;
      });

      const envGroup = el('div', { class: 'bench-filter-group bench-env-group' },
        el('span', { class: 'bench-filter-label' }, 'Environment:'),
        el('div', { class: 'bench-chip-group' }, ...envChips)
      );
      wrapper.appendChild(envGroup);
    }

    const card = el('div', { class: 'bench-specs-card' });
    const items = [];

    if (host.environment) {
      items.push(el('div', { class: 'bench-spec-item' },
        el('span', { class: 'bench-spec-k' }, 'Profile'),
        el('span', { class: 'bench-spec-v bench-spec-badge' }, host.environment)
      ));
    }
    if (host.cpu_model) {
      items.push(el('div', { class: 'bench-spec-item' },
        el('span', { class: 'bench-spec-k' }, 'CPU Model'),
        el('span', { class: 'bench-spec-v' }, host.cpu_model)
      ));
    }
    if (host.cores) {
      const arch = host.arch ? ' (' + host.arch + ')' : '';
      items.push(el('div', { class: 'bench-spec-item' },
        el('span', { class: 'bench-spec-k' }, 'Cores'),
        el('span', { class: 'bench-spec-v' }, host.cores + ' threads' + arch)
      ));
    }
    if (host.memory_human) {
      items.push(el('div', { class: 'bench-spec-item' },
        el('span', { class: 'bench-spec-k' }, 'Memory'),
        el('span', { class: 'bench-spec-v' }, host.memory_human)
      ));
    }
    if (host.os) {
      items.push(el('div', { class: 'bench-spec-item' },
        el('span', { class: 'bench-spec-k' }, 'OS'),
        el('span', { class: 'bench-spec-v' }, host.os + (host.arch ? ' ' + host.arch : ''))
      ));
    }

    if (items.length > 0) {
      card.appendChild(el('div', { class: 'bench-specs-grid' }, ...items));
      wrapper.appendChild(card);
    }

    return wrapper;
  }

  function renderToolbar(host) {
    if (!host) return;
    host.innerHTML = '';

    const specsNode = renderSystemSpecs();
    if (specsNode) {
      host.appendChild(specsNode);
    }

    const controlsBar = el('div', { class: 'bench-controls-bar' });

    const ecoChips = ['all', 'nim', 'cpp', 'rust', 'c'].map((eco) => {
      const label = eco === 'all' ? 'All' :
                    eco === 'nim' ? 'Nim' :
                    eco === 'cpp' ? 'C++' :
                    eco === 'rust' ? 'Rust' : 'C';
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

    controlsBar.appendChild(ecoGroup);
    controlsBar.appendChild(modeGroup);
    controlsBar.appendChild(shapeGroup);
    host.appendChild(controlsBar);
  }

  function rerenderCharts() {
    if (!_currentBmfResult) return;
    const bmfData = getActiveBenchmarkData();
    if (!bmfData) return;
    _rebuildCallbacks.length = 0;
    const heroHost = document.getElementById('bench-hero');
    const byTopology = groupByTopology(bmfData);
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

      // Cross-topology inclusion: MPSC, SPMC, and MPMC queues can run in SPSC (1p1c)
      if (panel.id === 'bench-throughput-spsc') {
        const queueTopos = ['mpmc', 'mpmc_unbounded', 'mpsc', 'mpsc_unbounded', 'spmc'];
        for (const topo of queueTopos) {
          const libs = byTopology.get(topo);
          if (!libs) continue;
          for (const [library, shapeMap] of libs) {
            if (merged.has(library)) continue; // keep dedicated SPSC measurement if present
            if ((library === 'nim_channels' && merged.has('nim_channel')) ||
                (library === 'nim_channel' && merged.has('nim_channels'))) continue;
            const pt1p1c = shapeMap.get('1p1c');
            if (pt1p1c && typeof pt1p1c.value === 'number') {
              const dest = new Map();
              dest.set('1p1c', pt1p1c);
              merged.set(library, dest);
            }
          }
        }
      }

      // Cross-topology inclusion: MPMC queues can run in MPSC (*p1c)
      if (panel.id === 'bench-throughput-mpsc') {
        const mpmcTopos = ['mpmc', 'mpmc_unbounded'];
        for (const topo of mpmcTopos) {
          const libs = byTopology.get(topo);
          if (!libs) continue;
          for (const [library, shapeMap] of libs) {
            let dest = merged.get(library);
            if (!dest) {
              dest = new Map();
              merged.set(library, dest);
            }
            for (const [shape, mv] of shapeMap) {
              if (shape.endsWith('p1c') && !dest.has(shape)) {
                dest.set(shape, mv);
              }
            }
          }
        }
      }

      renderThroughputPanel(host, panel, merged);
    }

    renderLatencyPanel(
      document.getElementById('bench-latency'),
      bmfData,
      'bench-latency',
      (t) => t === 'spsc' || t === 'spmc' || t === 'mpsc' || t === 'mpmc'
    );
    renderLatencyPanel(
      document.getElementById('bench-rendezvous-latency'),
      bmfData,
      'bench-rendezvous-latency',
      (t) => t === 'rendezvous_rpc' || t === 'rendezvous_handoff'
    );
    renderLatencyPanel(
      document.getElementById('bench-smr-latency'),
      bmfData,
      'bench-smr-latency',
      (t) => t === 'smr_pin_unpin' || t === 'smr_retire_reclaim' || t === 'pin_unpin' || t === 'retire_reclaim'
    );
  }

  function rebuildAllPlots() {
    for (const fn of _rebuildCallbacks) {
      try { fn(); } catch (_) { /* noop */ }
    }
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

  let _resizeTimer = null;
  window.addEventListener('resize', () => {
    if (_resizeTimer) clearTimeout(_resizeTimer);
    _resizeTimer = setTimeout(rebuildAllPlots, 120);
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', render);
  } else {
    render();
  }
})();
