import {
  activeWordIndexAtMs,
  flattenTimings,
  hasSegmentAudio,
  normalizeTimingPayload,
  segmentPlaybackPlan
} from './timings.js';

/**
 * Reader runtime implementation.
 * Spec source: Storytime CodeTV spec FR-031..FR-044 and
 * READER_MODE_RUNTIME_CONTRACT__SHIP_BLOCKER.md (2026-02-25).
 */

const POINTER_PUBLISH_INTERVAL_MS = 90;
const PRESENCE_HEARTBEAT_MS = 1800;
const STALE_PARTICIPANT_MS = 15000;
const SEGMENT_GAP_DEFAULT_MS = 100;

const dom = {
  stage: document.getElementById('stage'),
  openBook: document.getElementById('openBook'),
  sceneBg: document.getElementById('sceneBg'),
  sceneBox: document.getElementById('sceneBox'),
  cursorLayer: document.getElementById('cursorLayer'),
  title: document.getElementById('storyTitle'),
  meta: document.getElementById('storyMeta'),
  modeLabel: document.getElementById('modeLabel'),
  pageLabel: document.getElementById('pageLabel'),
  pageNumLeft: document.getElementById('pageNumLeft'),
  pageNumRight: document.getElementById('pageNumRight'),
  playbackLabel: document.getElementById('playbackLabel'),
  timingLabel: document.getElementById('timingLabel'),
  runtimeErrorLabel: document.getElementById('runtimeErrorLabel'),
  narration: document.getElementById('narration'),
  dialogueList: document.getElementById('dialogueList'),
  pageDots: document.getElementById('pageDots'),
  collabPill: document.getElementById('collabPill'),
  collabStatus: document.getElementById('collabStatus'),
  presenceList: document.getElementById('presenceList'),
  sidebarOverlay: document.getElementById('sidebarOverlay'),
  packConfigCard: document.getElementById('packConfigCard'),
  packUrlInput: document.getElementById('packUrlInput'),
  packConfigStatus: document.getElementById('packConfigStatus'),
  voiceVolume: document.getElementById('voiceVolume'),
  musicVolume: document.getElementById('musicVolume'),
  errorScreen: document.getElementById('errorScreen'),
  errorScreenTitle: document.getElementById('errorScreenTitle'),
  errorScreenBody: document.getElementById('errorScreenBody')
};

const voiceAudio = document.getElementById('voiceAudio');
const musicA = document.getElementById('musicA');
const musicB = document.getElementById('musicB');

/**
 * @returns {string}
 */
function randomId() {
  return Math.random().toString(36).slice(2, 10);
}

/**
 * @returns {{ id: string, name: string }}
 */
function createIdentity() {
  return {
    id: `reader-${randomId()}`,
    name: `Reader ${Math.floor(100 + Math.random() * 900)}`
  };
}

/**
 * @returns {any}
 */
function createState() {
  return {
    runtime: { tag: 'loading' },
    story: { tag: 'loading' },
    nav: { tag: 'idle', pageIndex: 0 },
    mode: { tag: 'read_alone' },
    audio: {
      tag: 'stopped',
      token: 0,
      queueToken: 0,
      active: null,
      timingsByUrl: new Map(),
      currentFlattened: null,
      currentHighlightLineId: null,
      currentGlobalOffsetMs: 0,
      warning: null,
      error: null
    },
    music: {
      tag: 'stopped',
      deck: 'a',
      activeTrackId: null,
      activeUrl: null,
      activeLoop: true,
      transitionToken: 0,
      error: null
    },
    collab: {
      tag: 'disconnected',
      backend: 'none',
      identity: createIdentity(),
      isHost: true,
      followHost: true,
      participants: new Map(),
      syncSeq: 0,
      lastAppliedSyncSeqByPeer: {},
      room: null,
      db: null,
      teardownFns: [],
      heartbeatTimer: null,
      staleSweepTimer: null,
      pointerMoveHandler: null,
      pointerLeaveHandler: null,
      lastPointerPublishAt: 0,
      error: null
    },
    ui: {
      tag: 'ready',
      transitionToken: 0,
      swipeStartX: 0
    }
  };
}

const state = createState();

/**
 * @param {unknown} value
 * @returns {string}
 */
function text(value) {
  return String(value ?? '');
}

/**
 * @param {unknown} value
 * @param {boolean} fallback
 * @returns {boolean}
 */
function parseBoolean(value, fallback) {
  if (typeof value === 'boolean') return value;

  const normalized = text(value).trim().toLowerCase();

  if (normalized === 'true' || normalized === '1' || normalized === 'yes' || normalized === 'on') {
    return true;
  }

  if (normalized === 'false' || normalized === '0' || normalized === 'no' || normalized === 'off') {
    return false;
  }

  return fallback;
}

/**
 * @param {number} value
 * @returns {number}
 */
function clampUnit(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(1, n));
}

/**
 * @param {string} html
 * @returns {string}
 */
function escapeHtml(html) {
  return text(html).replace(/[&<>"']/g, (char) => {
    if (char === '&') return '&amp;';
    if (char === '<') return '&lt;';
    if (char === '>') return '&gt;';
    if (char === '"') return '&quot;';
    return '&#39;';
  });
}

/**
 * @param {string} value
 * @returns {string}
 */
function inferSlugFromHostname(value) {
  const host = text(value).trim();
  const root = host.split('.')[0] || '';

  if (root.startsWith('storytime-')) {
    return root.replace(/^storytime-/, '');
  }

  return '';
}

/**
 * Resolves runtime config from query params and runtime-config.json.
 * Spec source: FR-048 / Reader runtime contract (2026-02-25).
 *
 * @returns {Promise<{ apiBase: string, storyId: string, storySlug: string, packUrl: string, instantAppId: string, allowPackOverride: boolean }>}
 */
async function loadRuntimeConfig() {
  const query = new URLSearchParams(window.location.search);

  let fileConfig = {};
  try {
    const response = await fetch('/runtime-config.json', { cache: 'no-store' });
    if (response.ok) {
      fileConfig = await response.json();
    }
  } catch (_error) {
    fileConfig = {};
  }

  const apiBase =
    query.get('api') ||
    text(fileConfig.apiBase) ||
    'https://storytime-api-091733.onrender.com';

  const allowPackOverride = (() => {
    const queryValue = query.get('allow_pack_override');
    if (queryValue != null) {
      return parseBoolean(queryValue, true);
    }

    return parseBoolean(fileConfig.allowPackOverride, true);
  })();

  const queryStoryId = allowPackOverride ? query.get('story_id') : null;
  const queryStorySlug = allowPackOverride ? query.get('story_slug') : null;
  const queryPackUrl = allowPackOverride ? query.get('pack') : null;

  return {
    apiBase: apiBase.replace(/\/$/, ''),
    storyId: queryStoryId || text(fileConfig.storyId) || '',
    storySlug:
      queryStorySlug ||
      text(fileConfig.storySlug) ||
      inferSlugFromHostname(window.location.hostname),
    packUrl: queryPackUrl || text(fileConfig.packUrl) || '',
    instantAppId: query.get('instant') || text(fileConfig.instantAppId) || '',
    allowPackOverride
  };
}

