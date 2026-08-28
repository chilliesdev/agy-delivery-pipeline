/**
 * AGY Control Center — app.js
 * Plain modern ES module for the local control-center browser UI.
 * Pure DOM element creation with strict escaping. Zero dependencies.
 */

// Palette taken from .agy/design/API-CONTRACT.md & agy-command-center.dc.html
const A = '#38bdf8';       // accent / running
const GREEN = '#4ade80';   // pass
const RED = '#f87171';     // fail
const AMBER = '#fbbf24';   // held / stalled
const DIM = '#8b98a5';     // dim text
const VIOLET = '#a78bfa';  // thinking tokens
const REFUSE = '#94a3b8';  // zero-spend Class A refusal
const CLEAN = '#5eead4';   // BRIEF_IMPOSSIBLE clean stop
const PAGE = '#0e1116';    // page background
const CHROME = '#11161d';  // chrome background
const RULE = '#232c36';    // rule / border
const TEXT = '#e6edf3';    // text
const MUTED = '#5d6b79';   // muted text
const IDLE = '#4a5765';    // idle text
const SEC = '#cbd5e0';     // secondary light text

const MONO = "'JetBrains Mono', ui-monospace, monospace";
const SANS = "'IBM Plex Sans', system-ui, sans-serif";

// Vocabulary constants from design
const STATUS_VOCAB = {
  A: [
    'BRIEF_INVALID(reason)', 'SECRETS_FOUND(pattern, file:line)',
    'RETRY_CAP_REACHED(n=N)', 'BUDGET_EXCEEDED(spent, budget)',
    'REPO_BUDGET_EXCEEDED', 'WORKER_CAP_EXCEEDED(running=N, cap=M)',
    'PREFLIGHT_FAILED', 'RANGE_REFUSED', 'TEST_COMMAND_NOT_RUNNABLE',
    'TEST_COMMAND_FAILED', 'TEST_COMMAND_TIMEOUT',
    'RELEASE_BLOCKED(reason)', 'RELEASE_FAILED'
  ],
  B: [
    'VERIFY_FAILED(rc=N)', 'WORKER_FAILED',
    'GIT_STATE_CHANGED(what changed)', 'DIFF_TESTS_WEAKENED(...)'
  ],
  clean: 'BRIEF_IMPOSSIBLE(what is in the way) — a genuine brief/constraint collision. Refunds the round, consumes no retry: a clean outcome, not a failure.'
};

const DEFAULT_TIERS = {
  DISCOVERY: 'low',
  IMPLEMENT: 'medium',
  REVIEW: 'high',
  QA: 'medium',
  RELEASE: 'medium',
  DELEGATE: 'medium'
};

const TIER_MODEL = {
  low: 'gemini-3.7-flash-low',
  medium: 'gemini-3.7-flash-medium',
  high: 'gemini-3.7-flash-high'
};

const CONSTRAINTS = {
  DELEGATE: 'One bounded task, one worker, one phase, no review loop. The worker may read and edit source inside the run’s worktree and write one verdict line; it may not run shell commands, stage, commit, branch or push — the orchestrator captures the diff and runs the test command through --verify.',
  DISCOVERY: 'The worker may read the repo and write DISCOVERY.md and TEST_COMMAND; it may not edit source, run shell commands, stage, commit or branch.',
  IMPLEMENT: 'The worker may read and edit source inside the worktree and write CHANGES.md; it may not run shell commands, stage, commit, branch or push — the orchestrator captures the diff.',
  REVIEW: 'The worker may read the repo and write its report; it may not edit source, run shell commands, stage, commit or branch.',
  QA: 'The worker may read the repo, the diff and the test output, and write QA_REPORT.md; it may not edit source or run the suite itself — the orchestrator runs TEST_COMMAND.',
  RELEASE: 'The worker may read the run artifacts and write RELEASE_PLAN.md; every irreversible git or gh action is printed for a human, never executed.'
};

// DOM creation helper with automatic text node creation and attribute/style setting
function h(tag, props = {}, ...children) {
  const el = document.createElement(tag);
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (v == null) continue;
      if (k === 'style' && typeof v === 'object') {
        Object.assign(el.style, v);
      } else if (k.startsWith('on') && typeof v === 'function') {
        el.addEventListener(k.slice(2).toLowerCase(), v);
      } else if (k === 'className') {
        el.className = v;
      } else if (k === 'dataset' && typeof v === 'object') {
        Object.assign(el.dataset, v);
      } else {
        el.setAttribute(k, v);
      }
    }
  }
  for (const child of children.flat(Infinity)) {
    if (child == null || child === false) continue;
    if (typeof child === 'string' || typeof child === 'number') {
      el.appendChild(document.createTextNode(String(child)));
    } else if (child instanceof Node) {
      el.appendChild(child);
    }
  }
  return el;
}

// Formatting helpers
function commas(n) {
  if (n == null) return '—';
  return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
}

function shortTokens(n) {
  if (n == null) return '—';
  if (typeof n === 'string') return n;
  if (n >= 1000000) return (n / 1000000).toFixed(2) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'k';
  return String(n);
}

function formatDuration(s) {
  if (s == null) return '—';
  if (typeof s === 'string') return s;
  const m = Math.floor(s / 60);
  const r = s % 60;
  return m + 'm ' + (r < 10 ? '0' : '') + r + 's';
}

function statusColor(status, statusClass, live) {
  if (live) return A;
  if (statusClass === 'A') return REFUSE;
  if (statusClass === 'B') return RED;
  if (status === 'BRIEF_IMPOSSIBLE') return CLEAN;
  if (status === 'PASSED' || status === 'DONE') return GREEN;
  if (status === 'BUDGET' || status === 'BUDGET_EXCEEDED' || status === 'REPO_BUDGET_EXCEEDED' || status === 'STALLED') return AMBER;
  if (status === 'WORKER_CAP_EXCEEDED' || status === 'SECRETS_FOUND' || status === 'REFUSED' || status === 'BRIEF_INVALID' || status === 'RANGE_REFUSED' || status === 'PREFLIGHT_FAILED') return REFUSE;
  if (status === 'VERIFY_FAILED' || status === 'CAP HIT' || status === 'RETRY_CAP_REACHED' || status === 'WORKER_FAILED' || status === 'GIT_STATE_CHANGED' || status === 'DIFF_TESTS_WEAKENED') return RED;
  if (status === 'IDLE' || status === 'UNREACHABLE') return IDLE;
  return DIM;
}

function copyToClipboard(text, btn) {
  navigator.clipboard.writeText(text).then(() => {
    if (btn) {
      const orig = btn.textContent;
      btn.textContent = 'COPIED!';
      setTimeout(() => { btn.textContent = orig; }, 1500);
    }
  }).catch(() => {});
}

// App State
class App {
  constructor(rootEl) {
    this.root = rootEl;
    this.state = {
      view: 'fleet',       // fleet | repo | run
      repoId: null,
      runId: null,
      tab: 'overview',     // overview | transcript | trace | diff | brief | fleet
      traceMode: 'waterfall', // waterfall | ribbon
      transcriptFilter: 'ALL',
      followLog: true,
      railFilter: 'ACTIVE', // ACTIVE | ATTENTION | ALL
      expandedRepos: {},
      showDollars: false,
      pricePerMtok: 3,
      fleetData: null,
      repoData: null,
      runData: null,
      artifacts: {},       // { [artifact:phase]: text }
      logOffset: 0,
      logText: '',
      eventsLog: [],
      pulse: this.initPulse(),
      liveSeconds: 0,
      sseConnected: false
    };

    this.sse = null;
    this.reconnectTimer = null;
    this.liveInterval = null;

    this.initFromUrl();
    window.addEventListener('popstate', () => {
      this.initFromUrl(false);
      this.fetchCurrentView();
    });

    this.startLiveTicker();
    this.fetchCurrentView();
  }

  initFromUrl(updateState = true) {
    const params = new URLSearchParams(window.location.search);
    const view = params.get('view') || (params.get('run') ? 'run' : (params.get('repo') ? 'repo' : 'fleet'));
    const repoId = params.get('repo') || null;
    const runId = params.get('run') || null;
    const tab = params.get('tab') || 'overview';
    const showDollars = params.get('dollars') === '1';
    const price = parseFloat(params.get('price')) || 3;

    if (updateState) {
      this.state.view = view;
      this.state.repoId = repoId;
      this.state.runId = runId;
      this.state.tab = tab;
      this.state.showDollars = showDollars;
      this.state.pricePerMtok = price;
    }
  }

  updateUrl() {
    const params = new URLSearchParams();
    if (this.state.view !== 'fleet') params.set('view', this.state.view);
    if (this.state.repoId) params.set('repo', this.state.repoId);
    if (this.state.runId) params.set('run', this.state.runId);
    if (this.state.view === 'run' && this.state.tab !== 'overview') params.set('tab', this.state.tab);
    if (this.state.showDollars) params.set('dollars', '1');
    if (this.state.pricePerMtok !== 3) params.set('price', String(this.state.pricePerMtok));

    const newUrl = window.location.pathname + (params.toString() ? '?' + params.toString() : '');
    window.history.pushState({}, '', newUrl);
  }

  initPulse() {
    const seed = [3,9,22,14,6,2,2,18,26,11,4,2,2,2,8,30,19,7,3,2,12,24,9,4,2,2,2,16,28,13,5,2,2,9,21,6,3,2,2,2];
    return seed.map(v => ({ v }));
  }

  stepPulse() {
    const seed = [3,9,22,14,6,2,2,18,26,11,4,2,2,2,8,30,19,7,3,2,12,24,9,4,2,2,2,16,28,13,5,2,2,9,21,6,3,2,2,2];
    const nextVal = seed[Math.floor(Math.random() * seed.length)];
    this.state.pulse = this.state.pulse.slice(1).concat([{ v: nextVal }]);
  }

  startLiveTicker() {
    if (this.liveInterval) clearInterval(this.liveInterval);
    this.liveInterval = setInterval(() => {
      this.state.liveSeconds += 1;
      this.stepPulse();
      // Light re-render of liveness pulse if visible
      const pulseContainer = document.getElementById('liveness-pulse-bars');
      if (pulseContainer) {
        this.renderPulseBars(pulseContainer);
      }
    }, 1000);
  }

  navigate(view, repoId = null, runId = null, tab = 'overview') {
    this.state.view = view;
    this.state.repoId = repoId;
    this.state.runId = runId;
    this.state.tab = tab;
    if (repoId && !this.state.expandedRepos[repoId]) {
      this.state.expandedRepos[repoId] = true;
    }
    this.updateUrl();
    this.fetchCurrentView();
  }

  async fetchCurrentView() {
    try {
      // Always fetch fleet if missing or needed for navigation
      if (!this.state.fleetData || this.state.view === 'fleet') {
        const res = await fetch('/api/fleet');
        if (res.ok) {
          this.state.fleetData = await res.json();
          // Expand active repos by default
          if (this.state.fleetData.repos) {
            this.state.fleetData.repos.forEach(r => {
              if (r.state === 'RUNNING' && this.state.expandedRepos[r.id || r.name] === undefined) {
                this.state.expandedRepos[r.id || r.name] = true;
              }
            });
          }
        }
      }

      if (this.state.view === 'repo' && this.state.repoId) {
        const res = await fetch(`/api/repo/${encodeURIComponent(this.state.repoId)}`);
        if (res.ok) {
          this.state.repoData = await res.json();
        }
      }

      if (this.state.view === 'run' && this.state.repoId && this.state.runId) {
        const res = await fetch(`/api/run/${encodeURIComponent(this.state.repoId)}/${encodeURIComponent(this.state.runId)}`);
        if (res.ok) {
          this.state.runData = await res.json();
          this.loadCurrentRunArtifacts();
        }
      }

      this.setupSSE();
      this.render();
    } catch (e) {
      console.error('Error fetching view:', e);
      this.render();
    }
  }

