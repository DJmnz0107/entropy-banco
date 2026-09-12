/**
 * Gemini Live — BidiGenerateContent WebSocket proxy.
 *
 * The Gemini Live API is a bidirectional WebSocket stream.
 * We connect to it on behalf of the browser and relay audio in/out.
 *
 * Protocol reference:
 *   wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent
 *   ?key=<API_KEY>
 *
 * Message format follows the REST BidiGenerateContent spec.
 */

import WebSocket from 'ws';

const API_KEY = process.env.GEMINI_API_KEY;
if (!API_KEY) throw new Error('[gemini-live] Missing GEMINI_API_KEY');

const LIVE_VOICE_MODEL = 'gemini-3.1-flash-live-preview';

export type GeminiLiveTool = {
  functionDeclarations: Array<{
    name: string;
    description: string;
    parameters: {
      type: 'OBJECT';
      properties: Record<string, { type: string; description: string; enum?: string[] }>;
      required?: string[];
    };
  }>;
};

export interface GeminiLiveConfig {
  systemPrompt: string;
  tools: GeminiLiveTool[];
  modelId?: string;
  temperature?: number;
  voiceName?: string;
  vadConfig?: Record<string, unknown>;
}

export interface GeminiLiveEvent {
  type:
    | 'audio_chunk'        // audio PCM24 from Gemini
    | 'transcript_agent'   // agent text transcript
    | 'transcript_customer'// customer input transcription
    | 'function_call'      // Gemini wants to call a tool
    | 'turn_complete'      // Gemini finished speaking a turn
    | 'interrupted'        // Gemini was interrupted
    | 'setup_complete'     // Session is ready
    | 'error'             // fatal error
    | 'close';            // connection closed
  payload?: unknown;
}

export type GeminiLiveCallback = (event: GeminiLiveEvent) => void;

export class GeminiLiveSession {
  private ws: WebSocket | null = null;
  private callback: GeminiLiveCallback;
  private isReady = false;
  private audioQueue: Buffer[] = [];
  private config: GeminiLiveConfig;

  constructor(config: GeminiLiveConfig, callback: GeminiLiveCallback) {
    this.config = config;
    this.callback = callback;
  }

  async connect(): Promise<void> {
    const model = this.config.modelId ?? LIVE_VOICE_MODEL;
    const url = `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=${API_KEY}`;

    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(url);

      this.ws.on('open', () => {
        // Send setup message
        const setupMsg = {
          setup: {
            model: `models/${model}`,
            generationConfig: {
              responseModalities: ['AUDIO'],
              speechConfig: {
                voiceConfig: {
                  prebuiltVoiceConfig: {
                    voiceName: this.config.voiceName ?? 'Kore',
                  },
                },
              },
              temperature: this.config.temperature ?? 0.4,
            },
            systemInstruction: {
              parts: [{ text: this.config.systemPrompt }],
            },
            tools: this.config.tools,
            realtimeInputConfig: {
              automaticActivityDetection: {
                disabled: false,
                startOfSpeechSensitivity: (
                  this.config.vadConfig?.['start_of_speech_sensitivity'] ?? 'START_SENSITIVITY_LOW'
                ),
                endOfSpeechSensitivity: (
                  this.config.vadConfig?.['end_of_speech_sensitivity'] ?? 'END_SENSITIVITY_LOW'
                ),
                prefixPaddingMs: this.config.vadConfig?.['prefix_padding_ms'] as number ?? 200,
                silenceDurationMs: this.config.vadConfig?.['silence_duration_ms'] as number ?? 700,
              },
            },
          },
        };

        this.ws!.send(JSON.stringify(setupMsg));
      });

      this.ws.on('message', (raw: WebSocket.RawData) => {
        let msg: Record<string, unknown>;
        try {
          msg = JSON.parse(raw.toString()) as Record<string, unknown>;
        } catch {
          return;
        }

        // Setup complete
        if (msg['setupComplete'] !== undefined) {
          this.isReady = true;
          this.callback({ type: 'setup_complete' });
          // Flush queued audio
          for (const chunk of this.audioQueue) {
            this._sendAudioChunk(chunk);
          }
          this.audioQueue = [];
          resolve();
          return;
        }

        // Server content (audio, text)
        if (msg['serverContent']) {
          const sc = msg['serverContent'] as Record<string, unknown>;

          if (sc['turnComplete']) {
            this.callback({ type: 'turn_complete' });
          }

          if (sc['interrupted']) {
            this.callback({ type: 'interrupted' });
          }

          if (sc['modelTurn']) {
            const parts = (sc['modelTurn'] as Record<string, unknown>)['parts'] as Array<Record<string, unknown>> ?? [];
            for (const part of parts) {
              if (part['inlineData']) {
                const inlineData = part['inlineData'] as Record<string, unknown>;
                this.callback({
                  type: 'audio_chunk',
                  payload: inlineData['data'] as string, // base64 PCM24
                });
              }
              if (part['text']) {
                this.callback({
                  type: 'transcript_agent',
                  payload: part['text'] as string,
                });
              }
            }
          }

          // Input transcription
          if (sc['inputTranscription']) {
            const t = sc['inputTranscription'] as Record<string, unknown>;
            this.callback({
              type: 'transcript_customer',
              payload: t['text'] as string,
            });
          }
        }

        // Tool call from Gemini
        if (msg['toolCall']) {
          const tc = msg['toolCall'] as Record<string, unknown>;
          const calls = tc['functionCalls'] as Array<Record<string, unknown>> ?? [];
          for (const call of calls) {
            this.callback({
              type: 'function_call',
              payload: {
                id: call['id'] as string,
                name: call['name'] as string,
                args: call['args'] as Record<string, unknown>,
              },
            });
          }
        }
      });

      this.ws.on('error', (err) => {
        this.callback({ type: 'error', payload: err.message });
        reject(err);
      });

      this.ws.on('close', (code, reason) => {
        this.callback({ type: 'close', payload: { code, reason: reason.toString() } });
      });
    });
  }

  sendAudio(pcm16Base64: string): void {
    const chunk = Buffer.from(pcm16Base64, 'base64');
    if (!this.isReady) {
      this.audioQueue.push(chunk);
      return;
    }
    this._sendAudioChunk(chunk);
  }

  private _sendAudioChunk(chunk: Buffer): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    const msg = {
      realtimeInput: {
        audio: {
          data: chunk.toString('base64'),
          mimeType: 'audio/pcm;rate=16000',
        },
      },
    };
    this.ws.send(JSON.stringify(msg));
  }

  sendToolResponse(callId: string, output: unknown): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    const msg = {
      toolResponse: {
        functionResponses: [
          {
            id: callId,
            response: { output },
          },
        ],
      },
    };
    this.ws.send(JSON.stringify(msg));
  }

  sendClientContent(text: string): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return;
    const msg = {
      clientContent: {
        turns: [
          {
            role: 'user',
            parts: [{ text }],
          },
        ],
        turnComplete: true,
      },
    };
    this.ws.send(JSON.stringify(msg));
  }

  close(): void {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.close(1000, 'Session ended');
    }
    this.ws = null;
  }
}
