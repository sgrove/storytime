import test from 'node:test';
import assert from 'node:assert/strict';

import {
  activeWordIndexAtMs,
  flattenTimings,
  hasSegmentAudio,
  normalizeTimingPayload,
  segmentPlaybackPlan
} from './timings.js';

test('normalizeTimingPayload parses ElevenLabs dialogue payload with exclusive character_end_index', () => {
  const text = 'Hi there';
  const chars = text.split('');
  const starts = chars.map((_, index) => index * 0.1);
  const ends = chars.map((_, index) => index * 0.1 + 0.08);

  const payload = {
    alignment: {
      characters: chars,
      character_start_times_seconds: starts,
      character_end_times_seconds: ends
    },
    voice_segments: [
      {
        character_start_index: 0,
        character_end_index: 2,
        speaker_id: 'narrator',
        audio_url: 'https://cdn.example.com/seg-0.mp3'
      },
      {
        character_start_index: 3,
        character_end_index: 8,
        speaker_id: 'hero',
        audio_url: 'https://cdn.example.com/seg-1.mp3'
      }
    ]
  };

  const result = normalizeTimingPayload(payload, { displayText: text });
  assert.equal(result.tag, 'ok');

  if (result.tag !== 'ok') {
    throw new Error('Expected ok result');
  }

  assert.equal(result.value.text, text);
  assert.equal(result.value.segments.length, 2);

  const first = result.value.segments[0];
  const second = result.value.segments[1];

  assert.equal(first.text, 'Hi');
  assert.equal(first.charStart, 0);
  assert.equal(first.charEnd, 2);
  assert.equal(first.words.length, 1);
  assert.equal(first.words[0].text, 'Hi');

  assert.equal(second.text, 'there');
  assert.equal(second.charStart, 3);
  assert.equal(second.charEnd, 8);
  assert.equal(second.words.length, 1);
  assert.equal(second.words[0].text, 'there');
});

test('normalizeTimingPayload prefers alignment over normalized_alignment for text parity', () => {
  const payload = {
    alignment: {
      characters: ['H', 'i'],
      character_start_times_seconds: [0, 0.1],
      character_end_times_seconds: [0.09, 0.19]
    },
    normalized_alignment: {
      characters: [' ', 'H', 'i', ' '],
      character_start_times_seconds: [0, 0.01, 0.1, 0.2],
      character_end_times_seconds: [0.01, 0.09, 0.19, 0.21]
    },
    voice_segments: []
  };

  const result = normalizeTimingPayload(payload, { displayText: 'Hi' });
  assert.equal(result.tag, 'ok');

  if (result.tag !== 'ok') {
    throw new Error('Expected ok result');
  }

  assert.equal(result.value.text, 'Hi');
  assert.equal(result.value.segments[0].text, 'Hi');
});

test('activeWordIndexAtMs tracks monotonic word progression', () => {
  const timings = {
    schemaVersion: 2,
    provider: 'elevenlabs',
    text: 'Hello world',
    totalDurationMs: 500,
    segmentGapMs: 0,
    segments: [
      {
        index: 0,
        voice: 'character',
        speakerId: 'speaker-0',
        text: 'Hello world',
        charStart: 0,
        charEnd: 11,
        durationMs: 500,
        audioUrl: null,
        words: [
          { text: 'Hello', startMs: 100, endMs: 220, charStart: 0, charEnd: 5 },
          { text: 'world', startMs: 300, endMs: 460, charStart: 6, charEnd: 11 }
        ]
      }
    ]
  };

  const flattened = flattenTimings(timings);
  assert.equal(activeWordIndexAtMs(flattened, 0), 0);
  assert.equal(activeWordIndexAtMs(flattened, 250), 0);
  assert.equal(activeWordIndexAtMs(flattened, 350), 1);
});

test('segmentPlaybackPlan sorts by index and hasSegmentAudio enforces all-segment URLs', () => {
  const withAudio = {
    schemaVersion: 2,
    provider: 'elevenlabs',
    text: 'abc',
    totalDurationMs: 300,
    segmentGapMs: 100,
    segments: [
      {
        index: 2,
        voice: 'character',
        speakerId: 's2',
        text: 'c',
        charStart: 2,
        charEnd: 3,
        durationMs: 100,
        audioUrl: 'https://cdn.example.com/seg-2.mp3',
        words: [{ text: 'c', startMs: 200, endMs: 280, charStart: 2, charEnd: 3 }]
      },
      {
        index: 0,
        voice: 'character',
        speakerId: 's0',
        text: 'a',
        charStart: 0,
        charEnd: 1,
        durationMs: 80,
        audioUrl: 'https://cdn.example.com/seg-0.mp3',
        words: [{ text: 'a', startMs: 0, endMs: 80, charStart: 0, charEnd: 1 }]
      }
    ]
  };

  assert.equal(hasSegmentAudio(withAudio), true);
  assert.deepEqual(segmentPlaybackPlan(withAudio).map((entry) => entry.index), [0, 2]);

  const withoutAudio = {
    ...withAudio,
    segments: [...withAudio.segments, {
      index: 1,
      voice: 'character',
      speakerId: 's1',
      text: 'b',
      charStart: 1,
      charEnd: 2,
      durationMs: 90,
      audioUrl: null,
      words: [{ text: 'b', startMs: 100, endMs: 190, charStart: 1, charEnd: 2 }]
    }]
  };

  assert.equal(hasSegmentAudio(withoutAudio), false);
});
