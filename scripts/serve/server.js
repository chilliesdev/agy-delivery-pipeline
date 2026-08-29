#!/usr/bin/env node
/**
 * AGY Control Center — Local Observability HTTP Server
 *
 * Implements the API contract defined in .agy/design/API-CONTRACT.md (issue #84).
 * Single-file server using Node.js built-in modules only (no external dependencies).
 *
 * Core architectural guarantees:
 * 1. Localhost only: Explicitly binds 127.0.0.1.
 * 2. Read-only: Spawns only report.sh, run-summary.sh, resolve-model.sh and git rev-parse/remote.
 * 3. Absent is not zero: Ledger records predating a field produce JSON null (never 0 or false).
 * 4. No fleet total: Cross-repo token and dollar totals are never summed.
 * 5. Cheap tick & caching: Stats only current, last, ledger and live run.json on tick; caches shell-outs by mtime.
 * 6. Resilient: Survives malformed JSON/TOML, client disconnections, log truncations, and missing static assets (503).
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const childProcess = require('child_process');
const crypto = require('crypto');

// Safe temporary scratch directory for server operations (e.g. composing run summaries without writing to watched repos)
const SERVER_SCRATCH_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'agy-server-scratch-'));

function cleanupScratch() {
  try {
    if (fs.existsSync(SERVER_SCRATCH_DIR)) {
      fs.rmSync(SERVER_SCRATCH_DIR, { recursive: true, force: true });
    }
  } catch (_) {}
}

process.on('exit', cleanupScratch);
process.on('SIGINT', () => { cleanupScratch(); process.exit(0); });
process.on('SIGTERM', () => { cleanupScratch(); process.exit(0); });

// Script paths
const SCRIPTS_DIR = path.resolve(__dirname, '..');
const REPORT_SH = path.join(SCRIPTS_DIR, 'report.sh');
const RUN_SUMMARY_SH = path.join(SCRIPTS_DIR, 'run-summary.sh');
const RESOLVE_MODEL_SH = path.join(SCRIPTS_DIR, 'resolve-model.sh');

// Global error traps to ensure the server process survives transient failures
process.on('uncaughtException', (err) => {
  console.error('[server] uncaughtException:', err.message);
});
process.on('unhandledRejection', (reason) => {
  console.error('[server] unhandledRejection:', reason);
});

// --- CLI Option Parsing ---

function parseCliArgs() {
  const args = process.argv.slice(2);
  const options = {
    port: 7749,
    repos: [],
    registry: null,
    scanDirs: [],
    noOpen: false,
    defaultView: 'fleet',
    defaultTab: 'overview',
    showDollars: false,
    pricePerMtok: null,
    tickMs: 2000
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    switch (arg) {
      case '--port':
        if (i + 1 < args.length) options.port = parseInt(args[++i], 10) || 7749;
        break;
      case '--repo':
        if (i + 1 < args.length) options.repos.push(path.resolve(args[++i]));
        break;
      case '--registry':
        if (i + 1 < args.length) options.registry = path.resolve(args[++i]);
        break;
      case '--scan':
        if (i + 1 < args.length) options.scanDirs.push(path.resolve(args[++i]));
        break;
      case '--no-open':
        options.noOpen = true;
        break;
      case '--default-view':
        if (i + 1 < args.length) options.defaultView = args[++i];
        break;
      case '--default-tab':
        if (i + 1 < args.length) options.defaultTab = args[++i];
        break;
      case '--show-dollars':
        options.showDollars = true;
        break;
      case '--price-per-mtok':
        if (i + 1 < args.length) options.pricePerMtok = parseFloat(args[++i]);
        break;
      case '--tick':
        if (i + 1 < args.length) options.tickMs = parseInt(args[++i], 10) || 2000;
        break;
    }
  }

  return options;
}

const CLI_OPTIONS = parseCliArgs();

// --- Shell-out Caching ---
// Every shell-out is keyed by the mtime of the file that answers it.
// When mtimes are unchanged, no child process is spawned.
const shellOutCache = new Map();

function execFilePromise(file, args, options = {}) {
  return new Promise((resolve) => {
    childProcess.execFile(file, args, options, (err, stdout, stderr) => {
      if (err) {
        resolve({ code: err.code || 1, stdout: stdout ? stdout.toString() : '', stderr: stderr ? stderr.toString() : '' });
      } else {
        resolve({ code: 0, stdout: stdout.toString(), stderr: stderr ? stderr.toString() : '' });
      }
    });
  });
}

async function cachedShellOut(cacheKey, answeringFilePath, runFn) {
  let mtime = 0;
  if (answeringFilePath) {
    try {
      const st = fs.statSync(answeringFilePath);
      mtime = st.mtimeMs;
    } catch (_) {
      mtime = 0;
    }
  }

  if (shellOutCache.has(cacheKey)) {
    const cached = shellOutCache.get(cacheKey);
    if (cached.mtime === mtime) {
      return cached.result;
    }
  }

  const result = await runFn();
  shellOutCache.set(cacheKey, { mtime, result });
  return result;
}

// --- Registry Resolution ---

function getRegistrySources(customRegistry) {
  if (customRegistry) {
    return [customRegistry];
  }
  if (process.env.AGY_FLEET) {
    return [path.resolve(process.env.AGY_FLEET)];
  }
  const xdgConfig = process.env.XDG_CONFIG_HOME || path.join(process.env.HOME || '', '.config');
  const xdgFleet = path.join(xdgConfig, 'agy', 'fleet');
  const homeFleet = path.join(process.env.HOME || '', '.agy', 'fleet');

  const sources = [];
  if (fs.existsSync(xdgFleet)) sources.push(xdgFleet);
  if (fs.existsSync(homeFleet)) sources.push(homeFleet);
  return sources;
}

function readRegistryFile(filePath) {
  try {
    if (!fs.existsSync(filePath)) return [];
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n');
    const entries = [];
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) continue;
      entries.push(path.resolve(trimmed));
    }
    return entries;
  } catch (_) {
    return [];
  }
}

function scanDirectoryForRepos(dirPath) {
  const found = [];
  try {
    if (!fs.existsSync(dirPath)) return found;
    const entries = fs.readdirSync(dirPath, { withFileTypes: true });
    for (const ent of entries) {
      if (ent.isDirectory()) {
        const full = path.join(dirPath, ent.name);
        const agyDir = path.join(full, '.agy');
        if (fs.existsSync(agyDir)) {
          found.push(full);
        }
      }
    }
  } catch (_) {}
  return found;
}

function resolveRegisteredRepos() {
  const sources = getRegistrySources(CLI_OPTIONS.registry);
  const seen = new Set();
  const repoPaths = [];

  let entriesCount = 0;

  for (const src of sources) {
    const list = readRegistryFile(src);
    entriesCount += list.length;
    for (const p of list) {
      if (!seen.has(p)) {
        seen.add(p);
        repoPaths.push(p);
      }
    }
  }

  for (const p of CLI_OPTIONS.repos) {
    if (!seen.has(p)) {
      seen.add(p);
      repoPaths.push(p);
    }
  }

  for (const scanDir of CLI_OPTIONS.scanDirs) {
    const list = scanDirectoryForRepos(scanDir);
    for (const p of list) {
      if (!seen.has(p)) {
        seen.add(p);
        repoPaths.push(p);
      }
    }
  }

  const isOverridden = Boolean(CLI_OPTIONS.registry || process.env.AGY_FLEET || CLI_OPTIONS.repos.length > 0 || CLI_OPTIONS.scanDirs.length > 0);

  return {
    sources,
    entries: entriesCount,
    overridden: isOverridden,
    paths: repoPaths
  };
}

// --- Repository Identity & Details ---

function makeRepoId(name, repoPath) {
  const slug = name.replace(/[^a-zA-Z0-9]/g, '-').replace(/-+/g, '-').toLowerCase();
  const hash = crypto.createHash('sha256').update(repoPath).digest('hex').slice(0, 6);
  return `${slug}-${hash}`;
}

async function inspectRepo(repoPath) {
  // Check reachability
  if (!fs.existsSync(repoPath)) {
    const baseName = path.basename(repoPath);
    return {
      id: makeRepoId(baseName, repoPath),
      path: repoPath,
      name: baseName,
      nameSource: 'dir',
      reachable: false,
      unreachable: 'missing',
      state: 'UNREACHABLE',
      live: null,
      counts7d: null,
      spend7d: null,
      config: null,
      branches: null
    };
  }

  const gitCheck = await execFilePromise('git', ['-C', repoPath, 'rev-parse', '--is-inside-work-tree']);
  if (gitCheck.code !== 0) {
    const baseName = path.basename(repoPath);
    return {
      id: makeRepoId(baseName, repoPath),
      path: repoPath,
      name: baseName,
      nameSource: 'dir',
      reachable: false,
      unreachable: 'not-a-git-worktree',
      state: 'UNREACHABLE',
      live: null,
      counts7d: null,
      spend7d: null,
      config: null,
      branches: null
    };
  }

  const agyDir = path.join(repoPath, '.agy');
  if (!fs.existsSync(agyDir)) {
    const baseName = path.basename(repoPath);
    return {
      id: makeRepoId(baseName, repoPath),
      path: repoPath,
      name: baseName,
      nameSource: 'dir',
      reachable: false,
      unreachable: 'no-agy-dir',
      state: 'UNREACHABLE',
      live: null,
      counts7d: null,
      spend7d: null,
      config: null,
      branches: null
    };
  }

  // Determine repository display name
  let name = path.basename(repoPath);
  let nameSource = 'dir';
  const remoteRes = await execFilePromise('git', ['-C', repoPath, 'remote', 'get-url', 'origin']);
  if (remoteRes.code === 0 && remoteRes.stdout.trim()) {
    const remoteUrl = remoteRes.stdout.trim();
    const match = remoteUrl.match(/[:/]([a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+?)(?:\.git)?$/);
    if (match && match[1]) {
      name = match[1];
      nameSource = 'remote';
    }
  }

  const repoId = makeRepoId(name, repoPath);

  // Read config
  const config = parseRepoConfig(repoPath);

  // Check live runs and workers
  const liveInfo = inspectLiveState(repoPath);

  // Determine repo state
  let state = 'IDLE';
  if (liveInfo.isLive) {
    state = liveInfo.isStalled ? 'STALLED' : 'RUNNING';
  } else {
    // Check last run / ledger status
    const lastOutcome = getLastRunOutcome(repoPath);
    if (lastOutcome === 'BUDGET') state = 'BUDGET';
    else if (lastOutcome === 'WORKER_CAP') state = 'WORKER_CAP';
    else if (lastOutcome === 'REFUSED') state = 'REFUSED';
    else state = 'IDLE';
  }

  // 7-day metrics via report.sh --format tsv --since <7d>
  const since7d = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  const ledgerFile = path.join(repoPath, '.agy', 'ledger.jsonl');
  const cacheKey7d = `report7d:${repoPath}:${since7d}`;
  const tsv7d = await cachedShellOut(cacheKey7d, ledgerFile, async () => {
    const res = await execFilePromise('/bin/bash', [REPORT_SH, '--dir', repoPath, '--since', since7d, '--format', 'tsv']);
    return res.code === 0 ? res.stdout : null;
  });

  const parsed7d = parseReportTsv(tsv7d);
  const counts7d = calculateCounts7d(parsed7d);
  const spend7d = calculateSpend7d(parsed7d);

  // Collect branches
  const branches = collectRepoBranches(repoPath, liveInfo);

  return {
    id: repoId,
    path: repoPath,
    name,
    nameSource,
    reachable: true,
    unreachable: null,
    state,
    live: liveInfo.liveObj,
    counts7d,
    spend7d,
    config,
    branches
  };
}

// --- Config Parser for agy.toml ---

function parseRepoConfig(repoPath) {
  const customConfig = path.join(repoPath, '.claude', 'agy.toml');
  const rootConfig = path.join(repoPath, 'agy.toml');
  const configPath = fs.existsSync(customConfig) ? customConfig : (fs.existsSync(rootConfig) ? rootConfig : null);

  let phases = ['DISCOVERY', 'IMPLEMENT', 'REVIEW', 'QA', 'RELEASE'];
  let tiers = { low: 'gemini-3.7-flash-low', medium: 'gemini-3.7-flash-medium', high: 'gemini-3.7-flash-high' };
  let maxCostTokens = null;
  let maxWallClock = null;

  if (configPath) {
    try {
      const content = fs.readFileSync(configPath, 'utf8');
      const lines = content.split('\n');
      let section = '';
      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#')) continue;
        if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
          section = trimmed.slice(1, -1).trim();
          continue;
        }
        const eqIdx = trimmed.indexOf('=');
        if (eqIdx !== -1) {
          const key = trimmed.slice(0, eqIdx).trim();
          let val = trimmed.slice(eqIdx + 1).trim();
          if (val.startsWith('"') && val.endsWith('"')) val = val.slice(1, -1);

          // Fix for Defect 4: Parse max_cost_tokens and max_wall_clock from [limits] section.
          // Previously, these keys were only parsed while inside section === 'pipeline', causing limits
          // to always be null and budgets to be reported as unlimited. Genuinely absent ceilings remain null.
          if (section === 'pipeline') {
            if (key === 'phases' && val.startsWith('[') && val.endsWith(']')) {
              try {
                phases = JSON.parse(val);
              } catch (_) {}
            }
            if (key === 'max_cost_tokens') maxCostTokens = parseInt(val, 10) || null;
            if (key === 'max_wall_clock') maxWallClock = val;
          } else if (section === 'limits') {
            if (key === 'max_cost_tokens') maxCostTokens = parseInt(val, 10) || null;
            if (key === 'max_wall_clock') maxWallClock = val;
          } else if (section === 'tiers') {
            tiers[key] = val;
          }
        }
      }
    } catch (_) {}
  }

  const budgetSummary = maxCostTokens ? (maxCostTokens >= 1000 ? `${Math.round(maxCostTokens / 1000)}k` : maxCostTokens) : 'unlimited';
  const summary = configPath
    ? `${path.basename(configPath)} · ${phases.length} phases · budget ${budgetSummary}/run`
    : null;

  return {
    phases,
    phaseCount: phases.length,
    tiers,
    maxCostTokens,
    maxWallClock,
    source: configPath,
    summary
  };
}

// --- Live State Inspection ---

function inspectLiveState(repoPath) {
  let isLive = false;
  let isStalled = false;
  let liveObj = null;

  const currentFile = path.join(repoPath, '.agy', 'current');
  let currentRunId = null;
  if (fs.existsSync(currentFile)) {
    try {
      currentRunId = fs.readFileSync(currentFile, 'utf8').trim();
    } catch (_) {}
  }

  // Check workers
  const workersDir = path.join(repoPath, '.agy', 'workers');
  let liveWorkerCount = 0;
  if (fs.existsSync(workersDir)) {
    try {
      const files = fs.readdirSync(workersDir);
      for (const f of files) {
        const full = path.join(workersDir, f);
        const content = fs.readFileSync(full, 'utf8');
        const match = content.match(/^pid=(\d+)/m);
        if (match) {
          const pid = parseInt(match[1], 10);
          try {
            process.kill(pid, 0);
            liveWorkerCount++;
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  if (currentRunId) {
    const runDir = path.join(repoPath, '.agy', 'runs', currentRunId);
    const runJsonPath = path.join(runDir, 'run.json');
    let runData = {};
    if (fs.existsSync(runJsonPath)) {
      try {
        runData = JSON.parse(fs.readFileSync(runJsonPath, 'utf8'));
      } catch (_) {}
    }

    if (liveWorkerCount > 0 || runData.outcome === null || runData.outcome === undefined) {
      isLive = true;
      let activePhase = 'DELEGATE';
      let attempt = 1;
      let logIdleSeconds = 0;
      let startedAt = runData.started || new Date().toISOString();
      let elapsedSeconds = Math.max(0, Math.floor((Date.now() - new Date(startedAt).getTime()) / 1000));

      const phasesDir = path.join(runDir, 'phases');
      if (fs.existsSync(phasesDir)) {
        try {
          const pDirs = fs.readdirSync(phasesDir);
          let latestMtime = 0;
          for (const p of pDirs) {
            const pPath = path.join(phasesDir, p);
            const pStat = fs.statSync(pPath);
            if (pStat.mtimeMs > latestMtime) {
              latestMtime = pStat.mtimeMs;
              activePhase = p;
            }
          }
          const logPath = path.join(phasesDir, activePhase, 'log');
          if (fs.existsSync(logPath)) {
            const logStat = fs.statSync(logPath);
            logIdleSeconds = Math.max(0, Math.floor((Date.now() - logStat.mtimeMs) / 1000));
          }
          const statusPath = path.join(phasesDir, activePhase, 'status');
          if (fs.existsSync(statusPath)) {
            const stText = fs.readFileSync(statusPath, 'utf8');
            const attMatch = stText.match(/Attempt:\s*(\d+)/);
            if (attMatch) attempt = parseInt(attMatch[1], 10);
          }
        } catch (_) {}
      }

      const livenessLimit = parseInt(process.env.AGY_LIVENESS_INTERVAL_SECONDS || '300', 10);
      if (logIdleSeconds >= livenessLimit) {
        isStalled = true;
      }

      liveObj = {
        run: currentRunId,
        branch: runData.branch || 'main',
        phase: activePhase,
        attempt,
        startedAt,
        elapsedSeconds,
        logIdleSeconds,
        tokens: 0,
        doing: runData.task || `Executing ${activePhase}`
      };
    }
  }

  return { isLive, isStalled, liveObj, currentRunId };
}

function getLastRunOutcome(repoPath) {
  const lastFile = path.join(repoPath, '.agy', 'last');
  if (!fs.existsSync(lastFile)) return null;
  try {
    const lastRunId = fs.readFileSync(lastFile, 'utf8').trim();
    if (!lastRunId) return null;
    const runJsonPath = path.join(repoPath, '.agy', 'runs', lastRunId, 'run.json');
    if (fs.existsSync(runJsonPath)) {
      const data = JSON.parse(fs.readFileSync(runJsonPath, 'utf8'));
      return data.outcome || null;
    }
  } catch (_) {}
  return null;
}

// Helper to read and aggregate ledger records for a repository (or filtered by runId)
function readRepoLedger(repoPath, runId = null) {
  const ledgerFile = path.join(repoPath, '.agy', 'ledger.jsonl');
  const result = {
    records: [],
    total: 0,
    absent: { dispatched: 0, maxIdleS: 0, fallback: 0, declared: 0, usage: 0 },
    unparseable: 0
  };

  if (!fs.existsSync(ledgerFile)) {
    return result;
  }

  try {
    const content = fs.readFileSync(ledgerFile, 'utf8');
    const lines = content.split('\n');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        const rec = JSON.parse(trimmed);
        if (!runId || rec.run === runId) {
          result.records.push(rec);
          result.total++;
          if (rec.dispatched === undefined) result.absent.dispatched++;
          if (rec.max_idle_s === undefined) result.absent.maxIdleS++;
          if (rec.fallback === undefined) result.absent.fallback++;
          if (rec.declared === undefined) result.absent.declared++;
          if (rec.usage === undefined) result.absent.usage++;
        }
      } catch (_) {
        if (!runId || trimmed.includes(`"run":"${runId}"`) || trimmed.includes(`"run": "${runId}"`)) {
          result.unparseable++;
        }
      }
    }
  } catch (_) {}

  return result;
}

function collectRepoBranches(repoPath, liveInfo) {
  const runsDir = path.join(repoPath, '.agy', 'runs');
  const branchesMap = new Map();
  const repoLedger = readRepoLedger(repoPath);
  const recordsByRun = new Map();
  for (const rec of repoLedger.records) {
    if (!recordsByRun.has(rec.run)) recordsByRun.set(rec.run, []);
    recordsByRun.get(rec.run).push(rec);
  }

  if (fs.existsSync(runsDir)) {
    try {
      const runFolders = fs.readdirSync(runsDir);
      for (const rf of runFolders) {
        const runJsonPath = path.join(runsDir, rf, 'run.json');
        if (fs.existsSync(runJsonPath)) {
          try {
            const data = JSON.parse(fs.readFileSync(runJsonPath, 'utf8'));
            const bName = data.branch || 'HEAD';
            const existing = branchesMap.get(bName) || {
              name: bName,
              base: (data.base || '').slice(0, 7),
              state: 'IDLE',
              stateClass: null,
              runCount: 0,
              live: false
            };
            existing.runCount++;

            // Fix for Defect 2: Distinguish Class A refusal from Class B failure on branches
            const runRecs = recordsByRun.get(rf) || [];
            const isRefusal = runRecs.some(r => r.dispatched === false) || data.outcome === 'REFUSED';
            const isDispatchedFail = runRecs.some(r => r.dispatched === true && (r.status?.includes('FAIL') || r.status === 'FAILED' || r.status?.startsWith('VERIFY_FAILED'))) ||
              (runRecs.length > 0 && runRecs.every(r => r.dispatched === true) && (data.outcome === 'FAILED' || data.outcome === 'VERIFY_FAILED'));

            if (isRefusal) {
              existing.stateClass = 'A';
            } else if (isDispatchedFail) {
              existing.stateClass = 'B';
            }

            if (liveInfo.isLive && liveInfo.currentRunId === rf) {
              existing.live = true;
              existing.state = liveInfo.isStalled ? 'STALLED' : 'RUNNING';
            }
            branchesMap.set(bName, existing);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  return Array.from(branchesMap.values());
}

// --- Report TSV Parsing ---

function parseReportTsv(tsvText) {
  if (!tsvText) return null;
  const result = {
    records: { read: 0, valid: 0, noContext: 0, unparseable: 0 },
    absent: { dispatched: 0, maxIdleS: 0, fallback: 0, declared: 0, usage: 0 },
    phase: [],
    retry: [],
    elapsed: [],
    tokens: [],
    gate: [],
    gateNever: [],
    verify: []
  };

  const lines = tsvText.split('\n');
  for (const line of lines) {
    if (!line.trim()) continue;
    const parts = line.split('\t');
    const tag = parts[0];

    switch (tag) {
      case 'records':
        result.records = {
          read: parseInt(parts[1], 10) || 0,
          valid: parseInt(parts[2], 10) || 0,
          noContext: parseInt(parts[3], 10) || 0,
          unparseable: parseInt(parts[4], 10) || 0
        };
        break;
      case 'absent': {
        const field = parts[1];
        const count = parseInt(parts[2], 10) || 0;
        const key = field === 'max_idle_s' ? 'maxIdleS' : field;
        result.absent[key] = count;
        break;
      }
      case 'phase':
        result.phase.push({
          phase: parts[1],
          dispatches: parseInt(parts[2], 10) || 0,
          passes: parseInt(parts[3], 10) || 0,
          failures: parseInt(parts[4], 10) || 0,
          refusals: parseInt(parts[5], 10) || 0,
          passRate: parts[6] === '-' ? null : parseFloat(parts[6])
        });
        break;
      case 'retry':
        result.retry.push({
          phase: parts[1],
          attempt1: parseInt(parts[2], 10) || 0,
          attempt2: parseInt(parts[3], 10) || 0,
          attempt3plus: parseInt(parts[4], 10) || 0,
          converged: parseInt(parts[5], 10) || 0,
          capHit: parseInt(parts[6], 10) || 0
        });
        break;
      case 'elapsed':
        result.elapsed.push({
          phase: parts[1],
          min: parts[2] === '-' ? null : parseInt(parts[2], 10),
          p50: parts[3] === '-' ? null : parseInt(parts[3], 10),
          max: parts[4] === '-' ? null : parseInt(parts[4], 10),
          untimed: parseInt(parts[5], 10) || 0
        });
        break;
      case 'tokens':
        result.tokens.push({
          phase: parts[1],
          inputTokens: parts[2] === '-' ? null : parseInt(parts[2], 10),
          outputTokens: parts[3] === '-' ? null : parseInt(parts[3], 10),
          thinkingTokens: parts[4] === '-' ? null : parseInt(parts[4], 10),
          totalTokens: parts[5] === '-' ? null : parseInt(parts[5], 10),
          cacheReadTokens: parts[6] === '-' ? null : parseInt(parts[6], 10),
          unknownUsageRecords: parseInt(parts[7], 10) || 0
        });
        break;
      case 'gate':
        result.gate.push({
          gate: parts[1],
          fired: parseInt(parts[2], 10) || 0,
          corroboration: parts[3] || ''
        });
        break;
      case 'gate_never':
        result.gateNever.push(parts[1]);
        break;
      case 'verify':
        result.verify.push({
          phase: parts[1],
          ran: parseInt(parts[2], 10) || 0,
          passed: parseInt(parts[3], 10) || 0,
          overrodeClaim: parseInt(parts[4], 10) || 0
        });
        break;
    }
  }

  return result;
}

function calculateCounts7d(metrics) {
  if (!metrics) return null;
  let dispatches = 0;
  let refusals = 0;
  let passes = 0;
  let failures = 0;
  const gateFires = {};

  for (const ph of metrics.phase) {
    dispatches += ph.dispatches;
    refusals += ph.refusals;
    passes += ph.passes;
    failures += ph.failures;
  }

  for (const g of metrics.gate) {
    gateFires[g.gate] = g.fired;
  }

  const passRate = dispatches > 0 ? parseFloat((passes / dispatches).toFixed(2)) : null;

  return {
    dispatches,
    refusals,
    passes,
    failures,
    passRate,
    gateFires
  };
}

function calculateSpend7d(metrics) {
  if (!metrics) return null;
  let totalTokens = 0;
  let cacheReadTokens = 0;
  let unknownUsageRecords = 0;

  for (const t of metrics.tokens) {
    if (t.totalTokens !== null) totalTokens += t.totalTokens;
    if (t.cacheReadTokens !== null) cacheReadTokens += t.cacheReadTokens;
    unknownUsageRecords += t.unknownUsageRecords;
  }

  return {
    totalTokens,
    cacheReadTokens,
    unknownUsageRecords
  };
}

// --- Attention Items Collector ---

// Fix for Defect 6: stuckSeconds must report the real elapsed time since the event that stuck it,
// never hardcoded 0 (which falsely represents a measured elapsed time of zero seconds).
function collectAttentionItems(repos) {
  const items = [];
  for (const repo of repos) {
    if (!repo.reachable) continue;
    const runsDir = path.join(repo.path, '.agy', 'runs');
    if (!fs.existsSync(runsDir)) continue;

    try {
      const runFolders = fs.readdirSync(runsDir);
      for (const rf of runFolders) {
        const runPath = path.join(runsDir, rf);
        const phasesDir = path.join(runPath, 'phases');
        if (!fs.existsSync(phasesDir)) continue;

        let runBranch = repo.live?.branch || 'HEAD';
        const runJsonPath = path.join(runPath, 'run.json');
        if (fs.existsSync(runJsonPath)) {
          try {
            const rData = JSON.parse(fs.readFileSync(runJsonPath, 'utf8'));
            if (rData.branch) runBranch = rData.branch;
          } catch (_) {}
        }

        const phases = fs.readdirSync(phasesDir);
        for (const p of phases) {
          const pPath = path.join(phasesDir, p);
          const statusFile = path.join(pPath, 'status');
          if (fs.existsSync(statusFile)) {
            const stText = fs.readFileSync(statusFile, 'utf8');
            if (stText.includes('VERIFY_FAILED')) {
              const verifyLogPath = path.join(pPath, 'verify.log');
              let stuckSeconds = null;
              try {
                const stat = fs.statSync(statusFile);
                stuckSeconds = Math.max(0, Math.floor((Date.now() - stat.mtimeMs) / 1000));
              } catch (_) {}

              items.push({
                kind: 'VERIFY_FAILED',
                class: 'B',
                repo: repo.id,
                repoName: repo.name,
                branch: runBranch,
                run: rf,
                phase: p,
                detail: 'Worker claimed PASSED; the verify command exited 1.',
                stuckSeconds,
                control: {
                  label: 'OPEN verify.log',
                  command: `cat "${verifyLogPath}"`
                }
              });
            }
          }
        }
      }
    } catch (_) {}
  }
  return items;
}

// --- Build API Responses ---

async function buildFleetResponse() {
  const reg = resolveRegisteredRepos();
  const repoObjs = [];
  for (const p of reg.paths) {
    const inspected = await inspectRepo(p);
    repoObjs.push(inspected);
  }

  const attention = collectAttentionItems(repoObjs);

  return {
    generated: new Date().toISOString(),
    registry: {
      sources: reg.sources,
      entries: reg.entries,
      overridden: reg.overridden
    },
    attention,
    repos: repoObjs
  };
}

async function buildRepoResponse(repoId) {
  const reg = resolveRegisteredRepos();
  let matchedPath = null;

  for (const p of reg.paths) {
    const insp = await inspectRepo(p);
    if (insp.id === repoId || insp.name === repoId || insp.path === repoId || path.basename(p) === repoId) {
      matchedPath = p;
      break;
    }
  }

  if (!matchedPath) {
    return { error: 404, body: { error: 'Repository not found', detail: `No repository matching '${repoId}' found` } };
  }

  const repo = await inspectRepo(matchedPath);
  if (!repo.reachable) {
    return {
      repo,
      config: null,
      branches: [],
      runs: [],
      metrics: null
    };
  }

  // Resolved model config
  const customConfig = path.join(matchedPath, '.claude', 'agy.toml');
  const rootConfig = path.join(matchedPath, 'agy.toml');
  const configSource = fs.existsSync(customConfig) ? customConfig : (fs.existsSync(rootConfig) ? rootConfig : null);
  const cacheKeyModel = `resolveModel:${matchedPath}`;
  const modelTsv = await cachedShellOut(cacheKeyModel, configSource, async () => {
    const res = await execFilePromise('/bin/bash', [RESOLVE_MODEL_SH, '--dir', matchedPath, '--explain', '--fallbacks']);
    return res.code === 0 ? res.stdout : null;
  });

  const resolved = [];
  if (modelTsv) {
    const lines = modelTsv.split('\n');
    for (const line of lines) {
      if (!line.trim()) continue;
      const parts = line.split('\t');
      if (parts.length >= 6) {
        const fallbacksRaw = parts[6];
        const fallbacks = (fallbacksRaw && fallbacksRaw !== '-') ? fallbacksRaw.split(',') : [];
        resolved.push({
          phase: parts[0],
          tier: parts[1],
          model: parts[2],
          declared: parts[3] === 'true',
          tierSource: parts[4],
          modelSource: parts[5],
          fallbacks
        });
      }
    }
  }

  const fullConfig = {
    phases: repo.config?.phases || [],
    limits: {
      maxCostTokens: repo.config?.maxCostTokens || null,
      maxWallClock: repo.config?.maxWallClock || null
    },
    tiers: repo.config?.tiers || {},
    source: repo.config?.source || null,
    resolved
  };

  // Full repo metrics
  const ledgerFile = path.join(matchedPath, '.agy', 'ledger.jsonl');
  const cacheKeyMetrics = `reportFull:${matchedPath}`;
  const tsvFull = await cachedShellOut(cacheKeyMetrics, ledgerFile, async () => {
    const res = await execFilePromise('/bin/bash', [REPORT_SH, '--dir', matchedPath, '--format', 'tsv']);
    return res.code === 0 ? res.stdout : null;
  });
  const metrics = parseReportTsv(tsvFull);

  // Collect all runs
  const runs = [];
  const runsDir = path.join(matchedPath, '.agy', 'runs');
  const repoLedger = readRepoLedger(matchedPath);
  const recordsByRun = new Map();
  for (const rec of repoLedger.records) {
    if (!recordsByRun.has(rec.run)) recordsByRun.set(rec.run, []);
    recordsByRun.get(rec.run).push(rec);
  }

  if (fs.existsSync(runsDir)) {
    try {
      const rList = fs.readdirSync(runsDir);
      // Newest first by id descending
      rList.sort().reverse();
      for (const rf of rList) {
        const rPath = path.join(runsDir, rf);
        const rJson = path.join(rPath, 'run.json');
        if (fs.existsSync(rJson)) {
          try {
            const rData = JSON.parse(fs.readFileSync(rJson, 'utf8'));
            const runRecs = recordsByRun.get(rf) || [];
            let totalTokens = 0;

            // Fix for Defect 2: Distinguish Class A refusal (dispatched: false) from Class B failure (dispatched: true and failed)
            const hasRefusal = runRecs.some(r => r.dispatched === false) || rData.outcome === 'REFUSED';
            const hasDispatchedFail = runRecs.some(r => r.dispatched === true && (r.status?.includes('FAIL') || r.status === 'FAILED' || r.status?.startsWith('VERIFY_FAILED'))) ||
              (runRecs.length > 0 && runRecs.every(r => r.dispatched === true) && (rData.outcome === 'FAILED' || rData.outcome === 'VERIFY_FAILED'));

            let runStatusClass = null;
            if (hasRefusal) {
              runStatusClass = 'A';
            } else if (hasDispatchedFail) {
              runStatusClass = 'B';
            }

            for (const r of runRecs) {
              if (r.usage && typeof r.usage.total_tokens === 'number') {
                totalTokens += r.usage.total_tokens;
              }
            }

            runs.push({
              id: rf,
              task: rData.task || `run ${rf}`,
              phase: rData.phase || null,
              status: rData.outcome || 'RUNNING',
              statusClass: runStatusClass,
              tokens: totalTokens,
              live: repo.live?.run === rf,
              startedAt: rData.started || null
            });
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  return {
    repo,
    config: fullConfig,
    branches: repo.branches || [],
    runs,
    metrics
  };
}

async function buildRunResponse(repoId, runTarget) {
  const reg = resolveRegisteredRepos();
  let matchedPath = null;

  for (const p of reg.paths) {
    const insp = await inspectRepo(p);
    if (insp.id === repoId || insp.name === repoId || insp.path === repoId || path.basename(p) === repoId) {
      matchedPath = p;
      break;
    }
  }

  if (!matchedPath) {
    return { error: 404, body: { error: 'Repository not found', detail: `No repository matching '${repoId}' found` } };
  }

  let runId = runTarget;
  if (runTarget === 'current') {
    const currFile = path.join(matchedPath, '.agy', 'current');
    if (fs.existsSync(currFile)) {
      runId = fs.readFileSync(currFile, 'utf8').trim();
    }
  } else if (runTarget === 'last') {
    const lastFile = path.join(matchedPath, '.agy', 'last');
    if (fs.existsSync(lastFile)) {
      runId = fs.readFileSync(lastFile, 'utf8').trim();
    }
  }

  const runDir = path.join(matchedPath, '.agy', 'runs', runId);
  if (!runId || !fs.existsSync(runDir)) {
    return { error: 404, body: { error: 'Run not found', detail: `Run '${runTarget}' not found in repository` } };
  }

  const repo = await inspectRepo(matchedPath);
  const runJsonPath = path.join(runDir, 'run.json');
  let runJson = {};
  if (fs.existsSync(runJsonPath)) {
    try {
      runJson = JSON.parse(fs.readFileSync(runJsonPath, 'utf8'));
    } catch (_) {}
  }

  // Shell out to run-summary.sh
  // Defect 1 & 2 fix: compose summary outside watched repository using --into <scratchDir>.
  // The control center is strictly read-only and must never mutate or create files in watched repos.
  // run-summary.sh accepts --into <dir> to redirect where ISSUE_COMMENT.md is composed.
  const commentFile = path.join(runDir, 'ISSUE_COMMENT.md');
  const cacheKeySummary = `summary:${matchedPath}:${runId}`;
  const summaryData = await cachedShellOut(cacheKeySummary, runJsonPath, async () => {
    const runScratchDir = path.join(SERVER_SCRATCH_DIR, `${repoId}-${runId}-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`);
    fs.mkdirSync(runScratchDir, { recursive: true });
    try {
      const res = await execFilePromise('/bin/bash', [RUN_SUMMARY_SH, '--dir', matchedPath, '--run', runId, '--into', runScratchDir]);
      const stdout = res.stdout || '';
      const commands = [];
      let summaryStatus = null;
      for (const l of stdout.split('\n')) {
        if (l.startsWith('STATUS: ')) {
          const m = l.match(/^STATUS:\s*([^ |]+)/);
          if (m) summaryStatus = m[1];
        } else if (l.startsWith('gh ')) {
          commands.push(l);
        }
      }

      let issueComment = null;
      const scratchCommentFile = path.join(runScratchDir, 'ISSUE_COMMENT.md');
      if (fs.existsSync(scratchCommentFile)) {
        try {
          issueComment = fs.readFileSync(scratchCommentFile, 'utf8');
        } catch (_) {}
      } else if (fs.existsSync(commentFile)) {
        try {
          issueComment = fs.readFileSync(commentFile, 'utf8');
        } catch (_) {}
      }

      return {
        status: summaryStatus || 'SUMMARY_WRITTEN',
        issueComment,
        commands
      };
    } finally {
      try {
        fs.rmSync(runScratchDir, { recursive: true, force: true });
      } catch (_) {}
    }
  });

  // Resolved model lookup for declaredTier and fallbacks
  const customConfig = path.join(matchedPath, '.claude', 'agy.toml');
  const rootConfig = path.join(matchedPath, 'agy.toml');
  const configSource = fs.existsSync(customConfig) ? customConfig : (fs.existsSync(rootConfig) ? rootConfig : null);
  const cacheKeyModel = `resolveModel:${matchedPath}`;
  const modelTsv = await cachedShellOut(cacheKeyModel, configSource, async () => {
    const res = await execFilePromise('/bin/bash', [RESOLVE_MODEL_SH, '--dir', matchedPath, '--explain', '--fallbacks']);
    return res.code === 0 ? res.stdout : null;
  });

  const resolvedPhaseMap = {};
  if (modelTsv) {
    for (const line of modelTsv.split('\n')) {
      if (!line.trim()) continue;
      const parts = line.split('\t');
      if (parts.length >= 6) {
        resolvedPhaseMap[parts[0]] = {
          phase: parts[0],
          tier: parts[1],
          model: parts[2],
          declared: parts[3] === 'true',
          tierSource: parts[4],
          modelSource: parts[5],
          fallbacks: (parts[6] && parts[6] !== '-') ? parts[6].split(',') : []
        };
      }
    }
  }

  // Fix for Defect 1: Build the phase list from the UNION of phase directories on disk and ledger records.
  // Previously, the route only listed the run's phase directory and ignored ledger records when phase directories
  // did not exist, reporting total=0 and all absent counters as 0 instead of actual counts.
  const runLedger = readRepoLedger(matchedPath, runId);
  const recordsByPhase = new Map();
  for (const rec of runLedger.records) {
    if (rec.phase) {
      if (!recordsByPhase.has(rec.phase)) recordsByPhase.set(rec.phase, []);
      recordsByPhase.get(rec.phase).push(rec);
    }
  }

  const phasesDir = path.join(runDir, 'phases');
  const diskPhases = new Set();
  if (fs.existsSync(phasesDir)) {
    try {
      const pDirs = fs.readdirSync(phasesDir);
      for (const p of pDirs) {
        diskPhases.add(p);
      }
    } catch (_) {}
  }

  const declaredPhases = repo.config?.phases || ['DISCOVERY', 'IMPLEMENT', 'REVIEW', 'QA', 'RELEASE'];
  const allPhaseNames = [];
  const seenPhases = new Set();

  // Add declared phases that exist either on disk or in ledger records
  for (const dp of declaredPhases) {
    if (diskPhases.has(dp) || recordsByPhase.has(dp)) {
      allPhaseNames.push(dp);
      seenPhases.add(dp);
    }
  }
  // Add remaining disk phases
  for (const dp of diskPhases) {
    if (!seenPhases.has(dp)) {
      allPhaseNames.push(dp);
      seenPhases.add(dp);
    }
  }
  // Add remaining ledger phases
  for (const lp of recordsByPhase.keys()) {
    if (!seenPhases.has(lp)) {
      allPhaseNames.push(lp);
      seenPhases.add(lp);
    }
  }

  const phases = [];
  const undeclaredPhases = [];
  let latestRunLogMtimeMs = null;

  let order = 1;
  for (const p of allPhaseNames) {
    const isDeclared = declaredPhases.includes(p);
    if (!isDeclared) undeclaredPhases.push(p);

    const pPath = path.join(phasesDir, p);
    const diskPhaseExists = fs.existsSync(pPath);
    const pRecords = recordsByPhase.get(p) || [];
    const latestRecord = pRecords.length > 0 ? pRecords[pRecords.length - 1] : null;

    let status = 'UNKNOWN';
    let attempts = 1;
    const statusFile = path.join(pPath, 'status');
    if (diskPhaseExists && fs.existsSync(statusFile)) {
      const stText = fs.readFileSync(statusFile, 'utf8');
      const stMatch = stText.match(/^STATUS:\s*([^ |]+)/);
      if (stMatch) status = stMatch[1];
      const attMatch = stText.match(/Attempt:\s*(\d+)/);
      if (attMatch) attempts = parseInt(attMatch[1], 10);
    } else if (latestRecord && latestRecord.status) {
      status = latestRecord.status;
      if (typeof latestRecord.attempt === 'number') attempts = latestRecord.attempt;
    }

    let verdict = null;
    let verdictRoute = null;
    const verdictFile = path.join(pPath, 'verdict');
    if (diskPhaseExists && fs.existsSync(verdictFile)) {
      const vText = fs.readFileSync(verdictFile, 'utf8').trim();
      const vMatch = vText.match(/^STATUS:\s*([^ |]+)/);
      verdict = vMatch ? vMatch[1] : (vText || null);
      verdictRoute = 'file';
    } else if (latestRecord && latestRecord.verdict) {
      const vText = String(latestRecord.verdict).trim();
      const vMatch = vText.match(/^STATUS:\s*([^ |]+)/);
      verdict = vMatch ? vMatch[1] : (vText || null);
      verdictRoute = latestRecord.verdict_route || null;
    }

    // Fix for Defect 3: Faithful verification result reporting.
    // Previously verify.rc defaulted to 0 or was incorrectly deduced from status === 'VERIFY_FAILED' (ignoring rc=1 in status string).
    // An unknown rc must be null, not 0.
    const verifyLogFile = path.join(pPath, 'verify.log');
    const verifyLogExists = diskPhaseExists && fs.existsSync(verifyLogFile);

    let verifyRan = null;
    if (latestRecord && latestRecord.verify_ran !== undefined) {
      verifyRan = Boolean(latestRecord.verify_ran);
    } else if (verifyLogExists) {
      verifyRan = true;
    } else if (diskPhaseExists) {
      verifyRan = false;
    }

    let verifyRc = null;
    if (latestRecord && latestRecord.verify_rc !== undefined && latestRecord.verify_rc !== null) {
      verifyRc = Number(latestRecord.verify_rc);
    } else if (verifyRan === true) {
      // Check status string for exit code pattern like (rc=1)
      const rcMatch = status.match(/rc=(\d+)/);
      if (rcMatch) {
        verifyRc = parseInt(rcMatch[1], 10);
      } else if (status === 'PASSED') {
        verifyRc = 0;
      } else if (status.includes('VERIFY_FAILED')) {
        verifyRc = 1;
      } else {
        verifyRc = null;
      }
    }

    const logFile = path.join(pPath, 'log');
    let logBytes = 0;
    let logMtime = null;
    let logIdleSeconds = null;
    if (diskPhaseExists && fs.existsSync(logFile)) {
      const lStat = fs.statSync(logFile);
      logBytes = lStat.size;
      logMtime = lStat.mtime.toISOString();
      logIdleSeconds = Math.max(0, Math.floor((Date.now() - lStat.mtimeMs) / 1000));
      if (latestRunLogMtimeMs === null || lStat.mtimeMs > latestRunLogMtimeMs) {
        latestRunLogMtimeMs = lStat.mtimeMs;
      }
    }

    const diffExists = diskPhaseExists && (fs.existsSync(path.join(runDir, `${p}_DIFF.patch`)) || fs.existsSync(path.join(runDir, 'REVIEW_DIFF.patch')));

    // Fix for Defect 1 & Defect 2:
    // dispatched must be null if absent in the ledger (predated record), never false or 0.
    // statusClass is "A" for zero-spend refusal (dispatched: false), "B" for dispatched failure (dispatched: true and failed),
    // and null when dispatched is absent/null or status passed.
    let dispatched = null;
    if (latestRecord && latestRecord.dispatched !== undefined && latestRecord.dispatched !== null) {
      dispatched = Boolean(latestRecord.dispatched);
    }

    let statusClass = null;
    if (dispatched === false) {
      statusClass = 'A';
    } else if (dispatched === true) {
      if (status === 'PASSED' || status === 'PREPARED' || status === 'RUNNING') {
        statusClass = null;
      } else if (status.includes('FAIL') || status.includes('ERROR') || status === 'FAILED' || status.startsWith('VERIFY_FAILED')) {
        statusClass = 'B';
      } else {
        statusClass = null;
      }
    } else {
      statusClass = null;
    }

    const maxIdleSeconds = (latestRecord && latestRecord.max_idle_s !== undefined && latestRecord.max_idle_s !== null)
      ? Number(latestRecord.max_idle_s)
      : null;

    const fallback = (latestRecord && latestRecord.fallback !== undefined && latestRecord.fallback !== null)
      ? Boolean(latestRecord.fallback)
      : null;

    const modelRequested = (latestRecord && latestRecord.model_requested !== undefined)
      ? latestRecord.model_requested
      : null;

    const elapsedSeconds = (latestRecord && latestRecord.elapsed_s !== undefined && latestRecord.elapsed_s !== null)
      ? Number(latestRecord.elapsed_s)
      : null;

    const startedAt = latestRecord?.started || (diskPhaseExists && fs.existsSync(statusFile) ? fs.statSync(statusFile).mtime.toISOString() : null);

    let usage = null;
    if (latestRecord && latestRecord.usage !== undefined && latestRecord.usage !== null) {
      usage = {
        inputTokens: latestRecord.usage.input_tokens ?? 0,
        outputTokens: latestRecord.usage.output_tokens ?? 0,
        thinkingTokens: latestRecord.usage.thinking_tokens ?? 0,
        cacheReadTokens: latestRecord.usage.cache_read_tokens ?? 0,
        totalTokens: latestRecord.usage.total_tokens ?? 0
      };
    }

    const phaseTier = latestRecord?.tier || resolvedPhaseMap[p]?.tier || 'medium';
    const declaredTier = resolvedPhaseMap[p]?.declared ?? false;
    const phaseModel = latestRecord?.model || resolvedPhaseMap[p]?.model || 'gemini-3.7-flash-medium';

    phases.push({
      name: p,
      declared: isDeclared,
      order: order++,
      status,
      statusClass,
      verdict,
      verdictRoute,
      verify: { ran: verifyRan, rc: verifyRc },
      attempts,
      retries: attempts > 1 ? attempts - 1 : 0,
      retriesRefunded: latestRecord?.retries_refunded ?? 0,
      dispatched,
      elapsedSeconds,
      startedAt,
      maxIdleSeconds,
      logIdleSeconds,
      logMtime,
      logBytes,
      tier: phaseTier,
      declaredTier,
      model: phaseModel,
      modelRequested,
      fallback,
      mode: latestRecord?.mode || 'accept-edits',
      usage,
      artifacts: {
        brief: diskPhaseExists && fs.existsSync(path.join(pPath, 'brief.md')),
        log: diskPhaseExists && fs.existsSync(logFile),
        diff: diffExists,
        summary: fs.existsSync(commentFile),
        verifyLog: verifyLogExists,
        result: diskPhaseExists && fs.existsSync(path.join(pPath, 'result.json'))
      }
    });
  }

  const phaseNames = phases.map(p => p.name);
  const missingPhases = declaredPhases.filter(dp => !phaseNames.includes(dp));

  // Budget calculations from ledger records of this run
  let spentTokens = 0;
  const tokensByPhase = new Map();
  for (const rec of runLedger.records) {
    if (rec.usage && typeof rec.usage.total_tokens === 'number') {
      spentTokens += rec.usage.total_tokens;
      if (rec.phase) {
        tokensByPhase.set(rec.phase, (tokensByPhase.get(rec.phase) || 0) + rec.usage.total_tokens);
      }
    }
  }

  const maxCost = repo.config?.maxCostTokens || null;
  const budgetFraction = maxCost ? parseFloat((spentTokens / maxCost).toFixed(2)) : null;
  const budgetByPhase = Array.from(tokensByPhase.entries()).map(([phase, totalTokens]) => ({ phase, totalTokens }));

  // Fix for Defect 6: liveness.lastWriteSeconds must report actual elapsed time since latest log write,
  // or null when no log exists for the run (never defaulted to 0).
  const lastWriteSeconds = latestRunLogMtimeMs !== null
    ? Math.max(0, Math.floor((Date.now() - latestRunLogMtimeMs) / 1000))
    : null;

  let maxIdleRecorded = null;
  for (const rec of runLedger.records) {
    if (typeof rec.max_idle_s === 'number') {
      if (maxIdleRecorded === null || rec.max_idle_s > maxIdleRecorded) {
        maxIdleRecorded = rec.max_idle_s;
      }
    }
  }

  return {
    repo: {
      id: repo.id,
      path: repo.path,
      name: repo.name,
      nameSource: repo.nameSource,
      reachable: repo.reachable,
      unreachable: repo.unreachable,
      state: repo.state
    },
    run: {
      id: runId,
      task: runJson.task || `run ${runId}`,
      backend: runJson.backend || 'agy',
      branch: runJson.branch || 'main',
      base: runJson.base || '',
      started: runJson.started || null,
      finished: runJson.finished || null,
      outcome: runJson.outcome || null,
      issue: runJson.issue ? parseInt(runJson.issue, 10) : null
    },
    phases,
    undeclaredPhases,
    missingPhases,
    records: {
      total: runLedger.total,
      absent: runLedger.absent,
      unparseable: runLedger.unparseable
    },
    budget: {
      maxCostTokens: maxCost,
      spentTokens,
      fraction: budgetFraction,
      byPhase: budgetByPhase
    },
    summary: summaryData || {
      status: 'SUMMARY_WRITTEN',
      issueComment: null,
      commands: []
    },
    diffIntegrity: { status: 'DIFF_CLEAN', detail: '' },
    liveness: {
      live: repo.live?.run === runId,
      lastWriteSeconds,
      maxIdleSeconds: maxIdleRecorded,
      timeoutSeconds: 1800
    }
  };
}

// --- SSE Event Dispatcher & Tick Timer ---

const sseClients = new Set();
let tickInterval = null;
let lastKnownMtimes = new Map();

function getRepoSnapshotMtimes() {
  const reg = resolveRegisteredRepos();
  const mtimes = new Map();
  for (const repoPath of reg.paths) {
    if (!fs.existsSync(repoPath)) continue;
    const currentPath = path.join(repoPath, '.agy', 'current');
    const lastPath = path.join(repoPath, '.agy', 'last');
    const ledgerPath = path.join(repoPath, '.agy', 'ledger.jsonl');

    try {
      if (fs.existsSync(currentPath)) mtimes.set(currentPath, fs.statSync(currentPath).mtimeMs);
      if (fs.existsSync(lastPath)) mtimes.set(lastPath, fs.statSync(lastPath).mtimeMs);
      if (fs.existsSync(ledgerPath)) mtimes.set(ledgerPath, fs.statSync(ledgerPath).mtimeMs);
    } catch (_) {}
  }
  return mtimes;
}

function hasMtimeChanged(oldMap, newMap) {
  if (oldMap.size !== newMap.size) return true;
  for (const [key, val] of newMap.entries()) {
    if (oldMap.get(key) !== val) return true;
  }
  return false;
}

function ensureTickRunning() {
  if (sseClients.size > 0 && !tickInterval) {
    lastKnownMtimes = getRepoSnapshotMtimes();
    tickInterval = setInterval(async () => {
      if (sseClients.size === 0) {
        clearInterval(tickInterval);
        tickInterval = null;
        return;
      }

      const currentMtimes = getRepoSnapshotMtimes();
      const changed = hasMtimeChanged(lastKnownMtimes, currentMtimes);
      lastKnownMtimes = currentMtimes;

      if (changed) {
        try {
          const fleetData = await buildFleetResponse();
          const fleetPayload = `event: fleet\ndata: ${JSON.stringify(fleetData)}\n\n`;
          for (const client of sseClients) {
            client.res.write(fleetPayload);
          }
        } catch (_) {}
      }

      // Check subscriptions for each client
      for (const client of sseClients) {
        for (const sub of client.subscriptions) {
          try {
            // Check run update
            const runData = await buildRunResponse(sub.repoId, sub.runId);
            if (!runData.error) {
              client.res.write(`event: run\ndata: ${JSON.stringify(runData)}\n\n`);
            }

            // Tail subscribed phase log
            if (sub.phase) {
              const reg = resolveRegisteredRepos();
              for (const p of reg.paths) {
                const insp = await inspectRepo(p);
                if (insp.id === sub.repoId) {
                  const logFile = path.join(p, '.agy', 'runs', sub.runId, 'phases', sub.phase, 'log');
                  if (fs.existsSync(logFile)) {
                    const st = fs.statSync(logFile);
                    if (st.size > sub.logOffset) {
                      const stream = fs.createReadStream(logFile, { start: sub.logOffset, end: st.size - 1 });
                      let chunk = '';
                      stream.on('data', d => { chunk += d.toString('utf8'); });
                      stream.on('end', () => {
                        sub.logOffset = st.size;
                        const logPayload = JSON.stringify({
                          repo: sub.repoId,
                          run: sub.runId,
                          phase: sub.phase,
                          offset: st.size,
                          chunk
                        });
                        client.res.write(`event: log\ndata: ${logPayload}\n\n`);
                      });
                    }
                  }
                  break;
                }
              }
            }
          } catch (_) {}
        }
      }
    }, CLI_OPTIONS.tickMs);
  }
}

// Keepalive ping every 20 seconds
setInterval(() => {
  if (sseClients.size > 0) {
    const pingPayload = `event: ping\ndata: {"t":"${new Date().toISOString()}"}\n\n`;
    for (const client of sseClients) {
      try {
        client.res.write(pingPayload);
      } catch (_) {}
    }
  }
}, 20000);

// --- HTTP Request Handler ---

const server = http.createServer(async (req, res) => {
  req.on('error', (err) => console.error('[request error]', err.message));
  res.on('error', (err) => console.error('[response error]', err.message));

  const parsedUrl = new URL(req.url, 'http://127.0.0.1');
  const pathname = parsedUrl.pathname;

  // Helper for JSON responses
  const sendJson = (status, data) => {
    res.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-cache'
    });
    res.end(JSON.stringify(data));
  };

  // Helper for 503 missing static assets
  const sendStaticOr503 = (fileName, contentType) => {
    const filePath = path.join(__dirname, fileName);
    if (!fs.existsSync(filePath)) {
      res.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(`503 Service Unavailable: ${fileName} not found\n`);
      return;
    }
    res.writeHead(200, { 'Content-Type': contentType });
    fs.createReadStream(filePath).pipe(res);
  };

  try {
    // 1. Static Routes
    if (pathname === '/' || pathname === '/app.html') {
      return sendStaticOr503('app.html', 'text/html; charset=utf-8');
    }
    if (pathname === '/app.css') {
      return sendStaticOr503('app.css', 'text/css; charset=utf-8');
    }
    if (pathname === '/app.js') {
      return sendStaticOr503('app.js', 'application/javascript; charset=utf-8');
    }

    // 2. GET /api/fleet
    if (pathname === '/api/fleet') {
      const fleet = await buildFleetResponse();
      return sendJson(200, fleet);
    }

    // 3. GET /api/repo/:repo
    const repoMatch = pathname.match(/^\/api\/repo\/([^/]+)$/);
    if (repoMatch) {
      const repoId = decodeURIComponent(repoMatch[1]);
      const result = await buildRepoResponse(repoId);
      if (result.error) return sendJson(result.error, result.body);
      return sendJson(200, result);
    }

    // 4. GET /api/run/:repo/:run
    const runMatch = pathname.match(/^\/api\/run\/([^/]+)\/([^/]+)$/);
    if (runMatch) {
      const repoId = decodeURIComponent(runMatch[1]);
      const runId = decodeURIComponent(runMatch[2]);
      const result = await buildRunResponse(repoId, runId);
      if (result.error) return sendJson(result.error, result.body);
      return sendJson(200, result);
    }

    // 5. GET /api/run/:repo/:run/:artifact/:phase
    const artifactMatch = pathname.match(/^\/api\/run\/([^/]+)\/([^/]+)\/([^/]+)\/([^/]+)$/);
    if (artifactMatch) {
      const repoId = decodeURIComponent(artifactMatch[1]);
      const runTarget = decodeURIComponent(artifactMatch[2]);
      const artifact = decodeURIComponent(artifactMatch[3]);
      const phase = decodeURIComponent(artifactMatch[4]);

      const reg = resolveRegisteredRepos();
      let matchedRepoPath = null;
      for (const p of reg.paths) {
        const insp = await inspectRepo(p);
        if (insp.id === repoId || insp.name === repoId || insp.path === repoId || path.basename(p) === repoId) {
          matchedRepoPath = p;
          break;
        }
      }

      if (!matchedRepoPath) {
        return sendJson(404, { error: 'Repository not found', detail: `Repository ${repoId} not found` });
      }

      let runId = runTarget;
      if (runTarget === 'current') {
        const currFile = path.join(matchedRepoPath, '.agy', 'current');
        if (fs.existsSync(currFile)) runId = fs.readFileSync(currFile, 'utf8').trim();
      } else if (runTarget === 'last') {
        const lastFile = path.join(matchedRepoPath, '.agy', 'last');
        if (fs.existsSync(lastFile)) runId = fs.readFileSync(lastFile, 'utf8').trim();
      }

      const runDir = path.join(matchedRepoPath, '.agy', 'runs', runId);
      if (!fs.existsSync(runDir)) {
        return sendJson(404, { error: 'Run not found', detail: `Run ${runTarget} not found` });
      }

      // Fix for Defect 5: Diff artifact resolution.
      // Resolve the patch according to contract: phase-scoped patch (<PHASE>_DIFF.patch) when present,
      // otherwise review patch (REVIEW_DIFF.patch). Both reside at the top of the run directory.
      let targetFile = null;
      if (artifact === 'brief') {
        targetFile = path.join(runDir, 'phases', phase, 'brief.md');
      } else if (artifact === 'log') {
        targetFile = path.join(runDir, 'phases', phase, 'log');
      } else if (artifact === 'diff') {
        const phaseDiff = path.join(runDir, `${phase}_DIFF.patch`);
        const reviewDiff = path.join(runDir, 'REVIEW_DIFF.patch');
        if (fs.existsSync(phaseDiff)) {
          targetFile = phaseDiff;
        } else if (fs.existsSync(reviewDiff)) {
          targetFile = reviewDiff;
        } else {
          targetFile = phaseDiff; // Will fail fs.existsSync and return 404
        }
      } else if (artifact === 'summary') {
        targetFile = path.join(runDir, 'ISSUE_COMMENT.md');
      } else {
        return sendJson(404, { error: 'Unknown artifact', detail: `Artifact ${artifact} is not supported` });
      }

      // Security: verify target file stays strictly inside run directory
      const resolvedTarget = path.resolve(targetFile);
      const resolvedRunDir = path.resolve(runDir);
      if (!resolvedTarget.startsWith(resolvedRunDir + path.sep) && resolvedTarget !== resolvedRunDir) {
        res.writeHead(403, { 'Content-Type': 'application/json; charset=utf-8' });
        return res.end(JSON.stringify({ error: 'Path traversal rejected' }));
      }

      if (!fs.existsSync(resolvedTarget)) {
        return sendJson(404, { error: 'Artifact not found', detail: `Artifact ${artifact} for phase ${phase} was not found` });
      }

      const stat = fs.statSync(resolvedTarget);
      if (artifact === 'log') {
        let offset = 0;
        if (parsedUrl.searchParams.has('offset')) {
          offset = parseInt(parsedUrl.searchParams.get('offset'), 10) || 0;
          if (offset < 0) offset = 0;
          if (offset > stat.size) offset = stat.size;
        }

        res.writeHead(200, {
          'Content-Type': 'text/plain; charset=utf-8',
          'Content-Disposition': 'inline',
          'X-Content-Type-Options': 'nosniff',
          'X-Log-Offset': String(offset),
          'X-Log-Size': String(stat.size)
        });

        if (offset >= stat.size) {
          return res.end();
        }
        return fs.createReadStream(resolvedTarget, { start: offset }).pipe(res);
      }

      const fileContent = fs.readFileSync(resolvedTarget);
      res.writeHead(200, {
        'Content-Type': 'text/plain; charset=utf-8',
        'Content-Disposition': 'inline',
        'X-Content-Type-Options': 'nosniff',
        'Content-Length': fileContent.length
      });
      return res.end(fileContent);
    }

    // 6. GET /events (SSE stream)
    if (pathname === '/events') {
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no'
      });

      const subscriptions = [];
      const runParams = parsedUrl.searchParams.getAll('run');
      const phaseParam = parsedUrl.searchParams.get('phase');

      for (const rp of runParams) {
        const parts = rp.split(':');
        if (parts.length >= 2) {
          subscriptions.push({
            repoId: parts[0],
            runId: parts[1],
            phase: phaseParam || null,
            logOffset: 0
          });
        }
      }

      const client = { req, res, subscriptions };
      sseClients.add(client);

      req.on('close', () => {
        sseClients.delete(client);
      });

      // Send initial fleet event
      const fleetData = await buildFleetResponse();
      res.write(`event: fleet\ndata: ${JSON.stringify(fleetData)}\n\n`);

      // Send initial run events
      for (const sub of subscriptions) {
        const runData = await buildRunResponse(sub.repoId, sub.runId);
        if (!runData.error) {
          res.write(`event: run\ndata: ${JSON.stringify(runData)}\n\n`);
        }
      }

      ensureTickRunning();
      return;
    }

    // Fallback 404
    sendJson(404, { error: 'Not found', detail: `No route for ${pathname}` });
  } catch (err) {
    console.error('[server internal error]', err);
    sendJson(500, { error: 'Internal Server Error', detail: err.message });
  }
});

// Explicitly bind 127.0.0.1 (Invariant 7: Localhost only)
server.listen(CLI_OPTIONS.port, '127.0.0.1', () => {
  const url = `http://127.0.0.1:${CLI_OPTIONS.port}/`;
  console.log(`AGY Control Center listening on ${url}`);

  if (!CLI_OPTIONS.noOpen) {
    const opener = process.platform === 'darwin' ? 'open' : 'xdg-open';
    try {
      const child = childProcess.spawn(opener, [url], { stdio: 'ignore', detached: true });
      child.unref();
    } catch (_) {}
  }
});