/**
 * @param {{ apiBase: string, storyId: string, storySlug: string, packUrl: string }} config
 * @returns {string | null}
 */
function resolvePackUrl(config) {
  if (config.packUrl) return config.packUrl;
  if (config.storyId) return `${config.apiBase}/api/stories/${encodeURIComponent(config.storyId)}/pack`;
  if (config.storySlug) return `${config.apiBase}/api/story-slugs/${encodeURIComponent(config.storySlug)}/pack`;
  return null;
}

/**
 * @param {any} payload
 */
function validateStoryPack(payload) {
  if (!payload || typeof payload !== 'object') {
    throw new Error('story_pack_invalid_payload');
  }

  if (payload.schemaVersion !== 1) {
    throw new Error('story_pack_invalid_schema_version');
  }

  if (!Array.isArray(payload.pages)) {
    throw new Error('story_pack_pages_missing');
  }
}

/**
 * @param {any} page
 * @returns {string | null}
 */
function pageSceneUrl(page) {
  const scene = page && page.scene ? page.scene : {};
  return text(scene.url || scene.imageUrl || '').trim() || null;
}

/**
 * @param {number} pageIndex
 * @returns {any | null}
 */
function pageAt(pageIndex) {
  if (state.story.tag !== 'ready') return null;
  return state.story.pack.pages[pageIndex] || null;
}

/**
 * @returns {number}
 */
function totalPages() {
  if (state.story.tag !== 'ready') return 0;
  return state.story.pack.pages.length;
}

/**
 * @param {number} nextIndex
 * @returns {number}
 */
function clampPageIndex(nextIndex) {
  const max = Math.max(0, totalPages() - 1);
  return Math.max(0, Math.min(max, Number(nextIndex) || 0));
}

/**
 * @param {string} message
 * @param {string} detail
 */
function setErrorScreen(message, detail) {
  dom.errorScreen.hidden = false;
  dom.errorScreenTitle.textContent = message;
  dom.errorScreenBody.textContent = detail;
}

/**
 * Hides the fail-safe error screen when runtime recovers.
 * Spec source: FR-031 fail-safe reader states.
 */
function clearErrorScreen() {
  dom.errorScreen.hidden = true;
  dom.errorScreenTitle.textContent = '';
  dom.errorScreenBody.textContent = '';
}

/**
 * @returns {void}
 */
function hidePackConfig() {
  dom.packConfigCard.hidden = true;
  dom.packConfigStatus.textContent = '';
}

/**
 * @param {{ prefill?: string, status?: string }} options
 * @returns {void}
 */
function showPackConfig(options = {}) {
  dom.packConfigCard.hidden = false;

  if (options.prefill != null) {
    dom.packUrlInput.value = text(options.prefill);
  }

  if (options.status != null) {
    dom.packConfigStatus.textContent = text(options.status);
  }
}

/**
 * @returns {void}
 */
function syncPackConfigVisibility() {
  if (state.runtime.tag !== 'ready') {
    hidePackConfig();
    return;
  }

  if (!state.runtime.config.allowPackOverride) {
    hidePackConfig();
    return;
  }

  showPackConfig({
    prefill: state.runtime.config.packUrl,
    status: state.runtime.config.packUrl
      ? `Using configured pack URL.`
      : 'No pack URL configured yet.'
  });
}

/**
 * @param {string | null} packUrl
 * @returns {void}
 */
function reloadWithPackQuery(packUrl) {
  const params = new URLSearchParams(window.location.search);

  if (packUrl && packUrl.trim()) {
    params.set('pack', packUrl.trim());
  } else {
    params.delete('pack');
  }

  const nextSearch = params.toString();
  const nextUrl = `${window.location.pathname}${nextSearch ? `?${nextSearch}` : ''}`;
  window.location.assign(nextUrl);
}

/**
 * @param {number | null} activeIndex
 * @param {{ text: string, words: any[] } | null} flattened
 * @param {string} displayText
 * @returns {string}
 */
function renderHighlightedText(activeIndex, flattened, displayText) {
  if (!flattened || !flattened.words.length || activeIndex == null) {
    return escapeHtml(displayText);
  }

  if (flattened.text !== displayText) {
    return escapeHtml(displayText);
  }

  let output = '';
  let cursor = 0;

  for (let index = 0; index < flattened.words.length; index += 1) {
    const word = flattened.words[index];
    if (!word) continue;

    if (word.charStart > cursor) {
      output += escapeHtml(displayText.slice(cursor, word.charStart));
    }

    const wordText = displayText.slice(word.charStart, word.charEnd);
    const className = index === activeIndex ? 'word active' : 'word';
    output += `<span class="${className}" data-word-index="${index}">${escapeHtml(wordText)}</span>`;
    cursor = word.charEnd;
  }

  if (cursor < displayText.length) {
    output += escapeHtml(displayText.slice(cursor));
  }

  return output;
}

/**
 * @returns {void}
 */
function renderScene() {
  const page = pageAt(state.nav.pageIndex);

  if (!page) {
    dom.sceneBg.style.backgroundImage = 'none';
    dom.sceneBox.innerHTML = '<div class="scene-empty">Story page is unavailable.</div>';
    return;
  }

  const sceneUrl = pageSceneUrl(page);

  if (!sceneUrl) {
    dom.sceneBg.style.backgroundImage = 'none';
    dom.sceneBox.innerHTML = '<div class="scene-empty">No scene image generated yet for this page.</div>';
    return;
  }

  dom.sceneBg.style.backgroundImage = `url('${sceneUrl.replace(/'/g, "%27")}')`;
  dom.sceneBox.innerHTML = `<img src="${escapeHtml(sceneUrl)}" alt="Story scene" />`;
}

/**
 * @returns {void}
 */
function renderNarrationAndDialogue() {
  const page = pageAt(state.nav.pageIndex);

  if (!page) {
    dom.narration.textContent = '';
    dom.dialogueList.innerHTML = '';
    return;
  }

  const narrationText = text(page.narration?.text || '');
  const narrationActive =
    state.audio.currentHighlightLineId === '__narration__' ? state.audio.currentFlattened : null;
  const narrationWordIndex = state.audio.currentHighlightLineId === '__narration__' ? state.audio.activeWordIndex ?? null : null;

  dom.narration.innerHTML = renderHighlightedText(narrationWordIndex, narrationActive, narrationText);

  const dialogue = Array.isArray(page.dialogue) ? page.dialogue : [];

  dom.dialogueList.innerHTML = dialogue
    .map((line) => {
      const active = state.audio.currentHighlightLineId === line.id;
      const flattened = active ? state.audio.currentFlattened : null;
      const activeWordIndex = active ? state.audio.activeWordIndex ?? null : null;
      const lineHtml = renderHighlightedText(activeWordIndex, flattened, text(line.text || ''));

      return `
        <article class="dialogue-line${active ? ' active' : ''}" data-line-id="${escapeHtml(line.id)}">
          <div class="dialogue-head">
            <div class="dialogue-name">${escapeHtml(line.characterName || 'Speaker')}</div>
            <button class="stone-btn" data-action="play-line" data-line-id="${escapeHtml(line.id)}">Play</button>
          </div>
          <div class="dialogue-text" id="dialogue-text-${escapeHtml(line.id)}">${lineHtml}</div>
        </article>
      `;
    })
    .join('');
}

