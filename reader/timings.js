/**
 * Timing normalization and read-along utilities.
 * Spec source: Storytime CodeTV spec FR-035 / FR-036 / FR-037 and
 * READER_MODE_RUNTIME_CONTRACT__SHIP_BLOCKER.md (2026-02-25).
 */

/**
 * @typedef {{ tag: 'ok', value: any } | { tag: 'error', error: string }} Result
 */

/**
 * @typedef {{
 *   text: string,
 *   startMs: number,
 *   endMs: number,
 *   charStart: number,
 *   charEnd: number
 * }} NormalizedWord
 */

/**
 * @typedef {{
 *   index: number,
 *   voice: 'character' | 'narrator',
 *   speakerId: string,
 *   text: string,
 *   charStart: number,
 *   charEnd: number,
 *   durationMs: number,
 *   audioUrl: string | null,
 *   words: NormalizedWord[]
 * }} NormalizedSegment
 */

/**
 * @typedef {{
 *   schemaVersion: 2,
 *   provider: string,
 *   text: string,
 *   totalDurationMs: number,
 *   segmentGapMs: number,
 *   segments: NormalizedSegment[]
 * }} NormalizedTimingV2
 */

/**
 * @param {any} value
 * @returns {Result}
 */
function ok(value) {
  return { tag: 'ok', value };
}

/**
 * @param {string} error
 * @returns {Result}
 */
function err(error) {
  return { tag: 'error', error };
}

/**
 * @param {number} value
 * @returns {number}
 */
function toNonNegativeInt(value) {
  if (!Number.isFinite(Number(value))) return 0;
  const out = Math.round(Number(value));
  return out < 0 ? 0 : out;
}

/**
 * @param {string[]} chars
 * @param {number[]} startsSeconds
 * @param {number[]} endsSeconds
 * @param {number} globalCharOffset
 * @param {number} timeOffsetMs
 * @returns {Result}
 */
function buildWordsFromAlignment(chars, startsSeconds, endsSeconds, globalCharOffset, timeOffsetMs) {
  if (chars.length !== startsSeconds.length || chars.length !== endsSeconds.length) {
    return err('timing_alignment_length_mismatch');
  }

  /** @type {NormalizedWord[]} */
  const words = [];
  let cursor = 0;

  while (cursor < chars.length) {
    while (cursor < chars.length && String(chars[cursor] || '').trim() === '') {
      cursor += 1;
    }

    if (cursor >= chars.length) break;

    const wordStart = cursor;
    let wordEnd = cursor;

    while (wordEnd < chars.length && String(chars[wordEnd] || '').trim() !== '') {
      wordEnd += 1;
    }

    const text = chars.slice(wordStart, wordEnd).join('');
    const startMs = toNonNegativeInt(Number(startsSeconds[wordStart] || 0) * 1000) + timeOffsetMs;
    const endMsRaw = toNonNegativeInt(Number(endsSeconds[Math.max(wordStart, wordEnd - 1)] || 0) * 1000) + timeOffsetMs;
    const endMs = endMsRaw < startMs ? startMs : endMsRaw;

    words.push({
      text,
      startMs,
      endMs,
      charStart: globalCharOffset + wordStart,
      charEnd: globalCharOffset + wordEnd
    });

    cursor = wordEnd;
  }

  return ok(words);
}

/**
 * @param {any} payload
 * @returns {Result}
 */