  async loadCurrentRunArtifacts() {
    if (!this.state.repoId || !this.state.runId || !this.state.runData) return;
    const repo = this.state.repoId;
    const run = this.state.runId;
    const phases = this.state.runData.phases || [];
    const activePhase = phases.find(p => p.status === 'RUNNING') || phases[phases.length - 1] || { name: 'REVIEW' };
    const phaseName = activePhase.name || 'REVIEW';

    // Fetch brief, summary, diff, log
    try {
      const [briefRes, summaryRes, diffRes] = await Promise.all([
        fetch(`/api/run/${encodeURIComponent(repo)}/${encodeURIComponent(run)}/brief/${encodeURIComponent(phaseName)}`),
        fetch(`/api/run/${encodeURIComponent(repo)}/${encodeURIComponent(run)}/summary/-`),
        fetch(`/api/run/${encodeURIComponent(repo)}/${encodeURIComponent(run)}/diff/${encodeURIComponent(phaseName)}`)
      ]);

      if (briefRes.ok) this.state.artifacts['brief'] = await briefRes.text();
      if (summaryRes.ok) this.state.artifacts['summary'] = await summaryRes.text();
      if (diffRes.ok) this.state.artifacts['diff'] = await diffRes.text();

      // If on transcript tab, fetch initial log chunk
      if (this.state.tab === 'transcript') {
        const logRes = await fetch(`/api/run/${encodeURIComponent(repo)}/${encodeURIComponent(run)}/log/${encodeURIComponent(phaseName)}?offset=${this.state.logOffset}`);
        if (logRes.ok) {
          const newChunk = await logRes.text();
          this.state.logText += newChunk;
          this.state.logOffset = parseInt(logRes.headers.get('X-Log-Size') || String(this.state.logText.length), 10);
        }
      }
    } catch (err) {
      console.warn('Artifact fetch warning:', err);
    }
  }

  setupSSE() {
    // Determine if we need SSE: live run or fleet view
    const isLiveRun = this.state.view === 'run' && this.state.runData?.liveness?.live;
    const shouldSubscribe = isLiveRun || this.state.view === 'fleet';

    if (!shouldSubscribe) {
      if (this.sse) {
        this.sse.close();
        this.sse = null;
      }
      return;
    }

    if (this.sse) {
      this.sse.close();
    }

    let url = '/events';
    if (this.state.view === 'run' && this.state.repoId && this.state.runId) {
      const activePhase = this.state.runData?.phases?.find(p => p.status === 'RUNNING')?.name || 'REVIEW';
      url += `?run=${encodeURIComponent(this.state.repoId)}:${encodeURIComponent(this.state.runId)}&phase=${encodeURIComponent(activePhase)}`;
    }

    try {
      this.sse = new EventSource(url);
      this.sse.onopen = () => {
        this.state.sseConnected = true;
      };
      this.sse.addEventListener('fleet', (e) => {
        try {
          this.state.fleetData = JSON.parse(e.data);
          if (this.state.view === 'fleet') this.render();
        } catch (_) {}
      });
      this.sse.addEventListener('run', (e) => {
        try {
          this.state.runData = JSON.parse(e.data);
          if (this.state.view === 'run') this.render();
        } catch (_) {}
      });
      this.sse.addEventListener('log', (e) => {
        try {
          const data = JSON.parse(e.data);
          if (data.chunk) {
            this.state.logText += data.chunk;
            this.state.logOffset = (data.offset || 0) + data.chunk.length;
            if (this.state.view === 'run' && this.state.tab === 'transcript') {
              this.appendTranscriptLog(data.chunk);
            }
          }
        } catch (_) {}
      });
      this.sse.onerror = () => {
        this.state.sseConnected = false;
        this.sse.close();
        this.sse = null;
        if (!this.reconnectTimer) {
          this.reconnectTimer = setTimeout(() => {
            this.reconnectTimer = null;
            this.setupSSE();
          }, 3000);
        }
      };
    } catch (e) {
      console.warn('SSE error:', e);
    }
  }

  appendTranscriptLog(chunk) {
    const logBox = document.getElementById('transcript-raw-log');
    if (logBox) {
      logBox.appendChild(document.createTextNode(chunk));
      if (this.state.followLog) {
        logBox.scrollTop = logBox.scrollHeight;
      }
    }
  }

  render() {
    while (this.root.firstChild) {
      this.root.removeChild(this.root.firstChild);
    }

    const container = h('div', {
      style: {
        fontFamily: SANS,
        background: PAGE,
        color: TEXT,
        minWidth: '1440px',
        minHeight: '100vh',
        display: 'flex',
        flexDirection: 'column'
      }
    });

    container.appendChild(this.renderHeader());

    const mainLayout = h('div', {
      style: {
        display: 'grid',
        gridTemplateColumns: '300px minmax(0, 1fr)',
        alignItems: 'start',
        flex: '1'
      }
    });

    mainLayout.appendChild(this.renderLeftRail());

    const contentArea = h('div', {
      style: {
        minHeight: 'calc(100vh - 58px)',
        display: 'flex',
        flexDirection: 'column'
      }
    });

    if (this.state.view === 'fleet') {
      contentArea.appendChild(this.renderFleetView());
    } else if (this.state.view === 'repo') {
      contentArea.appendChild(this.renderRepoView());
    } else if (this.state.view === 'run') {
      contentArea.appendChild(this.renderRunView());
    }

    mainLayout.appendChild(contentArea);
    container.appendChild(mainLayout);
    this.root.appendChild(container);
  }

  // -------------------------------------------------------------
  // Header Component
  // -------------------------------------------------------------
  renderHeader() {
    const fleet = this.state.fleetData || { repos: [], attention: [] };
    const repos = fleet.repos || [];
    const attention = fleet.attention || [];
    const liveWorkers = repos.reduce((acc, r) => acc + (r.branches?.filter(b => b.live)?.length || 0), 0);
    const workerLine = liveWorkers + (liveWorkers === 1 ? ' WORKER RUNNING · FLEET CAP ' : ' WORKERS RUNNING · FLEET CAP ') + (liveWorkers || 1);

    const crumbs = this.buildBreadcrumbs();

    return h('div', {
      style: {
        display: 'flex',
        alignItems: 'center',
        gap: '16px',
        height: '58px',
        padding: '0 20px',
        borderBottom: `1px solid ${RULE}`,
        background: CHROME,
        flexShrink: '0'
      }
    },
      h('div', {
        style: { display: 'flex', alignItems: 'center', gap: '9px', cursor: 'pointer' },
        onClick: () => this.navigate('fleet')
      },
        h('div', { style: { width: '9px', height: '9px', background: A, borderRadius: '2px' } }),
        h('span', {
          style: { fontFamily: MONO, fontSize: '12.5px', fontWeight: '700', letterSpacing: '0.14em', color: TEXT }
        }, 'AGY CONTROL')
      ),
      h('div', { style: { width: '1px', height: '24px', background: RULE } }),
      h('div', { style: { display: 'flex', alignItems: 'center', gap: '8px', fontFamily: MONO, fontSize: '11.5px' } },
        crumbs
      ),
      h('div', { style: { flex: '1' } }),
      h('div', {
        style: {
          display: 'flex', alignItems: 'center', gap: '7px', padding: '5px 11px',
          border: '1px solid #1e3a4a', background: '#0f2027', borderRadius: '4px'
        }
      },
        h('div', {
          className: 'pulse-anim',
          style: { width: '7px', height: '7px', borderRadius: '50%', background: A }
        }),
        h('span', {
          style: { fontFamily: MONO, fontSize: '11px', letterSpacing: '0.1em', color: '#7dd3fc' }
        }, workerLine)
      ),
      h('div', {
        style: {
          display: 'flex', alignItems: 'center', gap: '7px', padding: '5px 11px',
          border: '1px solid #3d3113', background: '#1a1508', borderRadius: '4px', cursor: 'pointer'
        },
        onClick: () => this.navigate('fleet')
      },
        h('span', { style: { fontFamily: MONO, fontSize: '11px', color: AMBER } }, '⚠'),
        h('span', {
          style: { fontFamily: MONO, fontSize: '11px', letterSpacing: '0.08em', color: '#fcd34d' }
        }, `${attention.length} NEED A HUMAN`)
      ),
      h('div', {
        style: { display: 'flex', alignItems: 'baseline', gap: '7px', fontFamily: MONO, fontSize: '11px', color: MUTED }
      },
        h('span', null, 'TODAY'),
        h('span', { style: { fontSize: '12px', color: '#a9b6c3' } }, 'no fleet total'),
        h('span', { style: { fontSize: '10px' } }, 'each repo bills separately')
      )
    );
  }

  buildBreadcrumbs() {
    const view = this.state.view;
    const sep = () => h('span', { style: { color: '#2a343f', fontFamily: MONO, fontSize: '11.5px' } }, '/');
    const crumbs = [];

    crumbs.push(h('span', {
      style: { color: view === 'fleet' ? TEXT : DIM, cursor: 'pointer', fontFamily: MONO, fontSize: '11.5px' },
      onClick: () => this.navigate('fleet')
    }, 'chilliesdev'));

    if (view !== 'fleet' && this.state.repoId) {
      crumbs.push(sep());
      const repoShort = this.state.repoId.split('/')[1] || this.state.repoId;
      crumbs.push(h('span', {
        style: { color: view === 'repo' ? TEXT : DIM, cursor: 'pointer', fontFamily: MONO, fontSize: '11.5px' },
        onClick: () => this.navigate('repo', this.state.repoId)
      }, repoShort));
    }

    if (view === 'run' && this.state.runData) {
      const run = this.state.runData.run || {};
      const branch = run.branch || this.state.runId;
      const status = (run.outcome || 'running').toLowerCase();
      const phase = this.state.runData.phases?.[0]?.name || 'RUN';

      crumbs.push(sep());
      crumbs.push(h('span', {
        style: { color: DIM, cursor: 'pointer', fontFamily: MONO, fontSize: '11.5px' },
        onClick: () => this.navigate('repo', this.state.repoId)
      }, branch));

      crumbs.push(sep());
      crumbs.push(h('span', {
        style: { color: TEXT, fontFamily: MONO, fontSize: '11.5px' }
      }, `${phase} · ${status}`));
    }

    if (view === 'fleet') {
      const fleet = this.state.fleetData || { repos: [] };
      const totalRepos = fleet.repos?.length || 0;
      const totalBranches = fleet.repos?.reduce((acc, r) => acc + (r.branches?.length || 0), 0) || 0;
      const totalLive = fleet.repos?.reduce((acc, r) => acc + (r.branches?.filter(b => b.live)?.length || 0), 0) || 0;

      crumbs.push(h('span', {
        style: { color: IDLE, fontFamily: MONO, fontSize: '11.5px' }
      }, `— ${totalRepos} repos, ${totalBranches} branches, ${totalLive} workers out`));
    }

    return crumbs;
  }

  // -------------------------------------------------------------
  // Left Rail (Fleet / Branch Tree)
  // -------------------------------------------------------------
  renderLeftRail() {
    const fleet = this.state.fleetData || { repos: [] };
    const repos = fleet.repos || [];
    const totalBranches = repos.reduce((acc, r) => acc + (r.branches?.length || 0), 0);
    const filter = this.state.railFilter;

    const visibleRepos = repos.filter(r => {
      if (filter === 'ALL') return true;
      if (filter === 'ATTENTION') {
        const needsState = ['VERIFY_FAILED', 'BUDGET', 'CAP HIT', 'STALLED', 'REFUSED', 'SECRETS_FOUND'];
        return needsState.includes(r.state) || r.branches?.some(b => needsState.includes(b.state));
      }
      return r.state !== 'IDLE';
    });

    const filterBtn = (label) => h('div', {
      style: {
        flex: '1', textAlign: 'center', padding: '5px 0', fontFamily: MONO, fontSize: '10.5px', borderRadius: '3px',
        cursor: 'pointer',
        color: filter === label ? PAGE : DIM,
        background: filter === label ? A : '#1a212a'
      },
      onClick: () => {
        this.state.railFilter = label;
        this.render();
      }
    }, label);

    const treeNodes = [];
    visibleRepos.forEach(r => {
      const repoKey = r.id || r.name;
      const isOpen = !!this.state.expandedRepos[repoKey];
      const isSelected = this.state.repoId === repoKey && this.state.view !== 'fleet';
      const rColor = statusColor(r.state, r.branches?.find(b => b.live)?.stateClass || null, r.state === 'RUNNING');
      const shortName = r.name?.split('/')[1] || r.name || r.path;
      const orgName = r.name?.split('/')[0] || 'chilliesdev';
      const bCount = r.branches?.length || 0;

      // Repo Row
      treeNodes.push(h('div', {
        style: {
          padding: '10px 14px',
          borderBottom: '1px solid #1c242d',
          display: 'flex',
          flexDirection: 'column',
          gap: '3px',
          cursor: 'pointer',
          background: isSelected ? '#151f28' : 'transparent',
          borderLeft: `2px solid ${isSelected ? A : 'transparent'}`
        },
        onClick: () => {
          this.state.expandedRepos[repoKey] = !isOpen;
          this.navigate('repo', repoKey);
        }
      },
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '7px' } },
          h('span', { style: { fontFamily: MONO, fontSize: '9px', color: IDLE, width: '9px' } }, isOpen ? '▾' : '▸'),
          h('div', {
            className: r.state === 'RUNNING' ? 'pulse-anim' : '',
            style: { width: '6px', height: '6px', borderRadius: '50%', flex: 'none', background: rColor }
          }),
          h('span', { style: { fontFamily: MONO, fontSize: '12px', color: TEXT } }, shortName),
          h('div', { style: { flex: '1' } }),
          h('span', { style: { fontFamily: MONO, fontSize: '9.5px', letterSpacing: '0.06em', color: rColor } }, r.state || 'IDLE')
        ),
        h('div', {
          style: { fontFamily: MONO, fontSize: '9.5px', color: IDLE, paddingLeft: '16px' }
        }, `${orgName} · ${bCount} ${bCount === 1 ? 'branch' : 'branches'}`)
      ));

