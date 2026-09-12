/**
 * VoiceSession — manages the full lifecycle of a voice call.
 *
 * Responsibilities:
 *  1. Load context from Supabase (get_conversation_context)
 *  2. Open Supabase conversation (start_conversation)
 *  3. Open Gemini Live session
 *  4. Proxy audio: browser WS ↔ Gemini Live
 *  5. Handle Gemini function calls → Supabase RPCs
 *  6. Run supervisor (evaluate_turn) after each customer turn
 *  7. Inject [CONTROL] messages back into Gemini
 *  8. Close everything on hang-up
 */

import type { WebSocket } from 'ws';
import { db } from '../lib/supabase.js';
import type { ConversationContext, StartConversationResult } from '../lib/supabase.js';
import { GeminiLiveSession } from '../lib/gemini-live.js';
import type { GeminiLiveEvent } from '../lib/gemini-live.js';
import { generateScorecard } from '../lib/supervisor.js';
import { buildSystemPrompt } from './system-prompt.js';
import { voiceTools } from './tools.js';

type WsMessage = {
  type: 'audio' | 'end';
  data?: string;
};

type BrowserMessage =
  | { type: 'audio'; data: string }           // base64 PCM16
  | { type: 'transcript'; role: 'agent' | 'customer'; text: string }
  | { type: 'stage'; stage: string; objective: string; control_message: string }
  | { type: 'commitment'; receipt_code: string; summary: string }
  | { type: 'offer'; offer: { code: string; terms_text: string; instruction: string } }
  | { type: 'end'; outcome: string; summary: string }
  | { type: 'error'; message: string }
  | { type: 'ready' };

export class VoiceSession {
  private customerId: string;
  private ws: WebSocket;
  private gemini: GeminiLiveSession | null = null;

  private conversationId: string | null = null;
  private currentStage = 'APERTURA';
  private startResult: StartConversationResult | null = null;

  private conversationHistory: Array<{ role: string; text: string }> = [];
  private activeAgentMessageId: string | null = null;
  private lastCustomerText = '';
  private lastOfferCode: string | null = null;
  private lastOfferParams: Record<string, unknown> = {};

  private supervisorRunning = false;
  private ended = false;

  constructor(customerId: string, ws: WebSocket) {
    this.customerId = customerId;
    this.ws = ws;
  }

