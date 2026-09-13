/**
 * Guardrails deterministas del agente de voz (docs/REGLAS-AGENTE-VOZ.md §5).
 *   G2 inspectCustomer: inyección, datos sensibles, agresión → antes del LLM
 *   G4 OutputGuard: revisa cada frase del agente antes de mandarla a la voz
 * Sin red ni LLM: rápido y predecible. El LLM marca desvíos semánticos con la herramienta registrar_desvio.
 */

export type InputRisk = 'injection' | 'sensitive_data' | 'abuse';

function fold(text: string): string {
  return text.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
}

const INJECTION = [
  /ignora(r)?\s+(todas?\s+)?(tus|las)\s+(instrucciones|reglas)/,
  /olvida(te)?\s+(de\s+)?(tus|las)\s+(instrucciones|reglas)/,
  /(system|sistema)\s*prompt/, /prompt\s+(del\s+)?sistema/,
  /(dime|revela|muestra|lee)(me)?\s+(tus|las)\s+(instrucciones|reglas|prompt)/,
  /modo\s+(desarrollador|developer|dios|admin)/, /\bjailbreak\b/, /\bdan\b\s+mode/,
  /(actua|comportate|finge|haz\s+de\s+cuenta)\s+(como|que\s+eres)/,
  /ahora\s+eres\s+(un|una|otro)/, /eres\s+(chatgpt|gemini|un\s+modelo)/,
  /(que|cual)\s+modelo\s+(eres|usas)/, /\b(openai|anthropic|chatgpt)\b/,
];

const ABUSE = [/\b(hijo\s+de\s+puta|hdp|puta|pendej[oa]|idiota|estupid[oa]|imbecil|maldit[oa]|cerot[oa]|culer[oa]|mierda|verga)\b/];

// 9+ dígitos: tarjeta, cuenta o DUI (un teléfono de El Salvador tiene 8 y no se marca)
const DIGITS = /(?:\d[\s-]?){9,}/g;
const SENSITIVE_WORDS = /\b(mi\s+)?(contrasena|clave|pin|cvv|codigo\s+de\s+(seguridad|verificacion)|numero\s+de\s+(tarjeta|cuenta))\b/;

export function redactSensitive(text: string): string {
  return text.replace(DIGITS, (m) => {
    const digits = m.replace(/\D/g, '');
    return `${'•'.repeat(Math.max(0, digits.length - 4))}${digits.slice(-4)}`;
  });
}

export function inspectCustomer(text: string): { risks: InputRisk[]; redacted: string } {
  const f = fold(text);
  const risks: InputRisk[] = [];
  if (INJECTION.some((r) => r.test(f))) risks.push('injection');
  DIGITS.lastIndex = 0;
  if (DIGITS.test(text) || (SENSITIVE_WORDS.test(f) && /\d/.test(f))) risks.push('sensitive_data');
  if (ABUSE.some((r) => r.test(f))) risks.push('abuse');
  DIGITS.lastIndex = 0;
  return { risks, redacted: redactSensitive(text) };
}

/** Respuestas fijas (no pasan por el LLM). */
export const GUARD_REPLIES = {
  injection: 'Disculpe, en esta llamada solo puedo ayudarle con el pago de su cuota. ¿Continuamos?',
  sensitive_data: 'Por su seguridad, no me comparta contraseñas, PIN ni números de tarjeta o cuenta; no los necesito. ¿Continuamos con su cuota?',
  abuse_1: 'Estoy aquí para ayudarle. Si prefiere, podemos conversar en otro momento. ¿Continuamos con su cuota?',
  abuse_2: 'Entiendo que no es buen momento. Un asesor le dará seguimiento. Le deseo un buen día.',
  off_topic_1: 'Entiendo. En esta llamada solo puedo ayudarle con su cuota. ¿Continuamos?',
  off_topic_2: 'Para ese tema le puede atender un asesor. ¿Desea que le contacten, o terminamos lo de su cuota?',
  off_topic_3: 'Para no quitarle más tiempo, un asesor le dará seguimiento. Agradezco mucho su tiempo y le deseo un excelente día.',
} as const;

// ── Fechas: el agente solo afirma fechas que el banco devolvió (R-NEG-3) ─────
const MONTHS = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
const DAY_WORDS: Record<string, number> = {
  uno: 1, primero: 1, dos: 2, tres: 3, cuatro: 4, cinco: 5, seis: 6, siete: 7, ocho: 8, nueve: 9, diez: 10, once: 11, doce: 12,
  trece: 13, catorce: 14, quince: 15, dieciseis: 16, diecisiete: 17, dieciocho: 18, diecinueve: 19, veinte: 20, veintiuno: 21,
  veintiun: 21, veintidos: 22, veintitres: 23, veinticuatro: 24, veinticinco: 25, veintiseis: 26, veintisiete: 27, veintiocho: 28,
  veintinueve: 29, treinta: 30, 'treinta y uno': 31,
};
const DATE_RE = new RegExp(`\\b(\\d{1,2}|${Object.keys(DAY_WORDS).sort((a, b) => b.length - a.length).join('|')})\\s+de\\s+(${MONTHS.join('|')})\\b`, 'g');
const NEGATION = /\b(no|excede\w*|maxim\w*|limite|lamentablemente|posible|permitid\w*|fuera)\b/;

