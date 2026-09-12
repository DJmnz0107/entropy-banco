/**
 * WebSocket route: /ws/voice/:customer_id
 *
 * The browser connects here to start a voice call.
 * Each connection spawns a VoiceSession.
 */

import type { WebSocketServer, WebSocket } from 'ws';
import { VoiceSession } from '../voice/session.js';

export function setupVoiceWs(wss: WebSocketServer): void {
  wss.on('connection', (ws: WebSocket, req) => {
    const url = new URL(req.url ?? '', `http://${req.headers.host ?? 'localhost'}`);
    const match = url.pathname.match(/\/ws\/voice\/([^/?]+)/);

    if (!match) {
      ws.close(1008, 'Ruta inválida. Usa /ws/voice/:customer_id');
      return;
    }

    const customerId = match[1];
    console.log(`[ws] New connection for customer: ${customerId}`);
    const session = new VoiceSession(customerId, ws);
    void session.start();

    ws.on('message', (data) => {
      const raw = typeof data === 'string' ? data : Buffer.from(data as ArrayBuffer).toString();
      session.handleBrowserMessage(raw);
    });

    ws.on('close', () => {
      console.log(`[ws] Connection closed for customer: ${customerId}`);
      void session.end('COMPLETED_AGENT', 'WebSocket cerrado por el navegador.');
    });

    ws.on('error', (err) => {
      console.error(`[ws] Error for customer: ${customerId}`, err);
      void session.end('ERROR', 'Error de WebSocket.');
    });
  });
}