function normalizeCanonicalV2(payload) {
  const text = typeof payload.text === 'string' ? payload.text : '';
  const provider = typeof payload.provider === 'string' ? payload.provider : 'elevenlabs';
  const segmentGapMs = toNonNegativeInt(payload.segmentGapMs || 0);
  const rawSegments = Array.isArray(payload.segments) ? payload.segments : null;

  if (!rawSegments) {
    return err('timing_v2_segments_missing');
  }

  /** @type {NormalizedSegment[]} */
  const segments = [];

  for (let i = 0; i < rawSegments.length; i += 1) {
    const raw = rawSegments[i] || {};
    const rawWords = Array.isArray(raw.words) ? raw.words : [];

    /** @type {NormalizedWord[]} */
    const words = rawWords
      .map((word, wordIndex) => {
        const wordText = typeof word.text === 'string' ? word.text : (typeof word.word === 'string' ? word.word : '');
        const startMs = toNonNegativeInt(word.startMs);
        const endMs = toNonNegativeInt(word.endMs);
        const safeEnd = endMs < startMs ? startMs : endMs;

        return {
          text: wordText,
          startMs,
          endMs: safeEnd,
          charStart: toNonNegativeInt(word.charStart),
          charEnd: Math.max(toNonNegativeInt(word.charEnd), toNonNegativeInt(word.charStart)),
          _wordIndex: wordIndex
        };
      })
      .sort((a, b) => (a.startMs - b.startMs) || (a._wordIndex - b._wordIndex))
      .map(({ _wordIndex, ...word }) => word);

    const fallbackDuration = words.length ? Math.max(0, words[words.length - 1].endMs - words[0].startMs) : 0;

    const segment = {
      index: Number.isFinite(Number(raw.index)) ? Number(raw.index) : i,
      voice: raw.voice === 'narrator' ? 'narrator' : 'character',
      speakerId: typeof raw.speakerId === 'string' && raw.speakerId.length ? raw.speakerId : `speaker-${i}`,
      text: typeof raw.text === 'string' ? raw.text : '',
      charStart: toNonNegativeInt(raw.charStart),
      charEnd: Math.max(toNonNegativeInt(raw.charEnd), toNonNegativeInt(raw.charStart)),
      durationMs: toNonNegativeInt(raw.durationMs || fallbackDuration),
      audioUrl: typeof raw.audioUrl === 'string' && raw.audioUrl.length ? raw.audioUrl : null,
      words
    };

    segments.push(segment);
  }

  const totalDurationMs = (() => {
    if (Number.isFinite(Number(payload.totalDurationMs))) return toNonNegativeInt(payload.totalDurationMs);
    if (!segments.length) return 0;
    const lastWord = segments.flatMap((segment) => segment.words).sort((a, b) => b.endMs - a.endMs)[0];
    if (lastWord) return toNonNegativeInt(lastWord.endMs);
    return segments.reduce((acc, segment) => acc + segment.durationMs, 0);
  })();

  const audioStartMs = Number.isFinite(Number(payload.audioStartMs))
    ? toNonNegativeInt(payload.audioStartMs)
    : 0;

  const audioEndCandidate = Number.isFinite(Number(payload.audioEndMs))
    ? toNonNegativeInt(payload.audioEndMs)
    : 0;

  const audioEndMs = audioEndCandidate > audioStartMs ? audioEndCandidate : null;

  return ok({
    schemaVersion: 2,
    provider,
    text,
    totalDurationMs,
    segmentGapMs,
    segments: segments.sort((a, b) => a.index - b.index),
    audioStartMs,
    audioEndMs
  });
}

/**
 * @param {any} payload
 * @param {string} displayText
 * @returns {Result}
 */
