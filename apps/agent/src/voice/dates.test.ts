import assert from 'node:assert';
import { resolveSpanishDate } from './dates.js';

console.log('🧪 Corriendo tests de dates.ts...');

// Base date: Sábado 12 de septiembre de 2026, 15:00 en America/El_Salvador
const BASE_NOW = new Date('2026-09-12T15:00:00-06:00');

let testsPassed = 0;

function check(
  input: string,
  expectedDate: string | null,
  expectedLabel?: string,
  expectedConfidence?: 'high' | 'low',
  customNow?: Date,
) {
  const result = resolveSpanishDate(input, customNow ?? BASE_NOW);

  if (expectedDate === null) {
    assert.strictEqual(
      result,
      null,
      `Esperaba null para "${input}", pero obtuve ${JSON.stringify(result)}`,
    );
  } else {
    assert.ok(result !== null, `Esperaba resultado para "${input}", pero obtuve null`);
    assert.strictEqual(
      result.date,
      expectedDate,
      `Fecha incorrecta para "${input}": esperada ${expectedDate}, obtenida ${result.date}`,
    );
    if (expectedLabel) {
      assert.strictEqual(
        result.label,
        expectedLabel,
        `Label incorrecto para "${input}": esperado "${expectedLabel}", obtenido "${result.label}"`,
      );
    }
    if (expectedConfidence) {
      assert.strictEqual(
        result.confidence,
        expectedConfidence,
        `Confidence incorrecto para "${input}": esperado ${expectedConfidence}, obtenido ${result.confidence}`,
      );
    }
  }
  testsPassed++;
}

// 1. Relativos básicos
check('hoy', '2026-09-12', 'sábado 12 de septiembre', 'high');
check('mañana', '2026-09-13', 'domingo 13 de septiembre', 'high');
check('manana', '2026-09-13', 'domingo 13 de septiembre', 'high');
check('pasado mañana', '2026-09-14', 'lunes 14 de septiembre', 'high');
check('pasado manana', '2026-09-14', 'lunes 14 de septiembre', 'high');

// 2. Días de la semana ("el X" o "este X" -> estrictamente después de hoy)
// Hoy es sábado 12 de sep. El próximo lunes es 14, martes 15, ..., viernes 18.
check('el lunes', '2026-09-14', 'lunes 14 de septiembre', 'high');
check('este martes', '2026-09-15', 'martes 15 de septiembre', 'high');
check('el miércoles', '2026-09-16', 'miércoles 16 de septiembre', 'high');
check('miercoles', '2026-09-16', 'miércoles 16 de septiembre', 'high');
check('el jueves', '2026-09-17', 'jueves 17 de septiembre', 'high');
check('el viernes', '2026-09-18', 'viernes 18 de septiembre', 'high');
check('este viernes', '2026-09-18', 'viernes 18 de septiembre', 'high');
check('el sábado', '2026-09-19', 'sábado 19 de septiembre', 'high');
check('sabado', '2026-09-19', 'sábado 19 de septiembre', 'high');

// 3. "el próximo [día]" / "el otro [día]" (cae dentro de 6 días -> suma 7)
// Próximo viernes: el viernes 18 cae en 6 días (<=6), así que es el viernes 25
check('el próximo viernes', '2026-09-25', 'viernes 25 de septiembre', 'high');
check('el proximo viernes', '2026-09-25', 'viernes 25 de septiembre', 'high');
check('el otro viernes', '2026-09-25', 'viernes 25 de septiembre', 'high');
// Próximo lunes: lunes 14 cae en 2 días (<=6), así que es lunes 21
check('el próximo lunes', '2026-09-21', 'lunes 21 de septiembre', 'high');