/**
 * @returns {void}
 */
function renderDots() {
  const count = totalPages();

  dom.pageDots.innerHTML = Array.from({ length: count })
    .map((_, index) => {
      const isActive = index === state.nav.pageIndex;
      const isVisited = index < state.nav.pageIndex;
      const classes = ['candle-dot'];
      if (isActive) classes.push('active');
      if (isVisited) classes.push('visited');
      return `<button class="${classes.join(' ')}" data-action="seek-page" data-page-index="${index}" aria-label="Go to page ${index + 1}"></button>`;
    })
    .join('');
}

/**
 * @returns {void}
 */
function freshParticipants() {
  const now = Date.now();
  return [...state.collab.participants.values()].filter((peer) => now - (peer.seenAt || 0) <= STALE_PARTICIPANT_MS);
}

/**
 * @returns {{ id: string, name: string, pageIndex: number, host: boolean, cursor: { x: number, y: number } | null, seenAt: number } | null}
 */
function activeHostParticipant() {
  const hosts = freshParticipants()
    .filter((participant) => participant.host)
    .sort((a, b) => a.id.localeCompare(b.id));

  return hosts[0] || null;
}

/**
 * @returns {boolean}
 */
function shouldElectSelfHost() {
  const peers = freshParticipants();
  if (!peers.length) return true;

  const candidates = [state.collab.identity.id, ...peers.map((peer) => peer.id)].sort();
  return candidates[0] === state.collab.identity.id;
}

/**
 * @returns {void}
 */
function renderCollaboration() {
  const peers = freshParticipants();
  const host = activeHostParticipant();

  dom.collabPill.textContent = `Readers: ${peers.length + 1}`;
  dom.collabStatus.textContent =
    `You: ${state.collab.identity.name} | role: ${state.collab.isHost ? 'host' : 'guest'} | follow: ${state.collab.followHost ? 'on' : 'off'} | host: ${host ? host.name : (state.collab.isHost ? state.collab.identity.name : 'none')} | backend: ${state.collab.backend}`;

  const presenceColors = ['#c9a227', '#8b3d3a', '#2c4a6e', '#3d6b4f', '#6b4a8a'];
  dom.presenceList.innerHTML = peers.length
    ? peers
        .map((peer, i) => {
          const color = presenceColors[i % presenceColors.length];
          const staleSeconds = Math.max(0, Math.floor((Date.now() - (peer.seenAt || Date.now())) / 1000));
          const freshness = staleSeconds <= 2 ? 'here now' : `${staleSeconds}s ago`;
          return `<div class="presence-item">
            <span class="presence-dot" style="background:${color}"></span>
            <span class="presence-name">${escapeHtml(peer.name)}</span>
            <span class="presence-detail">page ${peer.pageIndex + 1}${peer.host ? ' &bull; host' : ''} &bull; ${freshness}</span>
          </div>`;
        })
        .join('')
    : '<div class="info">No collaborators yet.</div>';
}

/**
 * @returns {void}
 */
function renderCursors() {
  const peers = freshParticipants().filter(
    (peer) => peer.cursor && clampPageIndex(peer.pageIndex) === state.nav.pageIndex
  );

  dom.cursorLayer.innerHTML = peers
    .map((peer) => {
      const cursor = peer.cursor;
      return `<div class="cursor-pill" style="left:${clampUnit(cursor.x) * 100}%;top:${clampUnit(cursor.y) * 100}%">${escapeHtml(peer.name)}</div>`;
    })
    .join('');
}

/**
 * @returns {void}
 */
function renderMeta() {
  if (state.story.tag !== 'ready') {
    dom.title.textContent = 'Storytime Reader';
    dom.meta.textContent = 'Loading story...';
    dom.pageLabel.textContent = 'Page 0 / 0';
    return;
  }

  const pack = state.story.pack;
  const isNarrating = state.mode.tag === 'narrate';

  dom.title.textContent = text(pack.title || 'Storytime Reader');

  const currentSpeaker = state.audio.tag === 'playing' && state.audio.active?.speaker ? state.audio.active.speaker : '';
  const speakerInfo = currentSpeaker ? ` | Speaking: ${currentSpeaker}` : '';
  dom.meta.textContent = `Page ${state.nav.pageIndex + 1} of ${pack.pages.length}${speakerInfo}`;

  const modeLabelIcon = dom.modeLabel.querySelector('.stone-icon');
  if (modeLabelIcon) {
    modeLabelIcon.innerHTML = isNarrating ? '&#9646;&#9646;' : '&#9654;';
  }
  dom.modeLabel.classList.toggle('is-playing', state.audio.tag === 'playing');
  dom.pageLabel.textContent = `Page ${state.nav.pageIndex + 1} / ${pack.pages.length}`;

  if (dom.pageNumLeft) dom.pageNumLeft.textContent = String((state.nav.pageIndex * 2) + 1);
  if (dom.pageNumRight) dom.pageNumRight.textContent = String((state.nav.pageIndex * 2) + 2);

  const audioMessage = (() => {
    if (state.audio.tag === 'loading') return 'Voice: loading...';
    if (state.audio.tag === 'playing') {
      if (state.audio.active?.kind === 'narration') return `Voice: narration`;
      if (state.audio.active?.kind === 'dialogue') return `Voice: ${state.audio.active.speaker}`;
      return 'Voice: playing';
    }
    if (state.audio.tag === 'paused') return 'Voice: paused';
    if (state.audio.tag === 'error') return `Voice error: ${state.audio.error || 'unknown'}`;
    return 'Voice: idle';
  })();

  dom.playbackLabel.textContent = audioMessage;

  if (state.audio.warning) {
    dom.timingLabel.textContent = `Timing warning: ${state.audio.warning}`;
    dom.timingLabel.className = 'status-row warn';
  } else if (state.audio.tag === 'error') {
    dom.timingLabel.textContent = `Timing error: ${state.audio.error || 'unknown'}`;
    dom.timingLabel.className = 'status-row error';
  } else {
    dom.timingLabel.textContent = 'Timing: ready';
    dom.timingLabel.className = 'status-row success';
  }

  const runtimeMessages = [];
  let runtimeClass = 'info';

  if (state.runtime.tag === 'ready') {
    runtimeMessages.push(
      state.runtime.config.allowPackOverride
        ? 'Story source override: enabled (?pack=...)'
        : 'Story source override: locked for this deployment'
    );
  }

  if (state.collab.error) {
    runtimeMessages.push(`Collab: ${state.collab.error}`);
    runtimeClass = 'info error';
  }

  dom.runtimeErrorLabel.textContent = runtimeMessages.join(' | ');
  dom.runtimeErrorLabel.className = runtimeClass;
}

/**
 * @returns {void}
 */
function renderAll() {
  renderScene();
  renderNarrationAndDialogue();
  renderDots();
  renderMeta();
  renderCollaboration();
  renderCursors();
}

/**
 * @param {number} nextIndex
 * @param {{ reason: 'manual' | 'auto' | 'sync' | 'seek' }} options
 */
