/**
 * Spanish Date Resolver for voice negotiation.
 *
 * Resolves natural language date references in Salvadoran Spanish into
 * concrete ISO dates (YYYY-MM-DD) and human-friendly labels.
 *
 * Rules:
 *  - "Hoy" is always computed in America/El_Salvador (UTC-6, no DST).
 *  - Output date format: 'YYYY-MM-DD'.
 *  - Output label format: e.g. "viernes 18 de septiembre".
 *  - Confidence: 'high' for explicit dates, 'low' for approximate references like "la próxima semana".
 *  - Vague text ("después", "no sé", "cuando pueda") returns null.
 */

export interface ResolvedDate {
  date: string;
  label: string;
  confidence: 'high' | 'low';
}

const DOW_NAMES = [
  'domingo',
  'lunes',
  'martes',
  'miércoles',
  'jueves',
  'viernes',
  'sábado',
];

const MONTH_NAMES = [
  '',
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

const DOW_MAP: Record<string, number> = {
  domingo: 0,
  dom: 0,
  lunes: 1,
  lun: 1,
  martes: 2,
  mar: 2,
  miercoles: 3,
  miércoles: 3,
  mie: 3,
  mié: 3,
  jueves: 4,
  jue: 4,
  viernes: 5,
  vie: 5,
  sabado: 6,
  sábado: 6,
  sab: 6,
  sáb: 6,
};

const MONTH_MAP: Record<string, number> = {
  enero: 1,
  ene: 1,
  febrero: 2,
  feb: 2,
  marzo: 3,
  mar: 3,
  abril: 4,
  abr: 4,
  mayo: 5,
  may: 5,
  junio: 6,
  jun: 6,
  julio: 7,
  jul: 7,
  agosto: 8,
  ago: 8,
  septiembre: 9,
  setiembre: 9,
  sep: 9,
  set: 9,
  octubre: 10,
  oct: 10,
  noviembre: 11,
  nov: 11,
  diciembre: 12,
  dic: 12,
};

const NUMBER_WORDS: Record<string, number> = {
  uno: 1,
  un: 1,
  primero: 1,
  '1ro': 1,
  '1er': 1,
  dos: 2,
  tres: 3,
  cuatro: 4,
  cinco: 5,
  seis: 6,
  siete: 7,
  ocho: 8,
  nueve: 9,
  diez: 10,
  once: 11,
  doce: 12,
  trece: 13,
  catorce: 14,
  quince: 15,
  dieciseis: 16,
  dieciséis: 16,
  diecisiete: 17,
  dieciocho: 18,
  diecinueve: 19,
  veinte: 20,
  veintiuno: 21,
  veintiun: 21,
  veintiún: 21,
  veintidos: 22,
  veintidós: 22,
  veintitres: 23,
  veintitrés: 23,
  veinticuatro: 24,
  veinticinco: 25,
  veintiseis: 26,
  veintiséis: 26,
  veintisiete: 27,
  veintiocho: 28,
  veintinueve: 29,
  treinta: 30,
  'treinta y uno': 31,
  'treinta y un': 31,
};

const VAGUE_PHRASES = [
  'despues',
  'después',
  'no se',
  'no sé',
  'cuando pueda',
  'cuando tenga',
  'luego',
  'mas adelante',
  'más adelante',
  'mas tarde',
  'más tarde',
  'en estos dias',
  'en estos días',
  'pronto',
  'otro dia',
  'otro día',
  'ya voy a ver',
  'ya vere',
  'ya veré',
  'ahi vemos',
  'ahí vemos',
  'despuesito',
  'despuésito',
];

interface SvDateParts {
  year: number;
  month: number;
  day: number;
  dayOfWeek: number;
}

function getSvParts(d: Date): SvDateParts {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/El_Salvador',
    year: 'numeric',
    month: 'numeric',
    day: 'numeric',
  }).formatToParts(d);

  let year = 0;
  let month = 0;
  let day = 0;

  for (const p of parts) {
    if (p.type === 'year') year = parseInt(p.value, 10);
    if (p.type === 'month') month = parseInt(p.value, 10);
    if (p.type === 'day') day = parseInt(p.value, 10);
  }

  const dt = new Date(Date.UTC(year, month - 1, day, 12, 0, 0));
  const dayOfWeek = dt.getUTCDay();

  return { year, month, day, dayOfWeek };
}

function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

function formatLabel(dow: number, day: number, month: number): string {
  return `${DOW_NAMES[dow]} ${day} de ${MONTH_NAMES[month]}`;
}