function normalizeElevenLabsDialoguePayload(payload, displayText) {
  const alignment = payload.alignment || payload.normalized_alignment;

  if (!alignment || !Array.isArray(alignment.characters)) {
    return err('timing_dialogue_alignment_missing');
  }

  const chars = alignment.characters.map((char) => String(char));
  const startsSeconds = Array.isArray(alignment.character_start_times_seconds)
    ? alignment.character_start_times_seconds.map(Number)
    : [];
  const endsSeconds = Array.isArray(alignment.character_end_times_seconds)
    ? alignment.character_end_times_seconds.map(Number)
    : [];

  const wordsResult = buildWordsFromAlignment(chars, startsSeconds, endsSeconds, 0, 0);
  if (wordsResult.tag === 'error') return wordsResult;

  const fullText = chars.join('') || displayText;
  const voiceSegments = Array.isArray(payload.voice_segments) ? payload.voice_segments : [];

  /** @type {NormalizedSegment[]} */
  const segments = voiceSegments.length
    ? voiceSegments
        .map((voiceSegment, index) => {
          const startIndex = toNonNegativeInt(voiceSegment.character_start_index);
          const endIndexExclusive = toNonNegativeInt(voiceSegment.character_end_index);
          const lower = Math.min(startIndex, endIndexExclusive);
          const upper = Math.max(startIndex, endIndexExclusive);
          const charStart = Math.min(lower, fullText.length);
          const charEnd = Math.min(Math.max(charStart, upper), fullText.length);

          const segmentWords = wordsResult.value.filter(
            (word) => word.charStart >= charStart && word.charEnd <= charEnd
          );

          const speakerId =
            typeof voiceSegment.speaker_id === 'string' && voiceSegment.speaker_id.length
              ? voiceSegment.speaker_id
              : typeof voiceSegment.voice_id === 'string' && voiceSegment.voice_id.length
                ? voiceSegment.voice_id
              : `speaker-${index}`;

          const voice = /narrator/i.test(speakerId) ? 'narrator' : 'character';
          const segmentStartMs = toNonNegativeInt(Number(voiceSegment.start_time_seconds || 0) * 1000);
          const segmentEndMs = toNonNegativeInt(Number(voiceSegment.end_time_seconds || 0) * 1000);
          const firstWordStart = segmentWords.length ? segmentWords[0].startMs : 0;
          const lastWordEnd = segmentWords.length ? segmentWords[segmentWords.length - 1].endMs : firstWordStart;
          const durationMs = segmentWords.length
            ? Math.max(0, lastWordEnd - firstWordStart)
            : Math.max(0, segmentEndMs - segmentStartMs);

          return {
            index:
              Number.isFinite(Number(voiceSegment.dialogue_input_index))
                ? toNonNegativeInt(Number(voiceSegment.dialogue_input_index))
                : index,
            voice,
            speakerId,
            text: fullText.slice(charStart, charEnd),
            charStart,
            charEnd,
            durationMs,
            audioUrl:
              typeof voiceSegment.audio_url === 'string' && voiceSegment.audio_url.length
                ? voiceSegment.audio_url
                : null,
            words: segmentWords
          };
        })
        .sort((a, b) => a.index - b.index)
    : [
        {
          index: 0,
          voice: 'character',
          speakerId: 'speaker-0',
          text: fullText,
          charStart: 0,
          charEnd: fullText.length,
          durationMs: wordsResult.value.length
            ? Math.max(0, wordsResult.value[wordsResult.value.length - 1].endMs - wordsResult.value[0].startMs)
            : 0,
          audioUrl: null,
          words: wordsResult.value
        }
      ];

  const totalDurationMs = wordsResult.value.length
    ? wordsResult.value[wordsResult.value.length - 1].endMs
    : 0;

  return ok({
    schemaVersion: 2,
    provider: 'elevenlabs',
    text: fullText,
    totalDurationMs,
    segmentGapMs: 0,
    segments
  });
}

/**
 * @param {any} payload
 * @param {string} displayText
 * @returns {Result}
 */
function normalizeLegacyAlignmentPayload(payload, displayText) {
  const alignment = payload && payload.characters ? payload : payload && payload.alignment ? payload.alignment : null;

  if (!alignment || !Array.isArray(alignment.characters)) {
    return err('timing_alignment_missing');
  }

  const chars = alignment.characters.map((char) => String(char));
  const startsSeconds = Array.isArray(alignment.character_start_times_seconds)
    ? alignment.character_start_times_seconds.map(Number)
    : [];
  const endsSeconds = Array.isArray(alignment.character_end_times_seconds)
    ? alignment.character_end_times_seconds.map(Number)
    : [];

  const wordsResult = buildWordsFromAlignment(chars, startsSeconds, endsSeconds, 0, 0);
  if (wordsResult.tag === 'error') return wordsResult;

  const text = chars.join('') || displayText;
  const totalDurationMs = wordsResult.value.length ? wordsResult.value[wordsResult.value.length - 1].endMs : 0;

  return ok({
    schemaVersion: 2,
    provider: 'elevenlabs',
    text,
    totalDurationMs,
    segmentGapMs: 0,
    segments: [
      {
        index: 0,
        voice: 'character',
        speakerId: 'speaker-0',
        text,
        charStart: 0,
        charEnd: text.length,
        durationMs: totalDurationMs,
        audioUrl: null,
        words: wordsResult.value
      }
    ]
  });
}