function setPageIndex(nextIndex, options) {
  const target = clampPageIndex(nextIndex);

  if (target === state.nav.pageIndex && options.reason !== 'seek') {
    return;
  }

  const direction = target > state.nav.pageIndex ? 'forward' : 'backward';
  const book = dom.openBook;

  // Animate page turn for manual navigation
  if (book && options.reason === 'manual') {
    book.classList.add(`page-turning-${direction}`);

    setTimeout(() => {
      state.nav = {
        tag: 'transitioning',
        pageIndex: target
      };

      stopVoice({ clearWarning: false });
      renderAll();

      book.classList.remove(`page-turning-${direction}`);

      queueMicrotask(() => {
        state.nav = { tag: 'idle', pageIndex: target };
        renderMeta();
      });

      publishPresence();
      publishPageSync();
      updateMusicForPage();

      if (state.mode.tag === 'narrate') {
        void playNarrateSequenceForCurrentPage({ autoAdvance: true });
      }
    }, 300);

    return;
  }

  // Non-animated transition (sync, auto, seek)
  state.nav = {
    tag: options.reason === 'seek' ? 'seeking' : 'transitioning',
    pageIndex: target
  };

  if (options.reason === 'manual' || options.reason === 'seek') {
    stopVoice({ clearWarning: false });
  }

  renderAll();
  queueMicrotask(() => {
    state.nav = { tag: 'idle', pageIndex: target };
    renderMeta();
  });

  publishPresence();
  publishPageSync();
  updateMusicForPage();

  if (state.mode.tag === 'narrate' && options.reason !== 'sync') {
    void playNarrateSequenceForCurrentPage({ autoAdvance: true });
  }
}

/**
 * @param {{ clearWarning?: boolean }} options
 */
function stopVoice(options = {}) {
  state.audio.token += 1;
  state.audio.queueToken += 1;
  voiceAudio.pause();
  voiceAudio.currentTime = 0;
  voiceAudio.removeAttribute('src');
  voiceAudio.load();

  state.audio.tag = 'stopped';
  state.audio.active = null;
  state.audio.currentFlattened = null;
  state.audio.currentHighlightLineId = null;
  state.audio.activeWordIndex = null;
  state.audio.currentGlobalOffsetMs = 0;
  state.audio.error = null;

  if (options.clearWarning !== false) {
    state.audio.warning = null;
  }

  renderAll();
}

/**
 * @returns {void}
 */
function pauseVoice() {
  if (state.audio.tag !== 'playing') return;
  voiceAudio.pause();
  state.audio.tag = 'paused';
  renderMeta();
}

/**
 * @returns {void}
 */
function resumeVoice() {
  if (state.audio.tag !== 'paused') return;

  void voiceAudio.play().then(() => {
    state.audio.tag = 'playing';
    renderMeta();
  }).catch((error) => {
    state.audio.tag = 'error';
    state.audio.error = `resume_failed:${text(error && error.message || error)}`;
    renderMeta();
  });
}

/**
 * @param {string} timingsUrl
 * @param {string} displayText
 * @returns {Promise<{ tag: 'ok', value: any } | { tag: 'error', error: string }>}
 */
async function fetchNormalizedTimings(timingsUrl, displayText) {
  const cacheKey = `${timingsUrl}::${displayText}`;
  if (state.audio.timingsByUrl.has(cacheKey)) {
    return state.audio.timingsByUrl.get(cacheKey);
  }

  const loadPromise = fetch(timingsUrl, { cache: 'force-cache' })
    .then(async (response) => {
      if (!response.ok) {
        return { tag: 'error', error: `timings_http_${response.status}` };
      }

      const payload = await response.json();
      const normalized = normalizeTimingPayload(payload, { displayText });

      if (normalized.tag === 'error') {
        return { tag: 'error', error: normalized.error };
      }

      return normalized;
    })
    .catch((error) => ({
      tag: 'error',
      error: `timings_fetch_failed:${text(error && error.message || error)}`
    }));

  state.audio.timingsByUrl.set(cacheKey, loadPromise);
  return loadPromise;
}

/**
 * @param {{ kind: 'narration' | 'dialogue', lineId: string, speaker: string, text: string, audioUrl: string, timingsUrl: string | null }} item
 * @param {number} token
 * @returns {Promise<{ tag: 'ok' } | { tag: 'error', error: string }>}
 */
async function playSingleAudioItem(item, token) {
  state.audio.tag = 'loading';
  state.audio.active = item;
  state.audio.currentHighlightLineId = item.kind === 'narration' ? '__narration__' : item.lineId;
  state.audio.activeWordIndex = null;
  state.audio.currentGlobalOffsetMs = 0;
  state.audio.currentFlattened = null;
  state.audio.warning = null;
  state.audio.error = null;
  renderAll();

  if (item.timingsUrl) {
    const timings = await fetchNormalizedTimings(item.timingsUrl, item.text);
    if (token !== state.audio.token) return { tag: 'error', error: 'audio_cancelled' };

    if (timings.tag === 'ok') {
      state.audio.currentFlattened = flattenTimings(timings.value);
    } else {
      state.audio.warning = timings.error;
      state.audio.currentFlattened = null;
    }
  }

  voiceAudio.pause();
  voiceAudio.src = item.audioUrl;
  voiceAudio.currentTime = 0;
  voiceAudio.volume = Number(dom.voiceVolume.value || 0.9);

  try {
    await voiceAudio.play();
    if (token !== state.audio.token) return { tag: 'error', error: 'audio_cancelled' };

    state.audio.tag = 'playing';
    renderMeta();

    return await new Promise((resolve) => {
      let settled = false;
      let cancellationTimer = null;

      const settle = (result) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(result);
      };

      const onEnded = () => {
        if (token !== state.audio.token) {
          settle({ tag: 'error', error: 'audio_cancelled' });
          return;
        }

        state.audio.tag = 'stopped';
        state.audio.active = null;
        state.audio.currentHighlightLineId = null;
        state.audio.currentFlattened = null;
        state.audio.activeWordIndex = null;
        state.audio.currentGlobalOffsetMs = 0;
        renderAll();
        settle({ tag: 'ok' });
      };

      const onError = () => {
        if (token !== state.audio.token) {
          settle({ tag: 'error', error: 'audio_cancelled' });
          return;
        }

        const error = 'audio_playback_failed';
        state.audio.tag = 'error';
        state.audio.error = error;
        renderMeta();
        settle({ tag: 'error', error });
      };

      const onAbort = () => {
        settle({ tag: 'error', error: 'audio_cancelled' });
      };

      const cleanup = () => {
        if (cancellationTimer) {
          window.clearInterval(cancellationTimer);
          cancellationTimer = null;
        }

        voiceAudio.removeEventListener('ended', onEnded);
        voiceAudio.removeEventListener('error', onError);
        voiceAudio.removeEventListener('abort', onAbort);
        voiceAudio.removeEventListener('emptied', onAbort);
      };

      voiceAudio.addEventListener('ended', onEnded, { once: true });
      voiceAudio.addEventListener('error', onError, { once: true });
      voiceAudio.addEventListener('abort', onAbort, { once: true });
      voiceAudio.addEventListener('emptied', onAbort, { once: true });

      cancellationTimer = window.setInterval(() => {
        if (token !== state.audio.token) {
          settle({ tag: 'error', error: 'audio_cancelled' });
        }
      }, 75);
    });
  } catch (error) {
    const details = `audio_play_failed:${text(error && error.message || error)}`;
    state.audio.tag = 'error';
    state.audio.error = details;
    renderMeta();
    return { tag: 'error', error: details };
  }
}