function makeResolved(
  year: number,
  month: number,
  day: number,
  confidence: 'high' | 'low' = 'high',
): ResolvedDate | null {
  const maxDay = daysInMonth(year, month);
  if (day < 1 || day > maxDay) return null;

  const dt = new Date(Date.UTC(year, month - 1, day, 12, 0, 0));
  const dow = dt.getUTCDay();

  const yStr = String(year);
  const mStr = String(month).padStart(2, '0');
  const dStr = String(day).padStart(2, '0');

  return {
    date: `${yStr}-${mStr}-${dStr}`,
    label: formatLabel(dow, day, month),
    confidence,
  };
}

function addDaysToParts(base: SvDateParts, n: number): SvDateParts {
  const dt = new Date(Date.UTC(base.year, base.month - 1, base.day + n, 12, 0, 0));
  return {
    year: dt.getUTCFullYear(),
    month: dt.getUTCMonth() + 1,
    day: dt.getUTCDate(),
    dayOfWeek: dt.getUTCDay(),
  };
}

function parseDayNumber(str: string): number | null {
  const clean = str.trim().toLowerCase();
  if (/^\d{1,2}$/.test(clean)) {
    const n = parseInt(clean, 10);
    return n >= 1 && n <= 31 ? n : null;
  }
  return NUMBER_WORDS[clean] ?? null;
}

/**
 * Resolves natural language date references in Spanish.
 */
