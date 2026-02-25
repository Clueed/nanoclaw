import { downloadMediaMessage } from '@whiskeysockets/baileys';
import { WAMessage, WASocket } from '@whiskeysockets/baileys';

import { readEnvFile } from './env.js';

interface TranscriptionConfig {
  model: string;
  enabled: boolean;
  fallbackMessage: string;
  baseURL: string;
}

const DEFAULT_CONFIG: TranscriptionConfig = {
  model: 'whisper-large-v3',
  enabled: true,
  fallbackMessage: '[Voice Message - transcription unavailable]',
  baseURL: 'https://api.groq.com/openai/v1',
};

export async function transcribeWithGroq(
  audioBuffer: Buffer,
  config: TranscriptionConfig = DEFAULT_CONFIG,
): Promise<string | null> {
  const env = readEnvFile(['GROQ_API_KEY']);
  const apiKey = env.GROQ_API_KEY;

  if (!apiKey) {
    console.warn('GROQ_API_KEY not set in .env');
    return null;
  }

  try {
    const openaiModule = await import('openai');
    const OpenAI = openaiModule.default;
    const toFile = openaiModule.toFile;

    const openai = new OpenAI({
      apiKey,
      baseURL: config.baseURL,
    });

    const file = await toFile(audioBuffer, 'voice.ogg', {
      type: 'audio/ogg',
    });

    const transcription = await openai.audio.transcriptions.create({
      file: file,
      model: config.model,
      response_format: 'text',
    });

    // When response_format is 'text', the API returns a plain string
    return transcription as unknown as string;
  } catch (err) {
    console.error('Groq transcription failed:', err);
    return null;
  }
}

export async function transcribeAudioMessage(
  msg: WAMessage,
  sock: WASocket,
): Promise<string | null> {
  const config = DEFAULT_CONFIG;

  if (!config.enabled) {
    return config.fallbackMessage;
  }

  try {
    const buffer = (await downloadMediaMessage(
      msg,
      'buffer',
      {},
      {
        logger: console as any,
        reuploadRequest: sock.updateMediaMessage,
      },
    )) as Buffer;

    if (!buffer || buffer.length === 0) {
      console.error('Failed to download audio message');
      return config.fallbackMessage;
    }

    console.log(`Downloaded audio message: ${buffer.length} bytes`);

    const transcript = await transcribeWithGroq(buffer, config);

    if (!transcript) {
      return config.fallbackMessage;
    }

    return transcript.trim();
  } catch (err) {
    console.error('Transcription error:', err);
    return config.fallbackMessage;
  }
}

/**
 * Channel-agnostic transcription for generic audio buffers.
 * Works with any channel (WhatsApp, Telegram, etc.)
 */
export async function transcribeAudioBuffer(
  audioBuffer: Buffer,
): Promise<string | null> {
  const config = DEFAULT_CONFIG;

  if (!config.enabled) {
    return config.fallbackMessage;
  }

  if (!audioBuffer || audioBuffer.length === 0) {
    console.error('Empty audio buffer provided');
    return config.fallbackMessage;
  }

  console.log(`Transcribing audio buffer: ${audioBuffer.length} bytes`);

  const transcript = await transcribeWithGroq(audioBuffer, config);

  if (!transcript) {
    return config.fallbackMessage;
  }

  return transcript.trim();
}

export function isVoiceMessage(msg: WAMessage): boolean {
  return msg.message?.audioMessage?.ptt === true;
}