/**
 * @param {{ kind: 'narration' | 'dialogue', lineId: string, speaker: string, text: string, audioUrl: string, timingsUrl: string | null }} item
 * @param {number} token
 * @returns {Promise<{ tag: 'ok' } | { tag: 'error', error: string }>}
 */
async function playSegmentAudioItem(item, token) {
  if (!item.timingsUrl) {
    return { tag: 'error', error: 'segment_timings_missing' };
  }

  const timings = await fetchNormalizedTimings(item.timingsUrl, item.text);
  if (token !== state.audio.token) return { tag: 'error', error: 'audio_cancelled' };
  if (timings.tag === 'error') return { tag: 'error', error: timings.error };

  if (!hasSegmentAudio(timings.value)) {
    return { tag: 'error', error: 'segment_audio_missing' };
  }

  const flattened = flattenTimings(timings.value);
  const plan = segmentPlaybackPlan(timings.value);
  const gapMs = Number.isFinite(Number(timings.value.segmentGapMs)) ? Number(timings.value.segmentGapMs) : SEGMENT_GAP_DEFAULT_MS;

  state.audio.currentFlattened = flattened;
  state.audio.currentHighlightLineId = item.kind === 'narration' ? '__narration__' : item.lineId;
  state.audio.warning = null;
  state.audio.error = null;

  for (let index = 0; index < plan.length; index += 1) {
    const segment = plan[index];
    state.audio.currentGlobalOffsetMs = segment.startMs;
    voiceAudio.pause();
    voiceAudio.src = segment.audioUrl;
    voiceAudio.currentTime = 0;
    voiceAudio.volume = Number(dom.voiceVolume.value || 0.9);

    try {
      await voiceAudio.play();
    } catch (error) {
      return { tag: 'error', error: `segment_play_failed:${text(error && error.message || error)}` };
    }

    const ended = await new Promise((resolve) => {
      let settled = false;
      let cancellationTimer = null;

      const settle = (result) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(result);
      };

      const onEnded = () => {
        settle(true);
      };

      const onError = () => {
        settle(false);
      };

      const onAbort = () => {
        settle(false);
      };

      const cleanup = () => {
        if (cancellationTimer) {
          window.clearInterval(cancellationTimer);
          cancellationTimer = null;
        }

        voiceAudio.removeEventListener('ended', onEnded);
        voiceAudio.removeEventListener('error', onError);
        voiceAudio.removeEventListener('abort', onAbort);
        voiceAudio.removeEventListener('emptied', onAbort);
      };

      voiceAudio.addEventListener('ended', onEnded, { once: true });
      voiceAudio.addEventListener('error', onError, { once: true });
      voiceAudio.addEventListener('abort', onAbort, { once: true });
      voiceAudio.addEventListener('emptied', onAbort, { once: true });

      cancellationTimer = window.setInterval(() => {
        if (token !== state.audio.token) {
          settle(false);
        }
      }, 75);
    });

    if (token !== state.audio.token) return { tag: 'error', error: 'audio_cancelled' };
    if (!ended) return { tag: 'error', error: 'segment_playback_failed' };

    if (index < plan.length - 1) {
      await new Promise((resolve) => window.setTimeout(resolve, gapMs));
      if (token !== state.audio.token) return { tag: 'error', error: 'audio_cancelled' };
    }
  }

  state.audio.currentHighlightLineId = null;
  state.audio.currentFlattened = null;
  state.audio.currentGlobalOffsetMs = 0;
  state.audio.activeWordIndex = null;

  return { tag: 'ok' };
}

/**
 * @param {{ kind: 'narration' | 'dialogue', lineId: string, speaker: string, text: string, audioUrl: string | null, timingsUrl: string | null }} item
 * @param {number} token
 * @returns {Promise<{ tag: 'ok' } | { tag: 'error', error: string }>}
 */
async function playItem(item, token) {
  if (item.audioUrl) {
    return playSingleAudioItem({ ...item, audioUrl: item.audioUrl }, token);
  }

  return playSegmentAudioItem({ ...item, audioUrl: '' }, token);
}

/**
 * @param {Array<{ kind: 'narration' | 'dialogue', lineId: string, speaker: string, text: string, audioUrl: string | null, timingsUrl: string | null }>} items
 * @param {{ autoAdvance: boolean }} options
 */
async function playQueue(items, options) {
  state.audio.queueToken += 1;
  const queueToken = state.audio.queueToken;
  state.audio.token += 1;
  const playbackToken = state.audio.token;

  for (const item of items) {
    if (queueToken !== state.audio.queueToken || playbackToken !== state.audio.token) return;

    const result = await playItem(item, playbackToken);

    if (result.tag === 'error') {
      if (result.error !== 'audio_cancelled') {
        state.audio.tag = 'error';
        state.audio.error = result.error;
        renderMeta();
      }
      return;
    }
  }

  if (options.autoAdvance && state.mode.tag === 'narrate') {
    const next = clampPageIndex(state.nav.pageIndex + 1);
    if (next !== state.nav.pageIndex) {
      setPageIndex(next, { reason: 'auto' });
    }
  }
}

/**
 * @returns {Array<{ kind: 'narration' | 'dialogue', lineId: string, speaker: string, text: string, audioUrl: string | null, timingsUrl: string | null }>}
 */
function buildNarrateQueueForCurrentPage() {
  const page = pageAt(state.nav.pageIndex);
  if (!page) return [];

  /** @type {Array<{ kind: 'narration' | 'dialogue', lineId: string, speaker: string, text: string, audioUrl: string | null, timingsUrl: string | null }>} */
  const queue = [];

  if (text(page.narration?.audioUrl || '').trim() || text(page.narration?.timingsUrl || '').trim()) {
    queue.push({
      kind: 'narration',
      lineId: '__narration__',
      speaker: 'Narrator',
      text: text(page.narration?.text || ''),
      audioUrl: text(page.narration?.audioUrl || '').trim() || null,
      timingsUrl: text(page.narration?.timingsUrl || '').trim() || null
    });
  }

  const dialogue = Array.isArray(page.dialogue) ? page.dialogue : [];

  for (const line of dialogue) {
    const audioUrl = text(line.audioUrl || '').trim() || null;
    const timingsUrl = text(line.timingsUrl || '').trim() || null;

    if (!audioUrl && !timingsUrl) continue;

    queue.push({
      kind: 'dialogue',
      lineId: text(line.id),
      speaker: text(line.characterName || 'Speaker'),
      text: text(line.text || ''),
      audioUrl,
      timingsUrl
    });
  }

  return queue;
}

/**
 * @param {{ autoAdvance: boolean }} options
 */
async function playNarrateSequenceForCurrentPage(options) {
  const queue = buildNarrateQueueForCurrentPage();
  if (!queue.length) return;
  await playQueue(queue, options);
}

/**
 * @param {string} lineId
 */
