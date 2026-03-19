import { readEnvFile } from './env.js';
import { logger } from './logger.js';

const FALLBACK_MESSAGE = '[Voice Message - transcription unavailable]';

/**
 * Transcribe a voice audio buffer using the Groq Whisper API.
 * Falls back to OpenAI if GROQ_API_KEY is not set.
 */
export async function transcribeVoiceBuffer(
  buffer: Buffer,
): Promise<string> {
  const env = readEnvFile(['GROQ_API_KEY', 'OPENAI_API_KEY']);

  const provider = env.GROQ_API_KEY
    ? { key: env.GROQ_API_KEY, url: 'https://api.groq.com/openai/v1/audio/transcriptions', model: 'whisper-large-v3-turbo' }
    : env.OPENAI_API_KEY
      ? { key: env.OPENAI_API_KEY, url: 'https://api.openai.com/v1/audio/transcriptions', model: 'whisper-1' }
      : null;

  if (!provider) {
    logger.warn('No transcription API key set (GROQ_API_KEY or OPENAI_API_KEY)');
    return FALLBACK_MESSAGE;
  }

  try {
    logger.info({ bytes: buffer.length }, 'Transcribing voice message');

    const blob = new Blob([buffer], { type: 'audio/ogg' });
    const form = new FormData();
    form.append('file', blob, 'voice.ogg');
    form.append('model', provider.model);
    form.append('response_format', 'text');

    const res = await fetch(provider.url, {
      method: 'POST',
      headers: { Authorization: `Bearer ${provider.key}` },
      body: form,
    });

    if (!res.ok) {
      const body = await res.text();
      logger.error({ status: res.status, body }, 'Transcription API error');
      return FALLBACK_MESSAGE;
    }

    const text = await res.text();
    return text.trim() || FALLBACK_MESSAGE;
  } catch (err) {
    logger.error({ err }, 'Transcription failed');
    return FALLBACK_MESSAGE;
  }
}