export function resolveSpanishDate(text: string, now?: Date): ResolvedDate | null {
  if (!text || typeof text !== 'string') return null;

  let clean = text
    .trim()
    .toLowerCase()
    .replace(/[¿?¡!.,;:]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  if (!clean) return null;

  for (const vague of VAGUE_PHRASES) {
    if (clean === vague || clean.startsWith(vague + ' ') || clean.endsWith(' ' + vague)) {
      return null;
    }
  }

  const baseDate = now ?? new Date();
  const current = getSvParts(baseDate);

  // 1. ISO format: YYYY-MM-DD
  const isoMatch = clean.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (isoMatch) {
    const y = parseInt(isoMatch[1], 10);
    const m = parseInt(isoMatch[2], 10);
    const d = parseInt(isoMatch[3], 10);
    return makeResolved(y, m, d, 'high');
  }

  // 2. Relative keywords
  if (clean === 'hoy') {
    return makeResolved(current.year, current.month, current.day, 'high');
  }

  if (clean === 'manana' || clean === 'mañana') {
    const next = addDaysToParts(current, 1);
    return makeResolved(next.year, next.month, next.day, 'high');
  }

  if (
    clean === 'pasado manana' ||
    clean === 'pasado mañana' ||
    clean === 'pasadomanana' ||
    clean === 'pasadomañana'
  ) {
    const next = addDaysToParts(current, 2);
    return makeResolved(next.year, next.month, next.day, 'high');
  }

  // 3. "fin de mes"
  if (clean === 'fin de mes' || clean === 'a fin de mes' || clean === 'al fin de mes') {
    const curLastDay = daysInMonth(current.year, current.month);
    if (current.day < curLastDay) {
      return makeResolved(current.year, current.month, curLastDay, 'high');
    } else {
      let nextMonth = current.month + 1;
      let nextYear = current.year;
      if (nextMonth > 12) {
        nextMonth = 1;
        nextYear += 1;
      }
      const nextLastDay = daysInMonth(nextYear, nextMonth);
      return makeResolved(nextYear, nextMonth, nextLastDay, 'high');
    }
  }

  // 4. "la quincena"
  if (clean === 'la quincena' || clean === 'quincena' || clean === 'a la quincena') {
    const curLastDay = daysInMonth(current.year, current.month);
    if (current.day < 15) {
      return makeResolved(current.year, current.month, 15, 'high');
    } else if (current.day < curLastDay) {
      return makeResolved(current.year, current.month, curLastDay, 'high');
    } else {
      let nextMonth = current.month + 1;
      let nextYear = current.year;
      if (nextMonth > 12) {
        nextMonth = 1;
        nextYear += 1;
      }
      return makeResolved(nextYear, nextMonth, 15, 'high');
    }
  }

  // 5. "la próxima semana" -> lunes siguiente con confidence 'low'
  if (
    clean === 'la proxima semana' ||
    clean === 'la próxima semana' ||
    clean === 'proxima semana' ||
    clean === 'próxima semana'
  ) {
    let daysUntilMon = (1 - current.dayOfWeek + 7) % 7;
    if (daysUntilMon === 0) daysUntilMon = 7;
    const next = addDaysToParts(current, daysUntilMon);
    return makeResolved(next.year, next.month, next.day, 'low');
  }

  // 6. "en N días" / "en una semana" / "en quince días"
  const inDaysMatch = clean.match(
    /^en\s+(un|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|quince|\d+)\s+(dias|días|semanas?|mes(?:es)?)$/,
  );
  if (inDaysMatch) {
    const rawNum = inDaysMatch[1];
    const unit = inDaysMatch[2];
    let count = 0;

    if (rawNum === 'un' || rawNum === 'una') count = 1;
    else if (/^\d+$/.test(rawNum)) count = parseInt(rawNum, 10);
    else count = NUMBER_WORDS[rawNum] ?? 0;

    if (count > 0) {
      if (unit.startsWith('semana')) {
        const next = addDaysToParts(current, count * 7);
        return makeResolved(next.year, next.month, next.day, 'high');
      } else if (unit.startsWith('dia') || unit.startsWith('día')) {
        const next = addDaysToParts(current, count);
        return makeResolved(next.year, next.month, next.day, 'high');
      } else if (unit.startsWith('mes')) {
        let targetMonth = current.month + count;
        let targetYear = current.year;
        while (targetMonth > 12) {
          targetMonth -= 12;
          targetYear += 1;
        }
        const maxD = daysInMonth(targetYear, targetMonth);
        const targetDay = Math.min(current.day, maxD);
        return makeResolved(targetYear, targetMonth, targetDay, 'high');
      }
    }
  }

  // 7. Days of week: "el próximo viernes", "el otro viernes", "el viernes", "este viernes", "viernes"
  const nextDowMatch = clean.match(
    /^(?:el\s+)?(?:pr[oó]ximo|otro)\s+(domingo|lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bado)$/,
  );
  if (nextDowMatch) {
    const dowKey = nextDowMatch[1];
    const targetDow = DOW_MAP[dowKey];
    if (targetDow !== undefined) {
      let daysToAdd = (targetDow - current.dayOfWeek + 7) % 7;
      if (daysToAdd === 0) daysToAdd = 7;
      // Claude's rule: "el próximo viernes"/"el otro viernes" = esa ocurrencia + 7 días si cae dentro de los próximos 6 días
      if (daysToAdd <= 6) {
        daysToAdd += 7;
      }
      const next = addDaysToParts(current, daysToAdd);
      return makeResolved(next.year, next.month, next.day, 'high');
    }
  }

  const thisDowMatch = clean.match(
    /^(?:el\s+|este\s+)?(domingo|lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bado)$/,
  );
  if (thisDowMatch) {
    const dowKey = thisDowMatch[1];
    const targetDow = DOW_MAP[dowKey];
    if (targetDow !== undefined) {
      let daysToAdd = (targetDow - current.dayOfWeek + 7) % 7;
      if (daysToAdd === 0) daysToAdd = 7;
      const next = addDaysToParts(current, daysToAdd);
      return makeResolved(next.year, next.month, next.day, 'high');
    }
  }

  // 8. Specific date with month: "25 de septiembre", "el 3 de octubre", "el veinticinco de septiembre", "el 15 de enero del 2027"
  const dateWithMonthMatch = clean.match(
    /^(?:el\s+)?([a-z0-9\s]+?)\s+de\s+([a-z]+)(?:\s+del?\s+(\d{4}))?$/,
  );
  if (dateWithMonthMatch) {
    const dayPart = dateWithMonthMatch[1].trim();
    const monthPart = dateWithMonthMatch[2].trim();
    const yearPart = dateWithMonthMatch[3];

    const targetDay = parseDayNumber(dayPart);
    const targetMonth = MONTH_MAP[monthPart];

    if (targetDay !== null && targetMonth !== undefined) {
      let targetYear = yearPart ? parseInt(yearPart, 10) : current.year;

      if (!yearPart) {
        if (
          targetMonth < current.month ||
          (targetMonth === current.month && targetDay <= current.day)
        ) {
          targetYear += 1;
        }
      }

      return makeResolved(targetYear, targetMonth, targetDay, 'high');
    }
  }

  // 9. Day of month only: "el 25", "el veinticinco", "el 3", "25", "veinticinco"
  const dayOnlyMatch = clean.match(/^(?:el\s+)?([a-z0-9\s]+)$/);
  if (dayOnlyMatch) {
    const dayPart = dayOnlyMatch[1].trim();
    const targetDay = parseDayNumber(dayPart);

    if (targetDay !== null) {
      let targetYear = current.year;
      let targetMonth = current.month;

      // "sin mes y día ya pasado -> mes siguiente" (estrictamente después de hoy)
      if (targetDay <= current.day) {
        targetMonth += 1;
        if (targetMonth > 12) {
          targetMonth = 1;
          targetYear += 1;
        }
      }

      return makeResolved(targetYear, targetMonth, targetDay, 'high');
    }
  }

  return null;
}