async function playSingleDialogueLine(lineId) {
  const page = pageAt(state.nav.pageIndex);
  if (!page) return;

  const line = (Array.isArray(page.dialogue) ? page.dialogue : []).find((entry) => text(entry.id) === lineId);
  if (!line) return;

  stopVoice({ clearWarning: false });

  state.audio.token += 1;
  const token = state.audio.token;

  await playItem(
    {
      kind: 'dialogue',
      lineId: text(line.id),
      speaker: text(line.characterName || 'Speaker'),
      text: text(line.text || ''),
      audioUrl: text(line.audioUrl || '').trim() || null,
      timingsUrl: text(line.timingsUrl || '').trim() || null
    },
    token
  );
}

/**
 * @param {string | null} preferredTrackId
 */
function musicElement(preferredTrackId) {
  if (preferredTrackId === 'a') return musicA;
  if (preferredTrackId === 'b') return musicB;
  return state.music.deck === 'a' ? musicA : musicB;
}

/**
 * @param {number} ms
 * @returns {Promise<void>}
 */
function delay(ms) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

/**
 * @returns {{ trackId: string, audioUrl: string, loop: boolean } | null}
 */
function trackForCurrentPage() {
  if (state.story.tag !== 'ready') return null;
  const music = state.story.pack.music || {};
  const tracks = Array.isArray(music.tracks) ? music.tracks : [];
  const spans = Array.isArray(music.spans) ? music.spans : [];

  const span = spans.find(
    (entry) => state.nav.pageIndex >= Number(entry.startPageIndex) && state.nav.pageIndex <= Number(entry.endPageIndex)
  );

  if (!span) return null;

  const track = tracks.find((entry) => text(entry.id) === text(span.trackId));
  if (!track) return null;

  const audioUrl = text(track.audioUrl || '').trim();
  if (!audioUrl) return null;

  return {
    trackId: text(track.id),
    audioUrl,
    loop: span.loop !== false
  };
}

/**
 * @param {number} token
 */
async function fadeOutMusic(token) {
  const active = musicElement();
  const startVolume = Number(active.volume || 0);
  const steps = 12;

  for (let index = steps; index >= 0; index -= 1) {
    if (token !== state.music.transitionToken) return;
    active.volume = (startVolume * index) / steps;
    await delay(48);
  }

  active.pause();
  active.currentTime = 0;
  active.removeAttribute('src');

  state.music.tag = 'stopped';
  state.music.activeTrackId = null;
  state.music.activeUrl = null;
  renderMeta();
}

/**
 * @param {{ trackId: string, audioUrl: string, loop: boolean }} target
 */
async function crossfadeToTrack(target) {
  state.music.transitionToken += 1;
  const token = state.music.transitionToken;

  if (state.music.activeTrackId === target.trackId && state.music.activeUrl === target.audioUrl) {
    const active = musicElement();
    active.loop = target.loop;
    return;
  }

  state.music.tag = 'crossfading';
  renderMeta();

  const outgoingDeck = state.music.deck;
  const incomingDeck = outgoingDeck === 'a' ? 'b' : 'a';
  const outgoing = musicElement(outgoingDeck);
  const incoming = musicElement(incomingDeck);

  incoming.loop = target.loop;
  incoming.src = target.audioUrl;
  incoming.currentTime = 0;
  incoming.volume = 0;

  try {
    await incoming.play();
  } catch (error) {
    state.music.tag = 'error';
    state.music.error = `music_play_failed:${text(error && error.message || error)}`;
    renderMeta();
    return;
  }

  const targetVolume = Number(dom.musicVolume.value || 0.35);
  const steps = 20;

  for (let index = 0; index <= steps; index += 1) {
    if (token !== state.music.transitionToken) return;

    const ratio = index / steps;
    incoming.volume = targetVolume * ratio;
    outgoing.volume = targetVolume * (1 - ratio);
    await delay(60);
  }

  outgoing.pause();
  outgoing.currentTime = 0;
  outgoing.removeAttribute('src');

  state.music.deck = incomingDeck;
  state.music.activeTrackId = target.trackId;
  state.music.activeUrl = target.audioUrl;
  state.music.activeLoop = target.loop;
  state.music.tag = 'playing';
  renderMeta();
}

/**
 * Updates music assignment for current page.
 * Spec source: FR-038 / FR-039.
 */
function updateMusicForPage() {
  const assignment = trackForCurrentPage();

  if (!assignment) {
    void fadeOutMusic(++state.music.transitionToken);
    return;
  }

  void crossfadeToTrack(assignment);
}

/**
 * @returns {{ readerId: string, name: string, pageIndex: number, host: boolean, cursor: { x: number, y: number } | null }}
 */
function currentPresencePayload(cursor = null) {
  return {
    readerId: state.collab.identity.id,
    name: state.collab.identity.name,
    pageIndex: state.nav.pageIndex,
    host: state.collab.isHost,
    cursor
  };
}

/**
 * @returns {void}
 */
function publishPresence(cursor = null) {
  if (!state.collab.room) return;
  state.collab.room.publishPresence(currentPresencePayload(cursor));
}

/**
 * @returns {void}
 */
function publishPageSync() {
  if (!state.collab.room || !state.collab.isHost) return;

  state.collab.syncSeq += 1;

  state.collab.room.publishTopic('page_sync', {
    type: 'page_sync',
    from: state.collab.identity.id,
    name: state.collab.identity.name,
    pageIndex: state.nav.pageIndex,
    host: state.collab.isHost,
    syncSeq: state.collab.syncSeq
  });
}

/**
 * @returns {void}
 */
function maybeFollowHost() {
  if (state.collab.isHost || !state.collab.followHost) return;

  const host = activeHostParticipant();

  if (!host) {
    if (shouldElectSelfHost()) {
      state.collab.isHost = true;
      publishPresence();
      publishPageSync();
      renderCollaboration();
    }
    return;
  }

  const nextIndex = clampPageIndex(host.pageIndex);
  if (nextIndex !== state.nav.pageIndex) {
    setPageIndex(nextIndex, { reason: 'sync' });
  }
}

/**
 * @param {any} message
 */
function handlePageSyncMessage(message) {
  if (!message || message.from === state.collab.identity.id) return;
  if (!message.host || state.collab.isHost || !state.collab.followHost) return;

  const host = activeHostParticipant();
  if (!host || host.id !== message.from) return;

  const sequence = Number(message.syncSeq || 0);
  const previous = Number(state.collab.lastAppliedSyncSeqByPeer[message.from] || 0);

  if (Number.isFinite(sequence) && sequence > 0 && sequence <= previous) {
    return;
  }

  if (Number.isFinite(sequence) && sequence > 0) {
    state.collab.lastAppliedSyncSeqByPeer[message.from] = sequence;
  }

  const nextPage = clampPageIndex(Number(message.pageIndex));
  if (nextPage !== state.nav.pageIndex) {
    setPageIndex(nextPage, { reason: 'sync' });
  }
}

/**
 * @param {any} response
 */