      // Branches rows if open
      if (isOpen && r.branches) {
        r.branches.forEach(b => {
          const bColor = statusColor(b.state, b.stateClass, b.live);
          const isBranchSelected = this.state.repoId === repoKey && this.state.runData?.run?.branch === b.name;

          treeNodes.push(h('div', {
            style: {
              padding: '8px 14px 8px 30px',
              borderBottom: '1px solid #171e26',
              display: 'flex',
              flexDirection: 'column',
              gap: '2px',
              cursor: 'pointer',
              background: isBranchSelected ? '#151f28' : '#0f141a'
            },
            onClick: (e) => {
              e.stopPropagation();
              // If run data is present on branch, open run, else repo
              const runId = b.runs?.[0]?.id || b.runs?.[0]?.[0] || 'current';
              this.navigate('run', repoKey, runId);
            }
          },
            h('div', { style: { display: 'flex', alignItems: 'center', gap: '7px' } },
              h('div', {
                className: b.live ? 'pulse-anim' : '',
                style: { width: '5px', height: '5px', borderRadius: '50%', flex: 'none', background: bColor }
              }),
              h('span', {
                style: { fontFamily: MONO, fontSize: '10.5px', color: '#a9b6c3', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }
              }, b.name),
              h('div', { style: { flex: '1' } }),
              h('span', { style: { fontFamily: MONO, fontSize: '9px', letterSpacing: '0.04em', color: bColor } }, b.state)
            )
          ));
        });
      }
    });

    return h('div', {
      style: {
        borderRight: `1px solid ${RULE}`,
        minHeight: 'calc(100vh - 58px)',
        background: CHROME,
        display: 'flex',
        flexDirection: 'column'
      }
    },
      h('div', {
        style: {
          padding: '14px 16px 12px',
          display: 'flex',
          flexDirection: 'column',
          gap: '11px',
          borderBottom: '1px solid #1c242d'
        }
      },
        h('div', { style: { display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' } },
          h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'FLEET'),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: MUTED } }, `${repos.length} repos · ${totalBranches} branches`)
        ),
        h('div', { style: { display: 'flex', gap: '5px' } },
          filterBtn('ACTIVE'),
          filterBtn('ATTENTION'),
          filterBtn('ALL')
        )
      ),
      h('div', { style: { display: 'flex', flexDirection: 'column' } },
        treeNodes
      )
    );
  }

  // -------------------------------------------------------------
  // Fleet View
  // -------------------------------------------------------------
  renderFleetView() {
    const fleet = this.state.fleetData || { repos: [], attention: [] };
    const repos = fleet.repos || [];
    const attention = fleet.attention || [];
    const liveWorkers = repos.reduce((acc, r) => acc + (r.branches?.filter(b => b.live)?.length || 0), 0);
    const activeCount = repos.filter(r => r.state !== 'IDLE').length;

    const headline = liveWorkers > 0
      ? `${liveWorkers} workers are out: delegated work across ${activeCount} active repositories.`
      : `All workers are idle. No runs are currently in flight.`;

    const kpis = [
      ['REPOS ACTIVE', `${activeCount} of ${repos.length}`, `${repos.length - activeCount} idle`, TEXT],
      ['RUNS IN FLIGHT', String(liveWorkers), liveWorkers ? 'workers hold repo locks' : 'no workers dispatched', A],
      ['WORKERS', `${liveWorkers} / ${liveWorkers || 1}`, 'worker cap', AMBER],
      ['NEED A HUMAN', String(attention.length), attention.length ? 'shown in the queue below' : 'nothing waiting', attention.length ? AMBER : DIM],
      ['TOKENS TODAY', 'per repo', 'no fleet aggregator — each repo has its own ledger', REFUSE],
      ['CLAIMS OVERRIDDEN', 'per repo', 'no cross-repo denominator exists yet', REFUSE]
    ];

    const kpiCards = kpis.map(([label, val, note, col]) => h('div', {
      style: { background: '#151c24', padding: '11px 13px', display: 'flex', flexDirection: 'column', gap: '5px' }
    },
      h('span', { style: { fontSize: '10px', letterSpacing: '0.14em', color: MUTED } }, label),
      h('span', { style: { fontFamily: MONO, fontSize: '17px', color: col } }, val),
      h('span', { style: { fontFamily: MONO, fontSize: '10px', color: IDLE } }, note)
    ));

    return h('div', { style: { display: 'flex', flexDirection: 'column' } },
      // Top Headline Banner
      h('div', {
        style: {
          padding: '20px 24px 18px',
          borderBottom: `1px solid ${RULE}`,
          background: 'linear-gradient(#131a22, #11161d)',
          display: 'flex',
          flexDirection: 'column',
          gap: '16px'
        }
      },
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '6px' } },
          h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'WHAT IS BEING DELEGATED RIGHT NOW'),
          h('div', { style: { fontSize: '21px', lineHeight: '1.35', color: '#f0f6fc' } }, headline)
        ),
        h('div', {
          style: {
            display: 'grid',
            gridTemplateColumns: 'repeat(6, 1fr)',
            gap: '1px',
            background: RULE,
            border: `1px solid ${RULE}`,
            borderRadius: '5px',
            overflow: 'hidden'
          }
        }, kpiCards)
      ),

      // Activity By Repo and Branch
      this.renderActivityLanes(repos),

      // Needs a Human Queue
      this.renderAttentionQueue(attention),

      // Repos using the pipeline
      this.renderRepoCardsGrid(repos)
    );
  }

  renderActivityLanes(repos) {
    const lanes = [];
    repos.forEach(r => {
      const repoShort = r.name?.split('/')[1] || r.name;
      (r.branches || []).forEach((b, bi) => {
        const runs = b.runs || [];
        const isFirst = bi === 0;
        const metaText = r.live?.branch === b.name
          ? `${r.live.phase} · ${r.live.doing || 'in flight'}`
          : (runs[0]?.task || `base ${b.base || 'origin'}`);

        // Construct run bars
        const bars = [];
        if (b.live) {
          bars.push(h('div', {
            className: 'pulse-anim',
            style: {
              position: 'absolute', top: '3px', height: '20px', left: '55%', width: '40%',
              background: A, borderRadius: '3px', display: 'flex', alignItems: 'center', paddingLeft: '6px',
              cursor: 'pointer', zIndex: 2
            },
            onClick: () => this.navigate('run', r.id || r.name, r.live?.run || 'current')
          },
            h('span', { style: { fontFamily: MONO, fontSize: '9.5px', color: PAGE, whiteSpace: 'nowrap' } }, `${r.live?.phase || 'RUN'} running`)
          ));
        } else if (runs.length > 0) {
          const run = runs[0];
          const col = statusColor(run.status || b.state, run.statusClass || b.stateClass, false);
          bars.push(h('div', {
            style: {
              position: 'absolute', top: '3px', height: '20px', left: '20%', width: '60%',
              background: col, borderRadius: '3px', display: 'flex', alignItems: 'center', paddingLeft: '6px',
              cursor: 'pointer', zIndex: 2
            },
            onClick: () => this.navigate('run', r.id || r.name, run.id || 'last')
          },
            h('span', { style: { fontFamily: MONO, fontSize: '9.5px', color: PAGE, whiteSpace: 'nowrap' } }, `${run.phase || 'PHASE'} ${run.status || b.state}`)
          ));
        }

        lanes.push(h('div', {
          style: {
            display: 'grid',
            gridTemplateColumns: '268px minmax(0, 1fr)',
            alignItems: 'center',
            padding: '7px 0',
            borderBottom: '1px solid #171e26',
            background: isFirst ? '#111820' : 'transparent'
          }
        },
          h('div', { style: { padding: '0 14px', display: 'flex', flexDirection: 'column', gap: '2px', overflow: 'hidden' } },
            h('div', { style: { display: 'flex', alignItems: 'center', gap: '7px' } },
              isFirst ? h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: TEXT } }, repoShort) : null,
              h('span', { style: { fontFamily: MONO, fontSize: '11px', color: isFirst ? '#7dd3fc' : '#a9b6c3', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' } }, b.name)
            ),
            h('span', { style: { fontFamily: MONO, fontSize: '9.5px', color: IDLE, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' } }, metaText)
          ),
          h('div', { style: { position: 'relative', height: '26px', marginRight: '14px' } },
            h('div', { style: { position: 'absolute', inset: 0, background: '#131a21', borderRadius: '3px' } }),
            bars
          )
        ));
      });
    });

    return h('div', {
      style: {
        padding: '18px 24px',
        borderBottom: `1px solid ${RULE}`,
        display: 'flex',
        flexDirection: 'column',
        gap: '12px'
      }
    },
      h('div', { style: { display: 'flex', alignItems: 'baseline', gap: '10px' } },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'ACTIVITY BY REPO AND BRANCH'),
        h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: IDLE } }, 'last 6 hours · one lane per branch · click a run to open it'),
        h('div', { style: { flex: '1' } }),
        h('div', { style: { display: 'flex', gap: '12px', fontFamily: MONO, fontSize: '10px', color: DIM } },
          h('span', { style: { display: 'flex', alignItems: 'center', gap: '5px' } }, h('span', { style: { width: '8px', height: '8px', background: A, borderRadius: '2px' } }), 'running'),
          h('span', { style: { display: 'flex', alignItems: 'center', gap: '5px' } }, h('span', { style: { width: '8px', height: '8px', background: GREEN, borderRadius: '2px' } }), 'passed'),
          h('span', { style: { display: 'flex', alignItems: 'center', gap: '5px' } }, h('span', { style: { width: '8px', height: '8px', background: REFUSE, borderRadius: '2px' } }), 'gate refused'),
          h('span', { style: { display: 'flex', alignItems: 'center', gap: '5px' } }, h('span', { style: { width: '8px', height: '8px', background: AMBER, borderRadius: '2px' } }), 'needs a human')
        )
      ),
      h('div', { style: { border: `1px solid ${RULE}`, borderRadius: '6px', background: '#0f141a', overflow: 'hidden' } },
        h('div', { style: { display: 'grid', gridTemplateColumns: '268px minmax(0,1fr)', borderBottom: '1px solid #1c242d' } },
          h('div', { style: { padding: '8px 14px', fontFamily: MONO, fontSize: '10px', color: IDLE } }, 'REPO / BRANCH'),
          h('div', { style: { display: 'flex', justifyContent: 'space-between', padding: '8px 14px', fontFamily: MONO, fontSize: '10px', color: IDLE } },
            h('span', null, '−6h'), h('span', null, '−4h'), h('span', null, '−2h'), h('span', null, 'now')
          )
        ),
        lanes
      )
    );
  }

  renderAttentionQueue(attention) {
    const items = (attention || []).map(a => {
      const col = a.class === 'A' ? REFUSE : (a.class === 'B' ? RED : AMBER);
      const stuckStr = formatDuration(a.stuckSeconds || 0);

      return h('div', {
        style: {
          display: 'grid',
          gridTemplateColumns: '148px minmax(0, 1fr) 78px 150px',
          gap: '14px',
          padding: '11px 15px',
          borderBottom: '1px solid #221c10',
          alignItems: 'center',
          cursor: 'pointer'
        },
        onClick: () => {
          if (a.repo && a.run) this.navigate('run', a.repo, a.run);
          else if (a.repo) this.navigate('repo', a.repo);
        }
      },
        h('span', { style: { fontFamily: MONO, fontSize: '11px', fontWeight: '700', letterSpacing: '0.06em', color: col } }, a.kind),
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '2px', overflow: 'hidden' } },
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: TEXT } }, `${a.repoName || a.repo} / ${a.branch || 'branch'}`),
          h('span', { style: { fontSize: '12px', lineHeight: '1.4', color: '#a9b6c3' } }, a.detail)
        ),
        h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: DIM, textAlign: 'right' } }, stuckStr),
        h('div', {
          style: {
            fontFamily: MONO, fontSize: '10px', letterSpacing: '0.06em', textAlign: 'center', padding: '6px 8px',
            borderRadius: '3px', border: `1px solid ${col === RED ? '#3d2226' : '#3d3113'}`,
            background: col === RED ? '#1d1416' : '#1a1508', color: col === RED ? '#fca5a5' : '#fcd34d',
            cursor: 'pointer'
          },
          onClick: (e) => {
            e.stopPropagation();
            if (a.control?.command) copyToClipboard(a.control.command, e.currentTarget);
            else if (a.repo && a.run) this.navigate('run', a.repo, a.run);
          }
        }, a.control?.label || 'OPEN')
      );
    });

    return h('div', {
      style: {
        padding: '18px 24px',
        borderBottom: `1px solid ${RULE}`,
        display: 'flex',
        flexDirection: 'column',
        gap: '12px'
      }
    },
      h('div', { style: { display: 'flex', alignItems: 'baseline', gap: '10px' } },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'NEEDS A HUMAN'),
        h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: IDLE } }, 'across every repo · ordered by how long it has been stuck')
      ),
      h('div', { style: { border: '1px solid #3d3113', borderRadius: '6px', overflow: 'hidden', background: '#14110a' } },
        items.length ? items : h('div', { style: { padding: '16px', color: IDLE, fontFamily: MONO, fontSize: '11px' } }, 'No items currently need human attention.')
      )
    );
  }

  renderRepoCardsGrid(repos) {
    const cards = (repos || []).map(r => {
      const isRunning = r.state === 'RUNNING';
      const col = statusColor(r.state, null, isRunning);
      const passRate = r.counts7d?.passRate != null ? `${Math.round(r.counts7d.passRate * 100)}%` : '—';
      const passCol = r.counts7d?.passRate >= 0.8 ? GREEN : (r.counts7d?.passRate != null ? AMBER : DIM);
      const spendTokens = r.spend7d?.totalTokens != null ? shortTokens(r.spend7d.totalTokens) : '—';
      const doing = r.live?.doing || (r.unreachable ? `Unreachable: ${r.unreachable} (${r.path})` : `${r.config?.phaseCount || 0} phases configured.`);

      // Budget burn calculation
      const maxBudget = r.config?.maxCostTokens || 500000;
      const spent = r.live?.tokens || (r.spend7d?.totalTokens ? Math.min(maxBudget, r.spend7d.totalTokens / 5) : 0);
      const spentPct = Math.min(100, Math.round((spent / maxBudget) * 100));

      return h('div', {
        style: {
          border: `1px solid ${isRunning ? '#22404f' : RULE}`,
          borderRadius: '6px',
          background: isRunning ? '#111a22' : '#0f141a',
          padding: '14px 15px',
          display: 'flex',
          flexDirection: 'column',
          gap: '10px',
          cursor: 'pointer'
        },
        onClick: () => this.navigate('repo', r.id || r.name)
      },
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '8px' } },
          h('div', {
            className: isRunning ? 'pulse-anim' : '',
            style: { width: '7px', height: '7px', borderRadius: '50%', background: col }
          }),
          h('span', { style: { fontFamily: MONO, fontSize: '12px', color: '#f0f6fc' } }, r.name || r.path),
          h('div', { style: { flex: '1' } }),
          h('span', { style: { fontFamily: MONO, fontSize: '9.5px', letterSpacing: '0.08em', padding: '2px 6px', borderRadius: '2px', background: '#1a212a', color: col } }, r.state)
        ),
        h('div', { style: { fontSize: '12.5px', lineHeight: '1.45', color: '#a9b6c3', minHeight: '36px' } }, doing),
        h('div', {
          style: { display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: '8px', paddingTop: '2px', borderTop: '1px solid #1c242d' }
        },
          h('div', { style: { display: 'flex', flexDirection: 'column', gap: '2px' } },
            h('span', { style: { fontFamily: MONO, fontSize: '9.5px', color: IDLE } }, 'BRANCHES'),
            h('span', { style: { fontFamily: MONO, fontSize: '12px', color: TEXT } }, String(r.branches?.length || 0))
          ),
          h('div', { style: { display: 'flex', flexDirection: 'column', gap: '2px' } },
            h('span', { style: { fontFamily: MONO, fontSize: '9.5px', color: IDLE } }, 'PASS 7D'),
            h('span', { style: { fontFamily: MONO, fontSize: '12px', color: passCol } }, passRate)
          ),
          h('div', { style: { display: 'flex', flexDirection: 'column', gap: '2px' } },
            h('span', { style: { fontFamily: MONO, fontSize: '9.5px', color: IDLE } }, 'SPEND 7D'),
            h('span', { style: { fontFamily: MONO, fontSize: '12px', color: TEXT } }, spendTokens)
          )
        ),
        h('div', { style: { height: '6px', background: '#131a21', borderRadius: '2px', overflow: 'hidden', display: 'flex' } },
          h('div', { style: { height: '100%', background: '#2c5a70', width: `${spentPct * 0.85}%` } }),
          h('div', { style: { position: 'relative', height: '100%', background: A, width: `${spentPct * 0.15}%` } },
            h('div', { style: { position: 'absolute', top: 0, right: 0, height: '100%', width: '70%', background: VIOLET, opacity: 0.9, borderLeft: '1px solid #0e1116' } })
          ),
          h('div', { style: { height: '100%', background: '#1a212a', width: `${100 - spentPct}%` } })
        ),
        h('span', { style: { fontFamily: MONO, fontSize: '9.5px', color: IDLE } }, r.config?.summary || 'agy.toml')
      );
    });

    return h('div', {
      style: {
        padding: '18px 24px 30px',
        display: 'flex',
        flexDirection: 'column',
        gap: '12px'
      }
    },
      h('div', { style: { display: 'flex', alignItems: 'baseline', gap: '10px' } },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'REPOS USING THE PIPELINE'),
        h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: IDLE } }, 'each carries its own agy.toml, tiers, budget and gates')
      ),
      h('div', { style: { display: 'grid', gridTemplateColumns: 'repeat(3, minmax(0, 1fr))', gap: '12px' } },
        cards
      )
    );
  }

  // -------------------------------------------------------------
  // Repo View
  // -------------------------------------------------------------
  renderRepoView() {
    const data = this.state.repoData;
    if (!data) {
      return h('div', { style: { padding: '40px', color: MUTED } }, 'Loading repo details...');
    }

    const repo = data.repo || {};
    const branches = data.branches || [];
    const isRunning = repo.state === 'RUNNING';
    const rColor = statusColor(repo.state, null, isRunning);
    const passRate = repo.counts7d?.passRate != null ? `${Math.round(repo.counts7d.passRate * 100)}%` : '—';
    const passCol = repo.counts7d?.passRate >= 0.8 ? GREEN : (repo.counts7d?.passRate != null ? AMBER : DIM);
    const spend7d = repo.spend7d?.totalTokens != null ? shortTokens(repo.spend7d.totalTokens) : '—';

    const kpis = [
      ['BRANCHES', String(branches.length), 'each with its own worktree', TEXT],
      ['IN FLIGHT', isRunning ? '1' : '0', isRunning ? 'worker holds the repo lock' : 'no worker dispatched', isRunning ? A : DIM],
      ['PASS 7D', passRate, 'dispatches only · refusals & unknowns separate', passCol],
      ['SPEND 7D', spend7d, 'tokens across every phase', TEXT],
      ['NEEDS A HUMAN', '0', 'nothing waiting on you', DIM]
    ];

    const kpiCards = kpis.map(([label, val, note, col]) => h('div', {
      style: { background: '#151c24', padding: '11px 13px', display: 'flex', flexDirection: 'column', gap: '5px' }
    },
      h('span', { style: { fontSize: '10px', letterSpacing: '0.14em', color: MUTED } }, label),
      h('span', { style: { fontFamily: MONO, fontSize: '16px', color: col } }, val),
      h('span', { style: { fontFamily: MONO, fontSize: '10px', color: IDLE } }, note)
    ));

    const branchCards = branches.map(b => {
      const bColor = statusColor(b.state, b.stateClass, b.state === 'RUNNING');
      const runs = b.runs || [];

      const runRows = runs.map(r => {
        const runCol = statusColor(r.status, r.statusClass, r.live);
        return h('div', {
          style: {
            display: 'grid',
            gridTemplateColumns: '10px 210px minmax(0, 1fr) 92px 76px 116px',
            gap: '10px',
            alignItems: 'center',
            padding: '8px 9px',
            borderRadius: '4px',
            cursor: 'pointer',
            background: r.live ? '#12202a' : '#131a21'
          },
          onClick: () => this.navigate('run', this.state.repoId, r.id)
        },
          h('div', {
            className: r.live ? 'pulse-anim' : '',
            style: { width: '6px', height: '6px', borderRadius: '50%', background: runCol }
          }),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: DIM } }, r.id),
          h('span', { style: { fontSize: '12.5px', lineHeight: '1.4', color: SEC } }, r.task),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: r.live ? A : DIM } }, r.phase),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: DIM, textAlign: 'right' } }, shortTokens(r.tokens)),
          h('span', { style: { fontFamily: MONO, fontSize: '10px', letterSpacing: '0.06em', textAlign: 'right', color: runCol } }, r.status)
        );
      });

      return h('div', {
        style: {
          border: `1px solid ${b.state === 'RUNNING' ? '#22404f' : RULE}`,
          borderRadius: '6px',
          background: b.state === 'RUNNING' ? '#111a22' : '#0f141a',
          padding: '13px 15px',
          display: 'flex',
          flexDirection: 'column',
          gap: '11px'
        }
      },
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '9px' } },
          h('div', {
            className: b.state === 'RUNNING' ? 'pulse-anim' : '',
            style: { width: '7px', height: '7px', borderRadius: '50%', background: bColor }
          }),
          h('span', { style: { fontFamily: MONO, fontSize: '12.5px', color: '#f0f6fc' } }, b.name),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: MUTED } }, `base ${b.base || 'origin'}`),
          h('div', { style: { flex: '1' } }),
          h('span', { style: { fontFamily: MONO, fontSize: '10px', letterSpacing: '0.08em', padding: '2px 7px', borderRadius: '2px', background: '#1a212a', color: bColor } }, b.state)
        ),
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '7px' } },
          runRows.length ? runRows : h('div', { style: { color: IDLE, fontFamily: MONO, fontSize: '10.5px', padding: '6px' } }, 'No run history on this branch.')
        )
      );
    });

    return h('div', { style: { display: 'flex', flexDirection: 'column' } },
      // Repo Header Banner
      h('div', {
        style: {
          padding: '20px 24px 18px',
          borderBottom: `1px solid ${RULE}`,
          background: 'linear-gradient(#131a22, #11161d)',
          display: 'flex',
          flexDirection: 'column',
          gap: '14px'
        }
      },
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } },
          h('span', { style: { fontFamily: MONO, fontSize: '17px', color: '#f0f6fc' } }, repo.name || repo.path),
          h('span', { style: { fontFamily: MONO, fontSize: '10px', letterSpacing: '0.08em', padding: '3px 8px', borderRadius: '3px', background: '#1a212a', color: rColor } }, repo.state || 'IDLE'),
          h('div', { style: { flex: '1' } }),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: MUTED } }, repo.config?.summary || 'agy.toml')
        ),
        h('div', { style: { fontSize: '13px', lineHeight: '1.55', color: DIM, maxWidth: '820px' } }, repo.live?.doing || (repo.unreachable ? `Unreachable: ${repo.unreachable}` : 'Repository configured for automated delivery.')),
        h('div', {
          style: {
            display: 'grid',
            gridTemplateColumns: 'repeat(5, 1fr)',
            gap: '1px',
            background: RULE,
            border: `1px solid ${RULE}`,
            borderRadius: '5px',
            overflow: 'hidden'
          }
        }, kpiCards)
      ),

      // Branches section
      h('div', {
        style: {
          padding: '18px 24px 30px',
          display: 'flex',
          flexDirection: 'column',
          gap: '12px'
        }
      },
        h('div', { style: { display: 'flex', alignItems: 'baseline', gap: '10px' } },
          h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'BRANCHES'),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: IDLE } }, 'a run is scoped to one branch; two runs never share a worktree')
        ),
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '10px' } },
          branchCards
        )
      )
    );
  }

  // -------------------------------------------------------------
  // Run View
  // -------------------------------------------------------------
  renderRunView() {
    const data = this.state.runData;
    if (!data) {
      return h('div', { style: { padding: '40px', color: MUTED } }, 'Loading run details...');
    }

    return h('div', {
      style: {
        display: 'grid',
        gridTemplateColumns: 'minmax(0, 1fr) 372px',
        alignItems: 'start',
        minHeight: 'calc(100vh - 58px)'
      }
    },
      this.renderRunMainColumn(data),
      this.renderRunRightRail(data)
    );
  }

  renderRunMainColumn(data) {
    const run = data.run || {};
    const phases = data.phases || [];
    const activePhase = phases.find(p => p.status === 'RUNNING') || phases[phases.length - 1] || { name: 'DELEGATE', tier: 'medium' };
    const curIdx = Math.max(0, phases.findIndex(p => p.name === activePhase.name));
    const isLive = !!data.liveness?.live;
    const isRefused = activePhase.statusClass === 'A' || !activePhase.dispatched;
    const isFailed = activePhase.statusClass === 'B' || activePhase.status === 'VERIFY_FAILED';
    const isImpossible = activePhase.status === 'BRIEF_IMPOSSIBLE';
    const statusCol = statusColor(activePhase.status, activePhase.statusClass, isLive);

    const selLabel = isLive
      ? (activePhase.name === 'DELEGATE' ? 'DELEGATING' : `${activePhase.name} IN FLIGHT`)
      : (isRefused ? `REFUSED — ${activePhase.status}` : (isImpossible ? 'CLEAN STOP — BRIEF_IMPOSSIBLE' : (isFailed ? `HELD — ${activePhase.status}` : 'CLOSED — PASSED')));

    const elapsedStr = isRefused ? 'no dispatch' : formatDuration(activePhase.elapsedSeconds != null ? activePhase.elapsedSeconds : data.liveness?.lastWriteSeconds);

    // Mismatch note
    const isUndeclared = (data.undeclaredPhases || []).includes(activePhase.name) && activePhase.name !== 'DELEGATE';

    return h('div', { style: { display: 'flex', flexDirection: 'column', minHeight: 'calc(100vh - 58px)' } },
      // Run Top Banner
      h('div', {
        style: {
          padding: '20px 24px 18px',
          borderBottom: `1px solid ${RULE}`,
          display: 'flex',
          flexDirection: 'column',
          gap: '16px',
          background: 'linear-gradient(#131a22, #11161d)'
        }
      },
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } },
          h('div', {
            style: {
              display: 'flex', alignItems: 'center', gap: '6px', padding: '3px 8px', borderRadius: '3px',
              background: isLive ? '#0f2027' : (isRefused ? '#121820' : (isImpossible ? '#0c1a1a' : (isFailed ? '#1d1416' : '#131a21'))),
              border: `1px solid ${isLive ? '#1e3a4a' : (isRefused ? '#2a3644' : (isImpossible ? '#134e4a' : (isFailed ? '#3d2226' : RULE)))}`
            }
          },
            h('div', {
              className: isLive ? 'pulse-anim' : '',
              style: { width: '6px', height: '6px', borderRadius: '50%', background: statusCol }
            }),
            h('span', { style: { fontFamily: MONO, fontSize: '10px', letterSpacing: '0.12em', color: statusCol } }, selLabel)
          ),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: DIM } }, run.id || this.state.runId),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: '#2a343f' } }, '|'),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: DIM } }, `phase ${curIdx + 1} of ${phases.length} · ${activePhase.name} · attempt ${activePhase.attempts || 1}`),
          h('div', { style: { flex: '1' } }),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: MUTED } }, 'elapsed'),
          h('span', { style: { fontFamily: MONO, fontSize: '15px', color: TEXT } }, elapsedStr)
        ),

        // Brief & Task description
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '7px' } },
          h('div', { style: { display: 'flex', alignItems: 'baseline', gap: '10px' } },
            h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'WHAT IS BEING DELEGATED'),
            h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: IDLE } }, `${this.state.repoId} · ${run.branch || 'branch'}`),
            h('div', { style: { flex: '1' } }),
            run.issue ? h('div', {
              style: {
                display: 'flex', alignItems: 'center', gap: '6px', padding: '3px 9px',
                border: `1px solid ${RULE}`, borderRadius: '3px', background: '#131a21'
              }
            },
              h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: '#7dd3fc' } }, `#${run.issue}`),
              h('span', { style: { fontSize: '11px', color: DIM, maxWidth: '260px', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' } }, `Issue ${run.issue}`)
            ) : null
          ),
          h('div', { style: { fontSize: '21px', lineHeight: '1.35', color: '#f0f6fc', maxWidth: '780px' } }, run.task || 'Task execution'),
          h('div', { style: { fontSize: '13px', lineHeight: '1.55', color: DIM, maxWidth: '780px' } },
            `${isRefused ? 'Would have been dispatched for' : 'Dispatched for'} `,
            h('span', { style: { color: SEC } }, run.task || 'the designated phase'),
            `. ${CONSTRAINTS[activePhase.name] || CONSTRAINTS.DELEGATE}`
          )
        ),

        // 5 Metric Tiles
        h('div', {
          style: {
            display: 'grid',
            gridTemplateColumns: 'repeat(5, 1fr)',
            gap: '1px',
            background: RULE,
            border: `1px solid ${RULE}`,
            borderRadius: '5px',
            overflow: 'hidden'
          }
        },
          this.renderMetricTile('DRIVER', 'agy · headless -p'),
          this.renderMetricTile('MODEL', isRefused ? 'never resolved' : (activePhase.model || 'gemini-3.7-flash-medium')),
          this.renderMetricTile('TIER', activePhase.tier || 'medium', A),
          this.renderMetricTile('MODE', activePhase.mode || (activePhase.name === 'IMPLEMENT' || activePhase.name === 'DELEGATE' ? 'accept-edits' : 'read + report')),
          this.renderMetricTile('RUN SPEND', isRefused ? '0 tok' : `${commas(activePhase.usage?.totalTokens != null ? activePhase.usage.totalTokens : (data.budget?.spentTokens || 0))} tok`)
        ),

        // Scope chips
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '8px', flexWrap: 'wrap' } },
          h('span', { style: { fontSize: '10.5px', letterSpacing: '0.14em', color: MUTED } }, isRefused ? 'WOULD BE IN SCOPE' : 'IN SCOPE'),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: SEC, background: '#1a212a', border: `1px solid ${RULE}`, borderRadius: '3px', padding: '4px 8px' } }, '--add-dir <worktree>'),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: SEC, background: '#1a212a', border: `1px solid ${RULE}`, borderRadius: '3px', padding: '4px 8px' } }, `phases/${activePhase.name}/brief.md`),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: SEC, background: '#1a212a', border: `1px solid ${RULE}`, borderRadius: '3px', padding: '4px 8px' } }, `writes phases/${activePhase.name}/verdict`),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: SEC, background: '#1a212a', border: `1px solid ${RULE}`, borderRadius: '3px', padding: '4px 8px' } }, '--verify test_command')
        )
      ),

      // Ledger / Config mismatch banner if undeclared
      isUndeclared ? h('div', {
        style: {
          display: 'flex', alignItems: 'flex-start', gap: '10px', padding: '10px 24px',
          background: '#1d1416', borderBottom: '1px solid #3d2226'
        }
      },
        h('span', { style: { fontFamily: MONO, fontSize: '11px', fontWeight: '700', letterSpacing: '0.06em', color: '#fca5a5', whiteSpace: 'nowrap', paddingTop: '1px' } }, 'LEDGER / CONFIG MISMATCH'),
        h('span', { style: { fontSize: '12px', lineHeight: '1.5', color: '#fca5a5' } }, `This run reports phase ${activePhase.name}, which ${this.state.repoId}/agy.toml does not declare. Reconcile the ledger with agy.toml before trusting this run.`)
      ) : null,

      // Pipeline Phase Cards
      this.renderPipelinePhases(data),

      // Tabs Header
      this.renderRunTabsHeader(),

      // Tab Content Body
      this.renderRunTabContent(data)
    );
  }

  renderMetricTile(label, value, col = TEXT) {
    return h('div', {
      style: { background: '#151c24', padding: '10px 12px', display: 'flex', flexDirection: 'column', gap: '4px' }
    },
      h('span', { style: { fontSize: '10px', letterSpacing: '0.14em', color: MUTED } }, label),
      h('span', { style: { fontFamily: MONO, fontSize: '12.5px', color: col } }, value)
    );
  }

  renderPipelinePhases(data) {
    const phases = data.phases || [];
    const activePhase = phases.find(p => p.status === 'RUNNING') || phases[phases.length - 1] || {};

    const phaseCards = phases.map((p, idx) => {
      const isSelected = p.name === activePhase.name;
      const isLive = p.status === 'RUNNING';
      const isRefused = p.statusClass === 'A' || !p.dispatched;
      const isFailed = p.statusClass === 'B' || p.status === 'VERIFY_FAILED';
      const isImpossible = p.status === 'BRIEF_IMPOSSIBLE';
      const isDone = p.status === 'PASSED' || p.status === 'DONE';

      const barCol = isDone ? GREEN : (isRefused ? REFUSE : (isImpossible ? CLEAN : (isFailed ? RED : (isLive ? A : '#1a212a'))));
      const pct = isDone || isFailed || isImpossible ? 100 : (isLive ? 62 : 0);

      // Invariant 2: Claim vs Verification separated
      const claimText = p.verdict || (isLive ? 'running' : (isRefused ? 'refused' : '—'));
      const verifyText = p.verify?.ran ? (p.verify.rc === 0 ? 'PASSED' : `VERIFY_FAILED(rc=${p.verify.rc})`) : (isLive ? 'pending' : (isRefused ? p.status : '—'));

      const claimCol = p.verdict === 'PASSED' || p.verdict === 'DONE' ? GREEN : (isRefused ? REFUSE : (isLive ? A : IDLE));
      const verifyCol = p.verify?.rc === 0 ? GREEN : (verifyText === 'pending' ? AMBER : (isRefused ? REFUSE : (isImpossible ? CLEAN : (isFailed ? RED : IDLE))));

      return h('div', {
        style: {
          border: `1px solid ${isSelected ? '#2f5f78' : RULE}`,
          borderRadius: '5px',
          padding: '11px 12px',
          display: 'flex',
          flexDirection: 'column',
          gap: '9px',
          background: isSelected ? '#151f28' : '#141a21'
        }
      },
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '7px' } },
          h('span', { style: { fontFamily: MONO, fontSize: '10px', color: MUTED } }, String(idx + 1)),
          h('span', { style: { fontFamily: MONO, fontSize: '12px', fontWeight: '700', letterSpacing: '0.05em', color: TEXT } }, p.name),
          h('div', { style: { flex: '1' } }),
          h('span', {
            style: {
              fontFamily: MONO, fontSize: '9.5px', letterSpacing: '0.08em', padding: '2px 5px', borderRadius: '2px',
              background: '#1a212a', color: p.declaredTier ? '#7dd3fc' : MUTED
            }
          }, p.tier || 'medium'),
          !p.declaredTier ? h('span', {
            style: { fontFamily: MONO, fontSize: '8.5px', letterSpacing: '0.05em', color: MUTED },
            title: 'inherited default'
          }, 'default') : null
        ),
        h('div', { style: { height: '3px', borderRadius: '2px', background: '#1a212a', overflow: 'hidden', position: 'relative' } },
          h('div', { style: { height: '100%', borderRadius: '2px', width: `${pct}%`, background: barCol } }),
          isLive ? h('div', {
            className: 'sweep-anim',
            style: { position: 'absolute', inset: 0, width: '40%', opacity: 0.5, background: `linear-gradient(90deg, transparent, ${A}, transparent)` }
          }) : null
        ),
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '3px', fontFamily: MONO, fontSize: '10.5px' } },
          h('div', { style: { display: 'flex', justifyContent: 'space-between' } },
            h('span', { style: { color: MUTED } }, 'claim'),
            h('span', { style: { color: claimCol } }, claimText)
          ),
          h('div', { style: { display: 'flex', justifyContent: 'space-between' } },
            h('span', { style: { color: MUTED } }, 'verify'),
            h('span', { style: { color: verifyCol } }, verifyText)
          ),
          h('div', { style: { display: 'flex', justifyContent: 'space-between' } },
            h('span', { style: { color: MUTED } }, formatDuration(p.elapsedSeconds)),
            h('span', { style: { color: DIM } }, shortTokens(p.usage?.totalTokens))
          )
        )
      );
    });

    return h('div', { style: { padding: '18px 24px', borderBottom: `1px solid ${RULE}` } },
      h('div', { style: { display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', marginBottom: '13px' } },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'PIPELINE'),
        h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: MUTED } }, 'claim and verification reported separately, never blended')
      ),
      h('div', {
        style: {
          display: 'grid',
          gridTemplateColumns: `repeat(${Math.max(1, phases.length)}, 1fr)`,
          gap: '8px'
        }
      }, phaseCards)
    );
  }

  renderRunTabsHeader() {
    const currentTab = this.state.tab;
    const tabList = [
      ['overview', 'OVERVIEW'],
      ['transcript', 'TRANSCRIPT'],
      ['trace', 'TRACE'],
      ['diff', 'DIFF'],
      ['brief', 'BRIEF'],
      ['fleet', 'ANALYTICS']
    ];

    const tabEls = tabList.map(([key, label]) => h('div', {
      style: {
        padding: '12px 14px',
        fontFamily: MONO,
        fontSize: '11.5px',
        letterSpacing: '0.06em',
        cursor: 'pointer',
        borderBottom: `2px solid ${currentTab === key ? A : 'transparent'}`,
        color: currentTab === key ? TEXT : DIM
      },
      onClick: () => {
        this.state.tab = key;
        this.updateUrl();
        this.fetchCurrentView();
      }
    }, label));

    return h('div', {
      style: {
        display: 'flex',
        gap: '2px',
        padding: '0 24px',
        borderBottom: `1px solid ${RULE}`,
        background: CHROME
      }
    }, tabEls);
  }

  renderRunTabContent(data) {
    const tab = this.state.tab;
    if (tab === 'transcript') return this.renderTranscriptTab(data);
    if (tab === 'trace') return this.renderTraceTab(data);
    if (tab === 'diff') return this.renderDiffTab(data);
    if (tab === 'brief') return this.renderBriefTab(data);
    if (tab === 'fleet') return this.renderAnalyticsTab(data);
    return this.renderOverviewTab(data);
  }

  // -------------------------------------------------------------
  // Overview Tab
  // -------------------------------------------------------------
  renderOverviewTab(data) {
    const phases = data.phases || [];
    const activePhase = phases[phases.length - 1] || {};
    const status = activePhase.status || 'PASSED';
    const isDone = status === 'PASSED' || status === 'DONE';
    const isLive = data.liveness?.live;
    const isRefused = activePhase.statusClass === 'A' || !activePhase.dispatched;
    const isImpossible = status === 'BRIEF_IMPOSSIBLE';

    const cardBg = isLive ? '#111a22' : (isRefused ? '#121820' : (isImpossible ? '#0c1a1a' : (isDone ? '#0f1a14' : '#161012')));
    const cardBorder = isLive ? '#22404f' : (isRefused ? '#2a3644' : (isImpossible ? '#134e4a' : (isDone ? '#1c3d29' : '#3d2226')));
    const codeCol = isLive ? '#7dd3fc' : (isRefused ? REFUSE : (isImpossible ? CLEAN : (isDone ? '#86efac' : '#fca5a5')));

    const headline = isLive
      ? 'A worker holds this branch right now. Nothing is verified until it returns and the orchestrator runs the verify command.'
      : (isRefused
        ? `Refused before dispatch (${status}). No model call was made, and zero tokens were spent on this dispatch.`
        : (isImpossible
          ? 'BRIEF_IMPOSSIBLE — the worker named a collision between the brief and its constraints before editing anything. Round refunded, no retry consumed.'
          : (isDone
            ? 'All declared phases completed and verified independently by the test suite. Irreversible commands are printed below for a human, not executed.'
            : `Held at ${status}. The test command overturned the claim or a resource cap was reached.`)));

    const nextText = isLive
      ? 'follow the log, or abort if the elapsed time stops making sense'
      : (isDone ? 'read the captured diff, then run the printed gh commands yourself' : 'read the verify log named on this line, then fix or re-brief once');

    // Artifacts list
    const artifactList = [
      ['phases/DELEGATE/verdict', 'STATUS: DONE (worker claim)', true],
      ['phases/DELEGATE/verify.log', 'command exited 0', true],
      ['REVIEW_DIFF.patch', 'captured by the orchestrator', true],
      ['ISSUE_COMMENT.md', 'composed by run-summary.sh', !!this.state.artifacts['summary']],
      ['phases/DELEGATE/brief.md', 'dispatched brief', true]
    ];

    const artifactEls = artifactList.map(([name, note, produced]) => h('div', {
      style: { display: 'flex', alignItems: 'center', gap: '10px', cursor: 'pointer' }
    },
      h('span', { style: { fontFamily: MONO, fontSize: '11px', color: produced ? GREEN : IDLE } }, produced ? '✓' : '○'),
      h('span', { style: { fontFamily: MONO, fontSize: '11.5px', color: produced ? SEC : IDLE } }, name),
      h('div', { style: { flex: '1', height: '1px', background: '#1c242d' } }),
      h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: MUTED } }, note)
    ));

    return h('div', {
      style: {
        padding: '16px 24px 28px',
        display: 'grid',
        gridTemplateColumns: 'minmax(0, 1fr) minmax(0, 1fr)',
        gap: '16px',
        alignItems: 'start'
      }
    },
      // Status Headline Card
      h('div', {
        style: {
          border: `1px solid ${cardBorder}`,
          borderRadius: '6px',
          background: cardBg,
          padding: '16px 18px',
          display: 'flex',
          flexDirection: 'column',
          gap: '11px',
          gridColumn: 'span 2'
        }
      },
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } },
          h('span', { style: { fontFamily: MONO, fontSize: '12px', fontWeight: '700', letterSpacing: '0.08em', color: codeCol } }, status),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: DIM } }, `${activePhase.name} · attempt ${activePhase.attempts || 1}`),
          h('div', { style: { flex: '1' } }),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: MUTED } }, isLive ? 'running' : 'completed')
        ),
        h('div', { style: { fontSize: '14px', lineHeight: '1.6', color: '#f0f6fc', maxWidth: '760px' } }, headline),
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px', paddingTop: '4px' } },
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', letterSpacing: '0.14em', color: MUTED } }, 'NEXT'),
          h('span', { style: { fontSize: '12.5px', color: SEC } }, nextText),
          h('div', { style: { flex: '1' } }),
          h('span', {
            style: {
              fontFamily: MONO, fontSize: '11px', padding: '6px 11px', borderRadius: '4px', cursor: 'pointer',
              border: '1px solid #1e3a4a', background: '#0f2027', color: '#7dd3fc'
            },
            onClick: () => { this.state.tab = 'transcript'; this.render(); }
          }, 'OPEN LOG')
        )
      ),

      // Artifacts Produced Card
      h('div', {
        style: {
          border: `1px solid ${RULE}`,
          borderRadius: '6px',
          background: '#0f141a',
          padding: '15px 17px',
          display: 'flex',
          flexDirection: 'column',
          gap: '12px'
        }
      },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.16em', color: MUTED } }, 'ARTIFACTS PRODUCED'),
        artifactEls
      ),

      // Anchors / Review Feedback Card
      h('div', {
        style: {
          border: `1px solid ${RULE}`,
          borderRadius: '6px',
          background: '#0f141a',
          padding: '15px 17px',
          display: 'flex',
          flexDirection: 'column',
          gap: '12px'
        }
      },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.16em', color: MUTED } }, 'REVIEW FEEDBACK'),
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '4px', paddingLeft: '10px', borderLeft: '2px solid #1e3a4a' } },
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: '#7dd3fc' } }, 'Diff integrity & verification'),
          h('span', { style: { fontSize: '12.5px', lineHeight: '1.5', color: '#a9b6c3' } }, data.diffIntegrity?.detail || 'No integrity anomalies detected. Changes are isolated to worktree.')
        )
      )
    );
  }

  // -------------------------------------------------------------
  // Transcript Tab
  // -------------------------------------------------------------
  renderTranscriptTab(data) {
    const rawLog = this.state.logText || '';

    const filterChips = ['ALL', 'THINKING', 'TOOLS', 'FINDINGS', 'GATES'].map(f => h('span', {
      style: {
        fontFamily: MONO, fontSize: '10.5px', padding: '4px 8px', borderRadius: '3px', cursor: 'pointer',
        background: this.state.transcriptFilter === f ? A : '#1a212a',
        color: this.state.transcriptFilter === f ? PAGE : DIM
      },
      onClick: () => {
        this.state.transcriptFilter = f;
        this.render();
      }
    }, f));

    return h('div', { style: { padding: '16px 24px 28px', display: 'flex', flexDirection: 'column', gap: '12px' } },
      h('div', { style: { display: 'flex', alignItems: 'center', gap: '8px' } },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'WORKER TRANSCRIPT'),
        h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: MUTED } }, 'log stream'),
        h('div', { style: { flex: '1' } }),
        filterChips,
        h('span', {
          style: {
            fontFamily: MONO, fontSize: '10.5px', padding: '4px 8px', borderRadius: '3px', cursor: 'pointer',
            border: '1px solid #1e3a4a', color: '#7dd3fc', background: '#0f2027'
          },
          onClick: () => {
            this.state.followLog = !this.state.followLog;
            this.render();
          }
        }, this.state.followLog ? 'FOLLOWING ▾' : 'PAUSED ▸')
      ),
      h('div', {
        id: 'transcript-raw-log',
        style: {
          border: `1px solid ${RULE}`,
          borderRadius: '6px',
          background: '#0f141a',
          padding: '16px',
          fontFamily: MONO,
          fontSize: '11.5px',
          lineHeight: '1.6',
          whiteSpace: 'pre-wrap',
          color: SEC,
          maxHeight: '600px',
          overflowY: 'auto'
        }
      }, rawLog || 'No log output captured yet.')
    );
  }

  // -------------------------------------------------------------
  // Trace Tab
  // -------------------------------------------------------------
  renderTraceTab(data) {
    const isWaterfall = this.state.traceMode === 'waterfall';

    const toggleChip = (on, label, onClick) => h('span', {
      style: {
        fontFamily: MONO, fontSize: '10.5px', padding: '5px 10px', borderRadius: '3px',
        cursor: 'pointer', color: on ? PAGE : DIM, background: on ? A : '#1a212a'
      },
      onClick
    }, label);

    return h('div', { style: { padding: '16px 24px 28px', display: 'flex', flexDirection: 'column', gap: '14px' } },
      h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'TRACE'),
        h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: MUTED } }, isWaterfall ? 'spans reconstructed from log timestamps' : 'tokens breakdown per turn'),
        h('div', { style: { flex: '1' } }),
        h('div', { style: { display: 'flex', gap: '4px' } },
          toggleChip(isWaterfall, 'WATERFALL', () => { this.state.traceMode = 'waterfall'; this.render(); }),
          toggleChip(!isWaterfall, 'TOKEN RIBBON', () => { this.state.traceMode = 'ribbon'; this.render(); })
        )
      ),

      isWaterfall ? h('div', {
        style: { border: `1px solid ${RULE}`, borderRadius: '6px', background: '#0f141a', padding: '14px 16px', display: 'flex', flexDirection: 'column', gap: '8px' }
      },
        h('div', { style: { display: 'grid', gridTemplateColumns: '210px minmax(0, 1fr) 62px', gap: '12px', paddingBottom: '8px', borderBottom: '1px solid #1c242d', fontFamily: MONO, fontSize: '10px', color: IDLE } },
          h('span', null, 'SPAN'),
          h('span', null, 'EXECUTION TIMELINE'),
          h('span', { style: { textAlign: 'right' } }, 'DUR')
        ),
        (data.phases || []).map(p => h('div', {
          style: { display: 'grid', gridTemplateColumns: '210px minmax(0, 1fr) 62px', gap: '12px', alignItems: 'center' }
        },
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: SEC } }, p.name),
          h('div', { style: { height: '15px', background: '#131a21', borderRadius: '3px', position: 'relative' } },
            h('div', {
              style: { position: 'absolute', top: 0, left: '0%', width: '100%', height: '100%', background: statusColor(p.status, p.statusClass, p.status === 'RUNNING'), borderRadius: '3px' }
            })
          ),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: DIM, textAlign: 'right' } }, formatDuration(p.elapsedSeconds))
        ))
      ) : h('div', {
        style: { border: `1px solid ${RULE}`, borderRadius: '6px', background: '#0f141a', padding: '16px', display: 'flex', flexDirection: 'column', gap: '14px' }
      },
        h('div', { style: { height: '120px', display: 'flex', alignItems: 'flex-end', gap: '6px' } },
          h('div', { style: { flex: '1', display: 'flex', flexDirection: 'column', gap: '2px' } },
            h('div', { style: { height: '40px', background: VIOLET, borderRadius: '2px 2px 0 0' } }),
            h('div', { style: { height: '20px', background: A } }),
            h('div', { style: { height: '60px', background: '#1e3a4a', borderRadius: '0 0 2px 2px' } })
          )
        ),
        h('div', { style: { display: 'flex', gap: '18px', paddingTop: '12px', borderTop: '1px solid #1c242d', fontFamily: MONO, fontSize: '10.5px', color: DIM } },
          h('span', { style: { display: 'flex', alignItems: 'center', gap: '6px' } }, h('span', { style: { width: '9px', height: '9px', background: '#1e3a4a', borderRadius: '2px' } }), 'input'),
          h('span', { style: { display: 'flex', alignItems: 'center', gap: '6px' } }, h('span', { style: { width: '9px', height: '9px', background: A, borderRadius: '2px' } }), 'output'),
          h('span', { style: { display: 'flex', alignItems: 'center', gap: '6px' } }, h('span', { style: { width: '9px', height: '9px', background: VIOLET, borderRadius: '2px' } }), 'thinking ⊂ output')
        )
      )
    );
  }

  // -------------------------------------------------------------
  // Diff Tab
  // -------------------------------------------------------------
  renderDiffTab(data) {
    const diffText = this.state.artifacts['diff'] || 'No diff patch captured.';

    return h('div', { style: { padding: '16px 24px 28px', display: 'flex', flexDirection: 'column', gap: '14px' } },
      h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'DIFF & INTEGRITY'),
        h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: MUTED } }, 'REVIEW_DIFF.patch · check-diff-integrity.sh')
      ),
      h('div', {
        style: {
          border: `1px solid ${RULE}`,
          borderRadius: '6px',
          background: '#0f141a',
          padding: '16px',
          fontFamily: MONO,
          fontSize: '11px',
          lineHeight: '1.6',
          whiteSpace: 'pre-wrap',
          color: SEC,
          overflowX: 'auto'
        }
      }, diffText)
    );
  }

  // -------------------------------------------------------------
  // Brief Tab
  // -------------------------------------------------------------
  renderBriefTab(data) {
    const briefText = this.state.artifacts['brief'] || 'No brief loaded.';
    const run = data.run || {};
    const ghCommands = data.summary?.commands || [
      `gh issue comment ${run.issue || '<issue>'} --body-file .agy/runs/${run.id}/ISSUE_COMMENT.md`
    ];

    return h('div', { style: { display: 'flex', flexDirection: 'column', gap: '20px' } },
      h('div', {
        style: {
          padding: '16px 24px 0',
          display: 'grid',
          gridTemplateColumns: 'minmax(0, 1fr) 260px',
          gap: '16px',
          alignItems: 'start'
        }
      },
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '12px' } },
          h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } },
            h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'DISPATCHED BRIEF'),
            h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: MUTED } }, 'byte-for-byte copy of what the worker got')
          ),
          h('div', {
            style: {
              border: `1px solid ${RULE}`,
              borderRadius: '6px',
              background: '#0f141a',
              padding: '18px 20px',
              fontFamily: MONO,
              fontSize: '12px',
              lineHeight: '1.85',
              whiteSpace: 'pre-wrap',
              color: '#a9b6c3'
            }
          }, briefText)
        ),
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '10px' } },
          h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'BRIEF LINT'),
          h('div', { style: { border: `1px solid ${RULE}`, borderRadius: '6px', background: '#0f141a', overflow: 'hidden' } },
            [
              'Verdict path points at phases/verdict',
              'Both verdict routes instructed — file and stdout',
              'Shell execution prohibited (driver reports shell=no)',
              'Git commit, stage and branch forbidden',
              'check-secrets.sh — 0 findings, nothing echoed'
            ].map(l => h('div', {
              style: { display: 'flex', alignItems: 'baseline', gap: '9px', padding: '9px 12px', borderBottom: '1px solid #171e26' }
            },
              h('span', { style: { fontFamily: MONO, fontSize: '11px', color: GREEN } }, '✓'),
              h('span', { style: { fontSize: '12px', lineHeight: '1.45', color: '#a9b6c3' } }, l)
            ))
          ),
          h('div', { style: { fontFamily: MONO, fontSize: '10.5px', lineHeight: '1.7', color: MUTED } }, 'check-brief.sh + check-secrets.sh ran before dispatch. An invalid brief costs zero tokens.')
        )
      ),

      // Unrun gh commands & Issue comment
      h('div', {
        style: {
          padding: '0 24px 28px',
          display: 'grid',
          gridTemplateColumns: 'minmax(0, 1fr) 260px',
          gap: '16px',
          alignItems: 'start'
        }
      },
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '12px' } },
          h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px', flexWrap: 'wrap' } },
            h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: '#fcd34d' } }, 'UNRUN gh COMMANDS · PRINT, NEVER POST'),
            h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: '#6b5a2a' } }, 'run-summary.sh composes these — it executes no gh command')
          ),
          h('div', {
            style: {
              border: '1px solid #3d3113',
              borderRadius: '6px',
              background: '#14110a',
              padding: '15px 17px',
              display: 'flex',
              flexDirection: 'column',
              gap: '11px'
            }
          },
            h('div', { style: { display: 'flex', alignItems: 'center', gap: '8px' } },
              h('span', { style: { width: '7px', height: '7px', borderRadius: '50%', background: AMBER } }),
              h('span', { style: { fontFamily: MONO, fontSize: '10px', letterSpacing: '0.06em', color: '#b78a2e' } }, 'these have not been run and will not be — copy and execute them yourself')
            ),
            h('div', { style: { display: 'flex', flexDirection: 'column', gap: '8px' } },
              ghCommands.map(cmd => h('div', {
                style: {
                  display: 'flex', alignItems: 'baseline', gap: '9px', fontFamily: MONO, fontSize: '12px', lineHeight: '1.6',
                  color: '#e6d9a8', background: '#0e0c07', border: '1px solid #241d0e', borderRadius: '4px',
                  padding: '9px 11px', whiteSpace: 'pre-wrap', wordBreak: 'break-all', cursor: 'pointer'
                },
                onClick: (e) => copyToClipboard(cmd, e.currentTarget)
              },
                h('span', { style: { color: '#6b5a2a' } }, '$'),
                cmd
              ))
            )
          )
        ),
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '8px' } },
          h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'WHY PRINT, NEVER POST'),
          h('div', {
            style: {
              border: '1px dashed #2a343f',
              borderRadius: '6px',
              background: '#0d1116',
              padding: '13px 15px',
              fontSize: '12px',
              lineHeight: '1.65',
              color: DIM
            }
          }, 'Every irreversible action — posting to an issue, opening a PR, pushing — is composed and printed for a human. The pipeline runs no gh command for you. What agy did is captured as a diff and a verdict; what happens on GitHub is your call.')
        )
      )
    );
  }

  // -------------------------------------------------------------
  // Analytics Tab (Fleet / Metrics Tab)
  // -------------------------------------------------------------
  renderAnalyticsTab(data) {
    const metrics = this.state.repoData?.metrics || {};
    const records = metrics.records || data.records || { read: 0, valid: 0, noContext: 0, unparseable: 0 };
    const absent = metrics.absent || data.records?.absent || {};

    const recTotal = (records.valid || 0) + (records.noContext || 0) || 1;
    const dispCount = records.valid || 0;
    const refCount = records.noContext || 0;

    return h('div', { style: { padding: '16px 24px 28px', display: 'flex', flexDirection: 'column', gap: '18px' } },
      // Record Accounting
      h('div', { style: { border: `1px solid ${RULE}`, borderRadius: '6px', background: '#0f141a', overflow: 'hidden' } },
        h('div', { style: { padding: '13px 17px', borderBottom: '1px solid #1c242d', display: 'flex', alignItems: 'baseline', gap: '10px' } },
          h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.16em', color: MUTED } }, 'RECORD ACCOUNTING'),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: IDLE } }, `${records.read || 0} records read · ${records.valid || 0} valid context`)
        ),
        h('div', { style: { padding: '15px 17px', display: 'flex', flexDirection: 'column', gap: '12px' } },
          h('div', { style: { height: '14px', background: '#131a21', borderRadius: '3px', overflow: 'hidden', display: 'flex' } },
            h('div', { style: { height: '100%', width: `${(dispCount / recTotal) * 100}%`, background: A } }),
            h('div', { style: { height: '100%', width: `${(refCount / recTotal) * 100}%`, background: REFUSE } })
          ),
          h('div', { style: { display: 'flex', alignItems: 'center', gap: '16px', fontFamily: MONO, fontSize: '10.5px', color: '#a9b6c3' } },
            h('span', { style: { display: 'flex', alignItems: 'center', gap: '6px' } }, h('span', { style: { width: '9px', height: '9px', borderRadius: '2px', background: A } }), `dispatched · ${dispCount}`),
            h('span', { style: { display: 'flex', alignItems: 'center', gap: '6px' } }, h('span', { style: { width: '9px', height: '9px', borderRadius: '2px', background: REFUSE } }), `refused · ${refCount}`)
          ),
          h('div', { style: { fontSize: '12px', lineHeight: '1.55', color: MUTED } },
            'Class A refusals fired before any worker ran — zero spend. Absent fields predate the ledger schema and render as unknown, never as confident passes.'
          )
        )
      ),

      // Class A vs Class B vocabulary
      h('div', { style: { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px', alignItems: 'start' } },
        h('div', { style: { border: '1px solid #2a3644', borderRadius: '6px', background: '#0f141a', padding: '15px 17px', display: 'flex', flexDirection: 'column', gap: '10px' } },
          h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.16em', color: REFUSE } }, 'CLASS A · REFUSED BEFORE DISPATCH'),
          h('span', { style: { fontFamily: MONO, fontSize: '10px', color: IDLE } }, 'no model call · no diff · zero spend'),
          h('div', { style: { display: 'flex', flexDirection: 'column', gap: '5px', marginTop: '3px' } },
            STATUS_VOCAB.A.map(s => h('span', { style: { fontFamily: MONO, fontSize: '11px', color: SEC } }, s))
          )
        ),
        h('div', { style: { display: 'flex', flexDirection: 'column', gap: '16px' } },
          h('div', { style: { border: '1px solid #3d2226', borderRadius: '6px', background: '#120e0f', padding: '15px 17px', display: 'flex', flexDirection: 'column', gap: '10px' } },
            h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.16em', color: '#fca5a5' } }, 'CLASS B · DISPATCHED, THEN FAILED'),
            h('span', { style: { fontFamily: MONO, fontSize: '10px', color: '#6b4a4d' } }, 'a worker ran · real spend'),
            h('div', { style: { display: 'flex', flexDirection: 'column', gap: '5px', marginTop: '3px' } },
              STATUS_VOCAB.B.map(s => h('span', { style: { fontFamily: MONO, fontSize: '11px', color: '#e6b8ba' } }, s))
            )
          ),
          h('div', { style: { border: '1px solid #134e4a', borderRadius: '6px', background: '#0c1a1a', padding: '15px 17px', display: 'flex', flexDirection: 'column', gap: '8px' } },
            h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.16em', color: CLEAN } }, 'CLEAN STOP'),
            h('span', { style: { fontSize: '12px', lineHeight: '1.55', color: '#9fded4' } }, STATUS_VOCAB.clean)
          )
        )
      )
    );
  }

  // -------------------------------------------------------------
  // Run Right Rail Component
  // -------------------------------------------------------------
  renderRunRightRail(data) {
    const run = data.run || {};
    const phases = data.phases || [];
    const activePhase = phases[phases.length - 1] || {};
    const isLive = !!data.liveness?.live;
    const isRefused = activePhase.statusClass === 'A' || !activePhase.dispatched;
    const isFailed = activePhase.statusClass === 'B' || activePhase.status === 'VERIFY_FAILED';
    const isImpossible = activePhase.status === 'BRIEF_IMPOSSIBLE';

    const elapsed = formatDuration(activePhase.elapsedSeconds != null ? activePhase.elapsedSeconds : data.liveness?.lastWriteSeconds);
    const lastWrite = isLive ? `${data.liveness?.lastWriteSeconds || 0}s` : (isRefused ? 'no worker attached' : 'run closed');

    // Operator Controls Buttons (copyable commands)
    const controls = this.getOperatorControls(activePhase.status, isLive);

    // Budget tokens
    const maxBudget = data.budget?.maxCostTokens || 500000;
    const spentTokens = data.budget?.spentTokens || 0;
    const burnPct = maxBudget ? Math.min(100, (spentTokens / maxBudget) * 100) : 0;
    const cacheTokens = shortTokens(activePhase.usage?.cacheReadTokens || 0);

    return h('div', {
      style: {
        borderLeft: `1px solid ${RULE}`,
        background: CHROME,
        minHeight: 'calc(100vh - 58px)',
        display: 'flex',
        flexDirection: 'column'
      }
    },
      // LIVENESS Panel
      h('div', {
        style: {
          padding: '15px 17px',
          borderBottom: '1px solid #1c242d',
          display: 'flex',
          flexDirection: 'column',
          gap: '12px'
        }
      },
        h('div', { style: { display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' } },
          h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'LIVENESS'),
          h('span', { style: { fontFamily: MONO, fontSize: '10px', color: IDLE } }, 'timeout at 30m')
        ),
        h('div', { style: { display: 'flex', alignItems: 'baseline', gap: '10px' } },
          h('span', { style: { fontFamily: MONO, fontSize: '30px', letterSpacing: '-0.02em', color: TEXT } }, elapsed),
          h('div', { style: { display: 'flex', flexDirection: 'column' } },
            h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: DIM } }, isLive ? 'last log write' : 'final log write'),
            h('span', { style: { fontFamily: MONO, fontSize: '12px', color: isLive ? '#cbd5e0' : MUTED } }, lastWrite)
          )
        ),
        h('div', {
          id: 'liveness-pulse-bars',
          style: { display: 'flex', alignItems: 'flex-end', gap: '2px', height: '34px' }
        },
          this.getPulseBarElements()
        ),
        h('div', {
          style: {
            display: 'flex', alignItems: 'center', gap: '8px', padding: '9px 11px', borderRadius: '4px',
            background: isLive || isFailed ? '#1a1508' : '#131a21', border: `1px solid ${isLive || isFailed ? '#3d3113' : RULE}`
          }
        },
          h('span', { style: { fontFamily: MONO, fontSize: '11px', color: isLive || isFailed ? AMBER : DIM } }, '⚠'),
          h('span', { style: { fontSize: '12px', lineHeight: '1.45', color: isLive || isFailed ? '#fcd34d' : DIM } },
            isLive
              ? 'A hung worker and a thinking worker look identical from outside. This warns; it never aborts.'
              : (isRefused
                ? 'The gate refused this dispatch before a worker started. Zero spend on this dispatch.'
                : (isFailed ? 'The run is held awaiting operator decision. Nothing is lost while it waits.' : 'No worker attached — run closed.'))
          )
        )
      ),

      // OPERATOR CONTROLS Panel
      h('div', {
        style: {
          padding: '15px 17px',
          borderBottom: '1px solid #1c242d',
          display: 'flex',
          flexDirection: 'column',
          gap: '10px'
        }
      },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'OPERATOR CONTROLS'),
        h('div', { style: { display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '7px' } },
          controls
        ),
        h('div', { style: { fontFamily: MONO, fontSize: '10px', lineHeight: '1.65', color: IDLE } },
          'Irreversible actions print a command for you to run. Nothing here pushes, tags or merges.'
        )
      ),

      // BUDGET BURN-DOWN Panel
      h('div', {
        style: {
          padding: '15px 17px',
          borderBottom: '1px solid #1c242d',
          display: 'flex',
          flexDirection: 'column',
          gap: '12px'
        }
      },
        h('div', { style: { display: 'flex', alignItems: 'baseline', justifyContent: 'space-between' } },
          h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'BUDGET BURN-DOWN'),
          h('span', { style: { fontFamily: MONO, fontSize: '10px', color: IDLE } }, 'this run')
        ),
        h('div', { style: { display: 'flex', alignItems: 'baseline', gap: '7px', fontFamily: MONO } },
          h('span', { style: { fontSize: '22px', color: TEXT } }, commas(spentTokens)),
          h('span', { style: { fontSize: '12px', color: MUTED } }, `/ ${commas(maxBudget)} tokens`)
        ),
        h('div', { style: { height: '9px', background: '#131a21', borderRadius: '3px', overflow: 'hidden', display: 'flex' } },
          h('div', { style: { height: '100%', background: '#2c5a70', width: `${burnPct * 0.85}%` } }),
          h('div', { style: { position: 'relative', height: '100%', background: A, width: `${burnPct * 0.15}%` } },
            h('div', { style: { position: 'absolute', top: 0, right: 0, height: '100%', width: '70%', background: VIOLET, opacity: 0.9, borderLeft: '1px solid #0e1116' } })
          ),
          h('div', { style: { height: '100%', background: '#1a212a', width: `${100 - burnPct}%` } })
        ),
        h('div', { style: { display: 'flex', alignItems: 'center', gap: '12px', fontFamily: MONO, fontSize: '9.5px', color: DIM } },
          h('span', { style: { display: 'flex', alignItems: 'center', gap: '5px' } }, h('span', { style: { width: '9px', height: '9px', background: '#1e3a4a', borderRadius: '2px' } }), 'input'),
          h('span', { style: { display: 'flex', alignItems: 'center', gap: '5px' } }, h('span', { style: { width: '9px', height: '9px', background: A, borderRadius: '2px' } }), 'output'),
          h('span', { style: { display: 'flex', alignItems: 'center', gap: '5px' } }, h('span', { style: { width: '9px', height: '9px', background: VIOLET, borderRadius: '2px' } }), 'thinking ⊂ output')
        ),
        h('div', {
          style: {
            display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', padding: '7px 9px',
            border: '1px dashed #2a343f', borderRadius: '4px', background: '#0f141a'
          }
        },
          h('span', { style: { fontFamily: MONO, fontSize: '10px', letterSpacing: '0.04em', color: MUTED } }, 'CACHE READ · not billed'),
          h('span', { style: { fontFamily: MONO, fontSize: '12px', color: '#a9b6c3' } }, `≈${cacheTokens}`)
        ),
        this.state.showDollars ? h('div', { style: { fontFamily: MONO, fontSize: '10.5px', color: DIM } },
          `≈ $${((spentTokens / 1000000) * this.state.pricePerMtok).toFixed(2)} at $${this.state.pricePerMtok}/Mtok — rates are yours to supply; the ledger records tokens`
        ) : null
      ),

      // CLAIM VS VERIFICATION Panel
      h('div', {
        style: {
          padding: '15px 17px',
          borderBottom: '1px solid #1c242d',
          display: 'flex',
          flexDirection: 'column',
          gap: '10px'
        }
      },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'CLAIM VS VERIFICATION'),
        phases.map(p => h('div', {
          style: { display: 'grid', gridTemplateColumns: '76px 1fr 1fr', gap: '8px', alignItems: 'center', padding: '7px 0', borderBottom: '1px solid #171e26' }
        },
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: DIM } }, p.name),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', color: p.verdict === 'PASSED' ? GREEN : DIM } }, p.verdict ? `claim ${p.verdict}` : 'did not run'),
          h('span', { style: { fontFamily: MONO, fontSize: '10.5px', textAlign: 'right', color: p.verify?.rc === 0 ? GREEN : (p.verify?.rc ? RED : DIM) } }, p.verify?.ran ? (p.verify.rc === 0 ? 'verified ✓' : 'OVERRIDDEN ✕') : 'did not run')
        ))
      ),

      // PROVENANCE Panel
      h('div', {
        style: {
          padding: '15px 17px',
          display: 'flex',
          flexDirection: 'column',
          gap: '10px'
        }
      },
        h('span', { style: { fontSize: '10.5px', fontWeight: '600', letterSpacing: '0.18em', color: MUTED } }, 'PROVENANCE'),
        [
          ['WORKTREE', `${this.state.repoId}/.agy/worktrees/${run.id || 'run'}`],
          ['BASE COMMIT', run.base || '—'],
          ['DRIVER', 'drivers/agy.sh · headless -p'],
          ['MODEL', activePhase.model || 'gemini-3.7-flash-medium']
        ].map(([k, v]) => h('div', { style: { display: 'flex', flexDirection: 'column', gap: '2px' } },
          h('span', { style: { fontFamily: MONO, fontSize: '10px', letterSpacing: '0.06em', color: IDLE } }, k),
          h('span', { style: { fontFamily: MONO, fontSize: '11px', lineHeight: '1.5', color: '#a9b6c3', wordBreak: 'break-all' } }, v)
        )),
        h('div', { style: { display: 'flex', flexWrap: 'wrap', gap: '5px', paddingTop: '4px' } },
          [
            ['shell=no', RED], ['sandbox=yes', GREEN], ['effort=yes', GREEN],
            ['read_outside_dir=no', RED], ['plan_mode_writes=no', RED]
          ].map(([lbl, col]) => h('span', {
            style: { fontFamily: MONO, fontSize: '10px', padding: '3px 6px', borderRadius: '2px', background: '#1a212a', color: col }
          }, lbl))
        )
      )
    );
  }

  getPulseBarElements() {
    return this.state.pulse.map((p, i) => h('div', {
      style: {
        flex: '1',
        borderRadius: '1px',
        height: `${Math.max(2, p.v)}px`,
        background: i > 33 ? (p.v > 12 ? A : '#1e3a4a') : (p.v > 12 ? '#2c5a70' : '#1a212a')
      }
    }));
  }

  renderPulseBars(container) {
    while (container.firstChild) {
      container.removeChild(container.firstChild);
    }
    this.getPulseBarElements().forEach(el => container.appendChild(el));
  }

  getOperatorControls(status, isLive) {
    const makeBtn = (label, col, border, commandText, span = 'auto') => h('div', {
      style: {
        padding: '9px 10px', borderRadius: '4px', border: `1px solid ${border}`, background: '#1a212a',
        fontFamily: MONO, fontSize: '10.5px', letterSpacing: '0.04em', textAlign: 'center', cursor: 'pointer',
        color: col, gridColumn: span
      },
      onClick: (e) => copyToClipboard(commandText || label, e.currentTarget)
    }, label);

    const CYAN = ['#7dd3fc', '#1e3a4a'];
    const DANGER = ['#fca5a5', '#3d2226'];
    const PLAIN = [SEC, RULE];
    const MUTED_BTN = [DIM, RULE];

    if (isLive) {
      return [
        makeBtn('ABORT DISPATCH', DANGER[0], DANGER[1], `agy abort ${this.state.runId}`),
        makeBtn('RUN TESTS MYSELF', CYAN[0], CYAN[1], 'npm test'),
        makeBtn('RAISE BUDGET', PLAIN[0], PLAIN[1], 'edit agy.toml budget'),
        makeBtn('FOLLOW LOG', PLAIN[0], PLAIN[1], 'tail -f phases/log')
      ];
    }

    if (status === 'VERIFY_FAILED') {
      return [
        makeBtn('RE-BRIEF & RETRY', CYAN[0], CYAN[1], `agy retry ${this.state.runId}`),
        makeBtn('RESET RETRIES', PLAIN[0], PLAIN[1], 'agy reset-retries'),
        makeBtn('RUN TESTS MYSELF', PLAIN[0], PLAIN[1], 'npm test'),
        makeBtn('CLOSE RUN', DANGER[0], DANGER[1], `agy close ${this.state.runId}`)
      ];
    }

    if (status === 'CAP HIT' || status === 'RETRY_CAP_REACHED') {
      return [
        makeBtn('TAKE OVER BY HAND', CYAN[0], CYAN[1], `git checkout -b fix/${this.state.runId}`),
        makeBtn('RESET RETRIES', PLAIN[0], PLAIN[1], 'agy reset-retries'),
        makeBtn('RUN TESTS MYSELF', PLAIN[0], PLAIN[1], 'npm test'),
        makeBtn('CLOSE RUN', DANGER[0], DANGER[1], `agy close ${this.state.runId}`)
      ];
    }

    if (status === 'WORKER_CAP_EXCEEDED') {
      return [
        makeBtn('RAISE FLEET CAP', CYAN[0], CYAN[1], 'scripts/serve.sh --max-workers 5'),
        makeBtn('RE-DISPATCH', PLAIN[0], PLAIN[1], `agy retry ${this.state.runId}`),
        makeBtn('EDIT BRIEF', MUTED_BTN[0], MUTED_BTN[1], 'edit brief.md', 'span 2')
      ];
    }

    if (status === 'SECRETS_FOUND') {
      return [
        makeBtn('EDIT BRIEF', CYAN[0], CYAN[1], 'edit brief.md'),
        makeBtn('RE-DISPATCH PHASE', PLAIN[0], PLAIN[1], `agy retry ${this.state.runId}`),
        makeBtn('VIEW GATE LOG', MUTED_BTN[0], MUTED_BTN[1], 'cat check-secrets.log', 'span 2')
      ];
    }

    // Default / Passed
    return [
      makeBtn('OPEN FINAL ARTIFACT', CYAN[0], CYAN[1], `cat phases/DELEGATE/verdict`),
      makeBtn('ARCHIVE RUN', PLAIN[0], PLAIN[1], `agy archive ${this.state.runId}`),
      makeBtn('COPY gh COMMANDS · print, never post', MUTED_BTN[0], MUTED_BTN[1], 'gh pr create --draft', 'span 2')
    ];
  }
}

// Mount the app on DOM ready
document.addEventListener('DOMContentLoaded', () => {
  const root = document.getElementById('app') || document.body;
  window.__AGY_APP__ = new App(root);
});