// 4. "en N días", "en una semana", "en quince días"
check('en 3 días', '2026-09-15', 'martes 15 de septiembre', 'high');
check('en 3 dias', '2026-09-15', 'martes 15 de septiembre', 'high');
check('en una semana', '2026-09-19', 'sábado 19 de septiembre', 'high');
check('en 1 semana', '2026-09-19', 'sábado 19 de septiembre', 'high');
check('en dos semanas', '2026-09-26', 'sábado 26 de septiembre', 'high');
check('en quince días', '2026-09-27', 'domingo 27 de septiembre', 'high');
check('en 15 días', '2026-09-27', 'domingo 27 de septiembre', 'high');

// 5. Día del mes solo: día > hoy -> este mes; día <= hoy -> mes siguiente
check('el 25', '2026-09-25', 'viernes 25 de septiembre', 'high');
check('el veinticinco', '2026-09-25', 'viernes 25 de septiembre', 'high');
check('el 3', '2026-10-03', 'sábado 3 de octubre', 'high');
check('el tres', '2026-10-03', 'sábado 3 de octubre', 'high');
check('el doce', '2026-10-12', 'lunes 12 de octubre', 'high'); // hoy es 12 -> mes siguiente

// 6. Día con mes explícito
check('25 de septiembre', '2026-09-25', 'viernes 25 de septiembre', 'high');
check('el 3 de octubre', '2026-10-03', 'sábado 3 de octubre', 'high');
check('el veinticinco de septiembre', '2026-09-25', 'viernes 25 de septiembre', 'high');
check('el primero de octubre', '2026-10-01', 'jueves 1 de octubre', 'high');

// 7. Hitos comerciales: fin de mes y quincena
check('fin de mes', '2026-09-30', 'miércoles 30 de septiembre', 'high');
check('la quincena', '2026-09-15', 'martes 15 de septiembre', 'high');

// 8. "la próxima semana" -> lunes siguiente con low confidence
check('la próxima semana', '2026-09-14', 'lunes 14 de septiembre', 'low');
check('la proxima semana', '2026-09-14', 'lunes 14 de septiembre', 'low');

// 9. ISO YYYY-MM-DD directo
check('2026-11-20', '2026-11-20', 'viernes 20 de noviembre', 'high');

// 10. Cruces de quincena y mes (con fecha base personalizada)
// Si hoy es 18 de septiembre, la siguiente quincena es el 30 (fin de mes)
const MID_SEP = new Date('2026-09-18T10:00:00-06:00');
check('la quincena', '2026-09-30', 'miércoles 30 de septiembre', 'high', MID_SEP);

// Si hoy es 30 de septiembre (último día), la quincena es el 15 de octubre
const END_SEP = new Date('2026-09-30T10:00:00-06:00');
check('la quincena', '2026-10-15', 'jueves 15 de octubre', 'high', END_SEP);
check('fin de mes', '2026-10-31', 'sábado 31 de octubre', 'high', END_SEP);

// 11. Cruces de año (con fecha base en diciembre)
const DEC_DATE = new Date('2026-12-20T10:00:00-06:00');
// "el 5" en dic 20 -> 5 de enero de 2027
check('el 5', '2027-01-05', 'martes 5 de enero', 'high', DEC_DATE);
check('el cinco', '2027-01-05', 'martes 5 de enero', 'high', DEC_DATE);
// "el 15 de enero" desde diciembre -> enero 2027
check('15 de enero', '2027-01-15', 'viernes 15 de enero', 'high', DEC_DATE);
// "fin de mes" en 31 de diciembre -> fin de enero 2027
const END_DEC = new Date('2026-12-31T20:00:00-06:00');
check('fin de mes', '2027-01-31', 'domingo 31 de enero', 'high', END_DEC);

// 12. Textos vagos que deben retornar null
check('después', null);
check('despues', null);
check('no sé', null);
check('no se', null);
check('cuando pueda', null);
check('cuando tenga dinero', null);
check('luego', null);
check('más adelante', null);
check('pronto', null);
check('otro día', null);
check('', null);
check('   ', null);

console.log(`✅ ¡Todos los ${testsPassed} casos de prueba pasaron exitosamente!`);