function applyPresence(response) {
  const peers = response?.peers || {};
  state.collab.participants.clear();

  for (const [peerId, peer] of Object.entries(peers)) {
    const participantId = text(peer?.readerId || peer?.peerId || peerId);
    if (!participantId || participantId === state.collab.identity.id) continue;

    state.collab.participants.set(participantId, {
      id: participantId,
      name: text(peer?.name || `Reader ${text(peerId).slice(-4)}`),
      pageIndex: clampPageIndex(Number(peer?.pageIndex)),
      host: Boolean(peer?.host),
      cursor: peer?.cursor
        ? {
            x: clampUnit(Number(peer.cursor.x)),
            y: clampUnit(Number(peer.cursor.y))
          }
        : null,
      seenAt: Date.now()
    });
  }

  maybeFollowHost();
  renderCollaboration();
  renderCursors();
}

/**
 * @returns {void}
 */
function teardownCollaboration() {
  if (state.collab.heartbeatTimer) {
    window.clearInterval(state.collab.heartbeatTimer);
    state.collab.heartbeatTimer = null;
  }

  if (state.collab.staleSweepTimer) {
    window.clearInterval(state.collab.staleSweepTimer);
    state.collab.staleSweepTimer = null;
  }

  if (state.collab.pointerMoveHandler) {
    dom.stage.removeEventListener('pointermove', state.collab.pointerMoveHandler);
    state.collab.pointerMoveHandler = null;
  }

  if (state.collab.pointerLeaveHandler) {
    dom.stage.removeEventListener('pointerleave', state.collab.pointerLeaveHandler);
    state.collab.pointerLeaveHandler = null;
  }

  for (const teardownFn of state.collab.teardownFns) {
    try {
      teardownFn();
    } catch (_error) {
      // Intentionally ignored during teardown.
    }
  }

  state.collab.teardownFns = [];
  state.collab.room = null;
  state.collab.db = null;
  state.collab.backend = 'none';
  state.collab.tag = 'disconnected';
  state.collab.participants.clear();
}

/**
 * @returns {Promise<void>}
 */
async function initCollaboration() {
  teardownCollaboration();

  if (state.runtime.tag !== 'ready') return;
  if (state.story.tag !== 'ready') return;

  const instantAppId = text(state.runtime.config.instantAppId).trim();

  if (!instantAppId) {
    state.collab.error = 'instantdb_app_id_missing';
    state.collab.tag = 'disconnected';
    renderCollaboration();
    return;
  }

  if (!window.instant || typeof window.instant.init !== 'function') {
    state.collab.error = 'instantdb_runtime_missing';
    state.collab.tag = 'disconnected';
    renderCollaboration();
    return;
  }

  const roomKey = text(state.story.pack.slug || state.runtime.config.storySlug || state.runtime.config.storyId || 'story');

  state.collab.tag = 'connecting';
  state.collab.error = null;
  renderCollaboration();

  try {
    const db = window.instant.init({ appId: instantAppId });
    const room = db.joinRoom('storytime', roomKey, {
      initialPresence: currentPresencePayload()
    });

    state.collab.db = db;
    state.collab.room = room;
    state.collab.backend = 'instantdb';
    state.collab.tag = 'solo';

    const unsubscribePresence = room.subscribePresence({}, (response) => {
      applyPresence(response);

      const peers = freshParticipants();
      state.collab.tag = peers.length ? 'active' : 'solo';
      renderCollaboration();
    });

    const unsubscribeTopic = room.subscribeTopic('page_sync', (message) => {
      const payload = message && message.data && typeof message.data === 'object' ? message.data : message;
      handlePageSyncMessage(payload);
    });

    state.collab.teardownFns.push(
      () => unsubscribePresence && unsubscribePresence(),
      () => unsubscribeTopic && unsubscribeTopic(),
      () => room.leaveRoom && room.leaveRoom(),
      () => db.shutdown && db.shutdown()
    );

    state.collab.heartbeatTimer = window.setInterval(() => {
      publishPresence();
    }, PRESENCE_HEARTBEAT_MS);

    state.collab.staleSweepTimer = window.setInterval(() => {
      renderCollaboration();
      renderCursors();
      maybeFollowHost();
    }, 2000);

    state.collab.pointerMoveHandler = (event) => {
      const now = Date.now();
      if (now - state.collab.lastPointerPublishAt < POINTER_PUBLISH_INTERVAL_MS) return;
      state.collab.lastPointerPublishAt = now;

      const rect = dom.stage.getBoundingClientRect();
      const cursor = {
        x: clampUnit((event.clientX - rect.left) / rect.width),
        y: clampUnit((event.clientY - rect.top) / rect.height)
      };

      publishPresence(cursor);
    };

    dom.stage.addEventListener('pointermove', state.collab.pointerMoveHandler, { passive: true });

    state.collab.pointerLeaveHandler = () => publishPresence(null);
    dom.stage.addEventListener('pointerleave', state.collab.pointerLeaveHandler, { passive: true });

    publishPresence();
    renderCollaboration();
  } catch (error) {
    state.collab.tag = 'disconnected';
    state.collab.error = `instantdb_connect_failed:${text(error && error.message || error)}`;
    renderCollaboration();
  }
}

/**
 * @returns {void}
 */
function initAudioEvents() {
  voiceAudio.addEventListener('timeupdate', () => {
    if (state.audio.tag !== 'playing' && state.audio.tag !== 'paused') return;
    if (!state.audio.currentFlattened) return;

    const globalTimeMs = state.audio.currentGlobalOffsetMs + voiceAudio.currentTime * 1000;
    const nextIndex = activeWordIndexAtMs(state.audio.currentFlattened, globalTimeMs);

    if (nextIndex !== state.audio.activeWordIndex) {
      state.audio.activeWordIndex = nextIndex;
      renderNarrationAndDialogue();
    }
  });

  dom.voiceVolume.addEventListener('input', () => {
    voiceAudio.volume = Number(dom.voiceVolume.value || 0.9);
  });

  dom.musicVolume.addEventListener('input', () => {
    const volume = Number(dom.musicVolume.value || 0.35);
    musicA.volume = volume;
    musicB.volume = volume;
  });
}

/**
 * @returns {void}
 */