/**
 * Normalizes timing payloads into canonical segment-based V2 timing.
 * Spec source: FR-035 + reader runtime contract (2026-02-25).
 *
 * @param {any} payload
 * @param {{ displayText?: string }} options
 * @returns {Result}
 */
export function normalizeTimingPayload(payload, options = {}) {
  const displayText = typeof options.displayText === 'string' ? options.displayText : '';

  if (!payload || typeof payload !== 'object') {
    return err('timing_payload_invalid_shape');
  }

  if (payload.schemaVersion === 2 && Array.isArray(payload.segments)) {
    return normalizeCanonicalV2(payload);
  }

  if (payload.schemaVersion === 1 && Array.isArray(payload.words)) {
    const text = typeof payload.text === 'string' ? payload.text : displayText;
    const words = payload.words
      .map((word) => ({
        text: typeof word.text === 'string' ? word.text : (typeof word.word === 'string' ? word.word : ''),
        startMs: toNonNegativeInt(word.startMs),
        endMs: Math.max(toNonNegativeInt(word.endMs), toNonNegativeInt(word.startMs)),
        charStart: toNonNegativeInt(word.charStart),
        charEnd: Math.max(toNonNegativeInt(word.charEnd), toNonNegativeInt(word.charStart))
      }))
      .sort((a, b) => a.startMs - b.startMs);

    const totalDurationMs = words.length ? words[words.length - 1].endMs : 0;

    return ok({
      schemaVersion: 2,
      provider: typeof payload.provider === 'string' ? payload.provider : 'elevenlabs',
      text,
      totalDurationMs,
      segmentGapMs: 0,
      segments: [
        {
          index: 0,
          voice: 'character',
          speakerId: 'speaker-0',
          text,
          charStart: 0,
          charEnd: text.length,
          durationMs: totalDurationMs,
          audioUrl: null,
          words
        }
      ]
    });
  }

  if (Array.isArray(payload.voice_segments) && (payload.alignment || payload.normalized_alignment)) {
    return normalizeElevenLabsDialoguePayload(payload, displayText);
  }

  if (payload.alignment || payload.characters) {
    return normalizeLegacyAlignmentPayload(payload, displayText);
  }

  return err('timing_payload_unsupported');
}

/**
 * Flattens canonical timing into a global word list.
 *
 * @param {NormalizedTimingV2} timings
 * @returns {{ text: string, words: NormalizedWord[] }}
 */
export function flattenTimings(timings) {
  const words = timings.segments
    .flatMap((segment) => (Array.isArray(segment.words) ? segment.words : []))
    .sort((a, b) => a.startMs - b.startMs);

  return { text: timings.text, words };
}

/**
 * Finds active word index for a playback timestamp.
 *
 * @param {{ words: NormalizedWord[] }} flattened
 * @param {number} timeMs
 * @returns {number | null}
 */
export function activeWordIndexAtMs(flattened, timeMs) {
  const words = flattened.words;
  if (!words.length) return null;

  const t = Math.max(0, toNonNegativeInt(timeMs));

  let lo = 0;
  let hi = words.length - 1;
  let best = -1;

  while (lo <= hi) {
    const mid = Math.floor((lo + hi) / 2);
    const word = words[mid];

    if (!word) break;

    if (word.startMs <= t) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }

  if (best < 0) return 0;
  return best;
}

/**
 * Returns true when every timing segment has its own audio URL.
 *
 * @param {NormalizedTimingV2} timings
 * @returns {boolean}
 */
export function hasSegmentAudio(timings) {
  return timings.segments.length > 0 && timings.segments.every((segment) => typeof segment.audioUrl === 'string' && segment.audioUrl.length > 0);
}

/**
 * Builds ordered segment playback entries from canonical timings.
 *
 * @param {NormalizedTimingV2} timings
 * @returns {{ index: number, audioUrl: string, startMs: number }[]}
 */
export function segmentPlaybackPlan(timings) {
  return timings.segments
    .filter((segment) => typeof segment.audioUrl === 'string' && segment.audioUrl.length > 0)
    .map((segment) => ({
      index: segment.index,
      audioUrl: /** @type {string} */ (segment.audioUrl),
      startMs: segment.words.length ? segment.words[0].startMs : 0
    }))
    .sort((a, b) => a.index - b.index);
}