/** Fechas mencionadas como claves "día-mes" ("martes veintidós de septiembre" → "22-9"). */
export function extractDates(text: string): string[] {
  const out: string[] = [];
  for (const m of fold(text).matchAll(DATE_RE)) {
    const day = /^\d+$/.test(m[1]) ? Number(m[1]) : DAY_WORDS[m[1]];
    if (day) out.push(`${day}-${MONTHS.indexOf(m[2]) + 1}`);
  }
  return out;
}

/** Fecha que se afirma sin validar. Mencionarla para decir que NO se puede está bien. */
export function unvalidatedDate(sentence: string, allowedDates: Set<string>): string | null {
  const dates = extractDates(sentence).filter((d) => !allowedDates.has(d));
  if (!dates.length || NEGATION.test(fold(sentence))) return null;
  return dates[0];
}

// ── G4: salida ──────────────────────────────────────────────────────────────
export type OutputViolation = 'threat' | 'unauthorized_promise' | 'asks_sensitive' | 'leak' | 'url' | 'unvalidated_date';

const OUTPUT_RULES: Array<{ kind: OutputViolation; re: RegExp }> = [
  { kind: 'threat', re: /\b((?<!sin )embarg\w*|demand(a|ar|aremos)\b|juicio|carcel|policia|abogad\w*|boletin\w*|lista\s+negra|visita(remos)?\s+(a\s+)?su|su\s+(familia|empleador|jefe|trabajo)\s+(sabra|se\s+enterara)|consecuencias\s+legales|accion(es)?\s+legal(es)?)/ },
  { kind: 'unauthorized_promise', re: /\b(condon\w*|perdon\w*\s+(la\s+)?deuda|sin\s+(ningun\s+)?interes(es)?|borr\w*\s+(su\s+)?(record|historial)|quedara\s+aprobad[oa]|le\s+aprobamos|garantiz\w*\s+(la\s+)?aprobacion)/ },
  { kind: 'asks_sensitive', re: /\b(su|tu|me\s+(da|dice|comparte|proporciona))\s+(contrasena|clave|pin|cvv|codigo\s+de\s+(seguridad|verificacion)|numero\s+(completo\s+)?de\s+(tarjeta|cuenta))/ },
  { kind: 'leak', re: /(\[control\]|system\s*prompt|mis\s+instrucciones|herramienta|validar_oferta|registrar_compromiso|finalizar_llamada|codigo_oferta|\bjson\b|\{"|modelo\s+de\s+lenguaje|\bgemini\b|\bopenai\b|\bllm\b|puntaje\s+de\s+riesgo|\bgrado\s+[a-e]\b)/ },
  { kind: 'url', re: /(https?:\/\/|www\.|\.com\b|\.sv\b)/ },
];

const SAFE_SENTENCE: Record<OutputViolation, string> = {
  threat: 'Mi objetivo es ayudarle a encontrar una alternativa que le funcione.',
  unauthorized_promise: 'Ese detalle se lo confirma un asesor.',
  asks_sensitive: 'No necesito ningún dato confidencial suyo.',
  leak: '',
  url: 'Le envío el enlace por correo.',
  unvalidated_date: '',
};

/** `allowed`: texto autorizado (condiciones validadas y guiones de ofertas). Una promesa que ya está ahí no es violación. */
export function checkOutput(sentence: string, allowed = ''): OutputViolation | null {
  const f = fold(sentence);
  const ok = fold(allowed);
  for (const rule of OUTPUT_RULES) {
    const m = f.match(rule.re);
    if (!m) continue;
    if (rule.kind === 'unauthorized_promise' && ok.includes(m[0])) continue;
    return rule.kind;
  }
  return null;
}

/**
 * Buffer por frase: libera texto en cada fin de frase o coma larga, ya revisado.
 * La latencia extra es solo hasta el primer signo de puntuación (~decenas de ms de tokens).
 */
export class OutputGuard {
  private buffer = '';
  /** Se detuvo por una fecha sin validar: el turno debe validar antes de seguir hablando. */
  halted = false;
  readonly violations: Array<{ kind: OutputViolation; text: string }> = [];

  constructor(
    private readonly emit: (safe: string) => void,
    private readonly allowed: () => string = () => '',
    private readonly allowedDates: (() => Set<string>) | null = null,
  ) {}

  resume(): void { this.halted = false; this.buffer = ''; }

  push(chunk: string): void {
    if (this.halted) return;
    this.buffer += chunk;
    // corta en . ? ! ; o en coma cuando ya hay suficiente texto (no esperar frases largas)
    const re = /[.?!;…]+\s|,\s(?=\S)/g;
    let cut = -1;
    let m: RegExpExecArray | null;
    while ((m = re.exec(this.buffer))) {
      if (m[0].startsWith(',') && m.index < 25) continue;
      cut = m.index + m[0].length;
    }
    if (cut > 0) {
      const ready = this.buffer.slice(0, cut);
      this.buffer = this.buffer.slice(cut);
      this.release(ready);
    }
  }

  flush(): void {
    if (this.buffer && !this.halted) this.release(this.buffer);
    this.buffer = '';
  }

  private release(text: string): void {
    if (this.halted) return;
    if (this.allowedDates && unvalidatedDate(text, this.allowedDates())) {
      this.violations.push({ kind: 'unvalidated_date', text });
      this.halted = true;
      this.buffer = '';
      return;
    }
    const kind = checkOutput(text, this.allowed());
    if (!kind) { this.emit(text); return; }
    this.violations.push({ kind, text: redactSensitive(text) });
    const safe = SAFE_SENTENCE[kind];
    if (safe) this.emit(`${safe} `);
  }
}