  async start(): Promise<void> {
    try {
      console.log(`[session:${this.customerId}] Starting voice session`);

      // 1. Load context
      const context = await db.getConversationContext(this.customerId);

      if (!context.customer.contact_enabled) {
        this.sendBrowser({ type: 'error', message: 'CONTACTO_NO_HABILITADO' });
        return;
      }

      // 2. Start conversation in Supabase
      this.startResult = await db.startConversation(this.customerId, 'voice', 'outbound');
      this.conversationId = this.startResult.conversation_id;
      this.currentStage = this.startResult.current_stage;

      const initialControlMessage = this.startResult.models.voice_realtime
        ? `[CONTROL] Etapa inicial: ${this.currentStage}. Preséntate como Valeria de Bancoagrícola y saluda a ${context.customer.full_name} cordialmente. Confirma identidad antes de mencionar cualquier dato del crédito.`
        : '[CONTROL] Inicia la llamada.';

      // 3. Build system prompt
      const systemPrompt = buildSystemPrompt(context as ConversationContext, initialControlMessage);

      // 4. Connect to Gemini Live
      const vr = this.startResult.models.voice_realtime;
      this.gemini = new GeminiLiveSession(
        {
          systemPrompt,
          tools: voiceTools,
          modelId: vr?.model_id ?? 'gemini-3.1-flash-live-preview',
          temperature: (vr?.params?.temperature as number) ?? 0.4,
          voiceName: (vr?.params?.voice_name as string) ?? 'Kore',
          vadConfig: vr?.vad_config ?? {},
        },
        (event) => this.handleGeminiEvent(event),
      );

      await this.gemini.connect();

      // Notify browser that session is ready
      this.sendBrowser({ type: 'ready' });
      console.log(`[session:${this.customerId}] conversation_id=${this.conversationId} ready`);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[session:${this.customerId}] Start error:`, msg);
      this.sendBrowser({ type: 'error', message: msg });
    }
  }

  handleBrowserMessage(raw: string): void {
    if (this.ended) return;
    let msg: WsMessage;
    try {
      msg = JSON.parse(raw) as WsMessage;
    } catch {
      return;
    }

    if (msg.type === 'audio' && msg.data) {
      this.gemini?.sendAudio(msg.data);
    } else if (msg.type === 'end') {
      void this.end('COMPLETED_AGENT', 'Cliente colgó la llamada.');
    }
  }

  private handleGeminiEvent(event: GeminiLiveEvent): void {
    if (this.ended) return;

    switch (event.type) {
      case 'audio_chunk':
        this.sendBrowser({ type: 'audio', data: event.payload as string });
        break;

      case 'transcript_agent': {
        const text = event.payload as string;
        this.conversationHistory.push({ role: 'agent', text });
        this.sendBrowser({ type: 'transcript', role: 'agent', text });
        // Log agent message to Supabase (fire and forget)
        void this.logAgentMessage(text);
        break;
      }

      case 'transcript_customer': {
        const text = event.payload as string;
        this.lastCustomerText = text;
        this.conversationHistory.push({ role: 'customer', text });
        this.sendBrowser({ type: 'transcript', role: 'customer', text });
        // Run supervisor in parallel
        void this.runSupervisorCycle(text);
        break;
      }

      case 'function_call':
        void this.handleFunctionCall(
          event.payload as { id: string; name: string; args: Record<string, unknown> },
        );
        break;

      case 'turn_complete':
        break;

      case 'interrupted':
        void this.handleInterruption();
        break;

      case 'error':
        console.error(`[session:${this.customerId}] Gemini error:`, event.payload);
        this.sendBrowser({ type: 'error', message: String(event.payload) });
        break;

      case 'close':
        if (!this.ended) {
          void this.end('COMPLETED_AGENT', 'Conexión con Gemini cerrada.');
        }
        break;
    }
  }

  private async handleFunctionCall(call: {
    id: string;
    name: string;
    args: Record<string, unknown>;
  }): Promise<void> {
    console.log(`[session:${this.customerId}] function_call: ${call.name}`, call.args);
    if (!this.conversationId) {
      this.gemini?.sendToolResponse(call.id, { error: 'No conversation ID' });
      return;
    }

    try {
      let result: unknown;

      switch (call.name) {
        case 'validar_oferta': {
          const offerCode = call.args['offer_code'] as string;
          const params = call.args['params']
            ? (JSON.parse(call.args['params'] as string) as Record<string, unknown>)
            : {};
          const res = await db.validateOffer(this.conversationId, offerCode, params);
          this.lastOfferCode = offerCode;
          this.lastOfferParams = res.normalized_params ?? params;
          if (res.valid) {
            this.sendBrowser({
              type: 'offer',
              offer: { code: offerCode, terms_text: res.terms_text, instruction: res.instruction },
            });
          }
          result = res;
          break;
        }

        case 'registrar_compromiso': {
          const offerCode = call.args['offer_code'] as string;
          const params = call.args['params']
            ? (JSON.parse(call.args['params'] as string) as Record<string, unknown>)
            : this.lastOfferParams;
          const confirmed = call.args['customer_confirmed'] === 'true';
          const res = await db.registerCommitment(
            this.conversationId,
            offerCode,
            params,
            confirmed,
          );
          if (res.ok && res.receipt_code) {
            this.sendBrowser({
              type: 'commitment',
              receipt_code: res.receipt_code,
              summary: res.summary,
            });
          }
          result = res;
          break;
        }

        case 'crear_link_de_pago': {
          const res = await db.createPaymentLink(this.conversationId);
          result = res;
          break;
        }

        case 'solicitar_escalacion': {
          const reason = call.args['reason'] as string;
          const res = await db.requestEscalation(this.conversationId, reason, 'high', 'agent');
          result = res;
          break;
        }

        case 'registrar_rellamada': {
          const callbackDate = call.args['callback_date'] as string;
          const window = (call.args['window'] as string) ?? 'any';
          // Validate as CALLBACK offer first
          const validate = await db.validateOffer(this.conversationId, 'CALLBACK', {
            callback_date: callbackDate,
            window,
          });
          if (validate.valid) {
            const register = await db.registerCommitment(
              this.conversationId,
              'CALLBACK',
              validate.normalized_params,
              true,
            );
            result = register;
          } else {
            result = validate;
          }
          break;
        }

        default:
          result = { error: `Unknown function: ${call.name}` };
      }

      this.gemini?.sendToolResponse(call.id, result);
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[session:${this.customerId}] Function call error (${call.name}):`, msg);
      this.gemini?.sendToolResponse(call.id, { error: msg });
    }
  }

  private async runSupervisorCycle(customerText: string): Promise<void> {
    if (this.supervisorRunning || !this.conversationId || this.ended) return;
    this.supervisorRunning = true;

    try {
      // 1. Log customer message
      const logResult = await db.logMessage(
        this.conversationId,
        'customer',
        customerText,
        { input_modality: 'audio' },
      );

      // 2. Generate scorecard (parallel to UX, completes in ~200-500ms)
      const scorecard = await generateScorecard(
        customerText,
        this.conversationHistory,
        this.currentStage,
      );

      // 3. Evaluate turn — the deterministic controller
      const evaluation = await db.evaluateTurn(
        this.conversationId,
        scorecard as unknown as Record<string, unknown>,
        logResult.message_id,
      );

      // 4. Update local stage tracking
      if (evaluation.to_stage && evaluation.to_stage !== this.currentStage) {
        this.currentStage = evaluation.to_stage;
        this.sendBrowser({
          type: 'stage',
          stage: evaluation.to_stage,
          objective: evaluation.stage?.objective ?? '',
          control_message: evaluation.control_message,
        });
      }

      // 5. Inject [CONTROL] message into Gemini as system guidance
      if (evaluation.control_message) {
        this.gemini?.sendClientContent(evaluation.control_message);
      }

      // 6. If terminal stage, end the conversation
      if (evaluation.is_terminal && evaluation.suggested_outcome) {
        await this.end(evaluation.suggested_outcome, undefined);
      }
    } catch (err) {
      console.error(`[session:${this.customerId}] Supervisor cycle error:`, err);
    } finally {
      this.supervisorRunning = false;
    }
  }

  private async logAgentMessage(text: string): Promise<void> {
    if (!this.conversationId) return;
    try {
      const result = await db.logMessage(this.conversationId, 'agent', text, {
        input_modality: 'audio',
        model_profile_key: this.startResult?.models.voice_realtime?.key,
      });
      this.activeAgentMessageId = result.message_id;
    } catch (err) {
      console.error(`[session:${this.customerId}] logAgentMessage error:`, err);
    }
  }

  private async handleInterruption(): Promise<void> {
    if (!this.conversationId || !this.activeAgentMessageId) return;
    try {
      const result = await db.logInterruption(
        this.conversationId,
        'real', // assume real interruption — backchannel detection is done by Gemini
        this.activeAgentMessageId,
        this.lastCustomerText,
        0,
        0,
        this.lastCustomerText,
        this.lastOfferCode ?? undefined,
      );
      if (result.control_message) {
        this.gemini?.sendClientContent(result.control_message);
      }
    } catch (err) {
      console.error(`[session:${this.customerId}] handleInterruption error:`, err);
    }
  }

  async end(outcome: string, summary?: string): Promise<void> {
    if (this.ended) return;
    this.ended = true;

    console.log(`[session:${this.customerId}] Ending conversation — outcome: ${outcome}`);

    this.gemini?.close();

    if (this.conversationId) {
      try {
        const result = await db.endConversation(this.conversationId, outcome, summary);
        this.sendBrowser({
          type: 'end',
          outcome,
          summary: summary ?? result.commitment_receipt ?? 'Conversación finalizada.',
        });
      } catch (err) {
        console.error(`[session:${this.customerId}] end_conversation error:`, err);
        this.sendBrowser({ type: 'end', outcome, summary: summary ?? '' });
      }
    } else {
      this.sendBrowser({ type: 'end', outcome, summary: summary ?? '' });
    }
  }

  private sendBrowser(msg: BrowserMessage): void {
    try {
      this.ws.send(JSON.stringify(msg));
    } catch {
      // WS might already be closed
    }
  }
}