function initUiEvents() {
  document.body.addEventListener('click', (event) => {
    const button = event.target.closest('[data-action]');
    if (!button) return;

    const action = button.dataset.action;

    if (action === 'toggle-sidebar') {
      if (dom.sidebarOverlay) {
        dom.sidebarOverlay.hidden = !dom.sidebarOverlay.hidden;
      }
      return;
    }

    if (action === 'apply-pack-url') {
      if (state.runtime.tag !== 'ready' || !state.runtime.config.allowPackOverride) return;

      const nextPackUrl = text(dom.packUrlInput.value).trim();

      if (!nextPackUrl) {
        dom.packConfigStatus.textContent = 'Enter a StoryPack URL first.';
        return;
      }

      dom.packConfigStatus.textContent = 'Loading StoryPack URL...';
      reloadWithPackQuery(nextPackUrl);
      return;
    }

    if (action === 'clear-pack-url') {
      if (state.runtime.tag !== 'ready' || !state.runtime.config.allowPackOverride) return;
      dom.packConfigStatus.textContent = 'Clearing URL override...';
      reloadWithPackQuery(null);
      return;
    }

    if (action === 'next-page') {
      setPageIndex(state.nav.pageIndex + 1, { reason: 'manual' });
      return;
    }

    if (action === 'prev-page') {
      setPageIndex(state.nav.pageIndex - 1, { reason: 'manual' });
      return;
    }

    if (action === 'seek-page') {
      setPageIndex(Number(button.dataset.pageIndex), { reason: 'seek' });
      return;
    }

    if (action === 'toggle-mode') {
      state.mode = { tag: state.mode.tag === 'narrate' ? 'read_alone' : 'narrate' };
      if (state.mode.tag === 'read_alone') {
        stopVoice({ clearWarning: false });
      } else {
        void playNarrateSequenceForCurrentPage({ autoAdvance: true });
      }
      renderMeta();
      return;
    }

    if (action === 'play-narration') {
      const page = pageAt(state.nav.pageIndex);
      if (!page) return;

      stopVoice({ clearWarning: false });
      state.audio.token += 1;
      const token = state.audio.token;

      void playItem(
        {
          kind: 'narration',
          lineId: '__narration__',
          speaker: 'Narrator',
          text: text(page.narration?.text || ''),
          audioUrl: text(page.narration?.audioUrl || '').trim() || null,
          timingsUrl: text(page.narration?.timingsUrl || '').trim() || null
        },
        token
      );

      return;
    }

    if (action === 'play-page-dialogue') {
      const page = pageAt(state.nav.pageIndex);
      if (!page) return;

      const queue = (Array.isArray(page.dialogue) ? page.dialogue : [])
        .map((line) => ({
          kind: 'dialogue',
          lineId: text(line.id),
          speaker: text(line.characterName || 'Speaker'),
          text: text(line.text || ''),
          audioUrl: text(line.audioUrl || '').trim() || null,
          timingsUrl: text(line.timingsUrl || '').trim() || null
        }))
        .filter((item) => item.audioUrl || item.timingsUrl);

      stopVoice({ clearWarning: false });
      void playQueue(queue, { autoAdvance: false });
      return;
    }

    if (action === 'play-narration-dialogue') {
      stopVoice({ clearWarning: false });
      void playNarrateSequenceForCurrentPage({ autoAdvance: false });
      return;
    }

    if (action === 'pause-voice') {
      pauseVoice();
      return;
    }

    if (action === 'resume-voice') {
      resumeVoice();
      return;
    }

    if (action === 'stop-voice') {
      stopVoice({ clearWarning: false });
      return;
    }

    if (action === 'play-line') {
      void playSingleDialogueLine(text(button.dataset.lineId));
      return;
    }

    if (action === 'toggle-host') {
      state.collab.isHost = !state.collab.isHost;
      if (state.collab.isHost) {
        state.collab.followHost = true;
      }
      publishPresence();
      publishPageSync();
      renderCollaboration();
      return;
    }

    if (action === 'toggle-follow') {
      state.collab.followHost = !state.collab.followHost;
      maybeFollowHost();
      renderCollaboration();
    }
  });

  window.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowRight') {
      setPageIndex(state.nav.pageIndex + 1, { reason: 'manual' });
      return;
    }

    if (event.key === 'ArrowLeft') {
      setPageIndex(state.nav.pageIndex - 1, { reason: 'manual' });
      return;
    }

    if (event.key === ' ') {
      event.preventDefault();
      if (state.audio.tag === 'playing') {
        pauseVoice();
      } else if (state.audio.tag === 'paused') {
        resumeVoice();
      } else {
        const page = pageAt(state.nav.pageIndex);
        if (!page) return;

        stopVoice({ clearWarning: false });
        state.audio.token += 1;

        void playItem(
          {
            kind: 'narration',
            lineId: '__narration__',
            speaker: 'Narrator',
            text: text(page.narration?.text || ''),
            audioUrl: text(page.narration?.audioUrl || '').trim() || null,
            timingsUrl: text(page.narration?.timingsUrl || '').trim() || null
          },
          state.audio.token
        );
      }
    }
  });

  dom.stage.addEventListener('touchstart', (event) => {
    state.ui.swipeStartX = event.changedTouches[0]?.clientX || 0;
  }, { passive: true });

  dom.stage.addEventListener('touchend', (event) => {
    const endX = event.changedTouches[0]?.clientX || 0;
    const deltaX = endX - (state.ui.swipeStartX || 0);

    if (deltaX > 42) {
      setPageIndex(state.nav.pageIndex - 1, { reason: 'manual' });
    } else if (deltaX < -42) {
      setPageIndex(state.nav.pageIndex + 1, { reason: 'manual' });
    }
  }, { passive: true });
}

/**
 * Loads runtime config and story pack, then initializes reader subsystems.
 * Spec source: FR-031 / FR-048 / FR-054.
 */
async function boot() {
  clearErrorScreen();
  hidePackConfig();

  try {
    state.runtime = { tag: 'loading' };
    state.story = { tag: 'loading' };
    renderMeta();

    const runtimeConfig = await loadRuntimeConfig();
    state.runtime = { tag: 'ready', config: runtimeConfig };
    syncPackConfigVisibility();

    const packUrl = resolvePackUrl(runtimeConfig);

    if (!packUrl) {
      state.story = { tag: 'error', error: 'missing_story_config' };
      setErrorScreen('Story configuration is incomplete.', 'No StoryPack URL could be resolved from runtime config.');
      if (runtimeConfig.allowPackOverride) {
        showPackConfig({
          prefill: '',
          status: 'No pack configured. Paste a StoryPack URL to continue.'
        });
      }
      renderMeta();
      return;
    }

    const response = await fetch(packUrl, { cache: 'no-store' });

    if (!response.ok) {
      const statusText = `story_pack_http_${response.status}`;
      state.story = { tag: 'error', error: statusText };
      setErrorScreen('Story failed to load.', `Reader could not fetch StoryPack (${response.status}) from ${packUrl}.`);
      if (runtimeConfig.allowPackOverride) {
        showPackConfig({
          prefill: packUrl,
          status: `Pack fetch failed (${response.status}). Try a different StoryPack URL.`
        });
      }
      renderMeta();
      return;
    }

    const pack = await response.json();
    validateStoryPack(pack);

    state.story = { tag: 'ready', pack, packUrl };
    state.nav = { tag: 'idle', pageIndex: 0 };
    clearErrorScreen();
    syncPackConfigVisibility();
    if (runtimeConfig.allowPackOverride) {
      dom.packConfigStatus.textContent = `Loaded pack: ${packUrl}`;
    }
    renderAll();

    updateMusicForPage();
    await initCollaboration();

    if (state.mode.tag === 'narrate') {
      await playNarrateSequenceForCurrentPage({ autoAdvance: true });
    }
  } catch (error) {
    const details = text(error && error.message || error);
    state.story = { tag: 'error', error: details };
    setErrorScreen('Reader runtime failed.', details);
    if (state.runtime.tag === 'ready' && state.runtime.config.allowPackOverride) {
      showPackConfig({
        prefill: resolvePackUrl(state.runtime.config) || '',
        status: `Runtime error: ${details}. Try a different StoryPack URL.`
      });
    }
    renderMeta();
  }
}

initAudioEvents();
initUiEvents();

window.addEventListener('beforeunload', () => {
  teardownCollaboration();
  stopVoice({ clearWarning: true });
});

boot();
