/**
 * Plantilla de correo con el formato de los avisos de Banco Agrícola:
 * encabezado con logo, "Estimado(a) NOMBRE.", "Por este medio…", bloque "Datos de …",
 * firma "Atentamente, Banco Agrícola" y "Mensaje automático, por favor no responder."
 * HTML en tablas con estilos en línea (Gmail/Outlook ignoran <style> y flexbox).
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { InlineImage } from '../lib/resend.js';

const ASSETS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../assets/email');

const BRAND = { yellow: '#fdda24', ink: '#2c2a29', muted: '#6b6e66', line: '#e7e8e4', surface: '#f7f8f4', green: '#00b398' };

export type EmailDetail = [label: string, value: string];
export type EmailButton = { label: string; url: string } | null;
export type EmailVideo = { title: string; url: string; duration: number } | null;

export interface BankEmail {
  customerName: string;       // nombre completo del cliente
  intro: string[];            // "Por este medio le…"
  detailsTitle: string;       // "Datos de su cuota:"
  details: EmailDetail[];
  closing?: string[];         // párrafos después de los datos
  button?: EmailButton;
  video?: EmailVideo;
}

let images: InlineImage[] | null = null;
/** Logos incrustados por CID: se ven aunque la web corra en localhost. */
export function emailImages(): InlineImage[] {
  images ??= [
    { filename: 'bancoagricola-logo-blanco.png', contentId: 'bancoagricola-logo', contentBase64: fs.readFileSync(path.join(ASSETS, 'logo-blanco.png')).toString('base64') },
  ];
  return images;
}

export function escapeHtml(value: string): string {
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/** Formato de los avisos del banco: MAYÚSCULAS sin tildes ("JOSUE EDUARDO GARCIA ESTRADA"). */
export function bankName(fullName: string): string {
  return fullName.normalize('NFD').replace(/[̀-ͯ]/g, '').toUpperCase().trim();
}

export function renderBankEmail(email: BankEmail): { html: string; text: string } {
  const p = (text: string) => `<p style="margin:0 0 16px;font-size:15px;line-height:1.6;color:${BRAND.ink}">${escapeHtml(text)}</p>`;
  const rows = email.details.map(([label, value], index) => `
          <tr>
            <td style="padding:11px 16px;font-size:14px;color:${BRAND.muted};width:44%;${index ? `border-top:1px solid ${BRAND.line};` : ''}">${escapeHtml(label)}</td>
            <td style="padding:11px 16px;font-size:14px;color:${BRAND.ink};font-weight:600;${index ? `border-top:1px solid ${BRAND.line};` : ''}">${escapeHtml(value)}</td>
          </tr>`).join('');
  const button = email.button ? `
        <table role="presentation" cellpadding="0" cellspacing="0" style="margin:8px 0 24px"><tr>
          <td style="background:${BRAND.yellow};border-radius:8px">
            <a href="${escapeHtml(email.button.url)}" style="display:inline-block;padding:13px 26px;font-size:15px;font-weight:700;color:${BRAND.ink};text-decoration:none">${escapeHtml(email.button.label)}</a>
          </td>
        </tr></table>` : '';
  const video = email.video ? `
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;background:${BRAND.surface};border-radius:10px"><tr>
          <td style="padding:14px 16px;font-size:14px;line-height:1.5;color:${BRAND.ink}">
            <strong>Educación financiera · ${escapeHtml(email.video.title)}</strong> (${email.video.duration} s)<br/>
            <a href="${escapeHtml(email.video.url)}" style="color:${BRAND.ink};font-weight:600">Ver el video</a>
          </td>
        </tr></table>` : '';

  const html = `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Banco Agrícola</title></head>
<body style="margin:0;padding:0;background:#eceee8;font-family:Arial,Helvetica,sans-serif">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#eceee8"><tr><td align="center" style="padding:24px 12px">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:12px;overflow:hidden">
      <tr><td style="background:${BRAND.ink};padding:22px 28px">
        <img src="cid:bancoagricola-logo" width="190" alt="Banco Agrícola" style="display:block;width:190px;max-width:60%;height:auto;border:0">
      </td></tr>
      <tr><td style="background:${BRAND.yellow};height:5px;line-height:5px;font-size:0">&nbsp;</td></tr>
      <tr><td style="padding:30px 28px 8px">
        <p style="margin:0 0 20px;font-size:15px;line-height:1.6;color:${BRAND.ink}">Estimado(a) <strong>${escapeHtml(bankName(email.customerName))}</strong>.</p>
        ${email.intro.map(p).join('')}
        <p style="margin:8px 0 10px;font-size:15px;font-weight:700;color:${BRAND.ink}">${escapeHtml(email.detailsTitle)}</p>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;border:1px solid ${BRAND.line};border-radius:10px;border-collapse:separate">${rows}
        </table>
        ${(email.closing ?? []).map(p).join('')}
        ${button}
        ${video}
        <p style="margin:0 0 4px;font-size:15px;color:${BRAND.ink}">Atentamente,</p>
        <p style="margin:0 0 26px;font-size:15px;font-weight:700;color:${BRAND.ink}">Banco Agrícola</p>
      </td></tr>
      <tr><td style="padding:16px 28px 22px;border-top:1px solid ${BRAND.line};background:${BRAND.surface}">
        <p style="margin:0 0 6px;font-size:12px;color:${BRAND.muted}">Mensaje automático, por favor no responder.</p>
        <p style="margin:0;font-size:11px;color:#9a9d92">Mensaje de demostración · Entropía Hack 2026 · datos ficticios. Banco Agrícola nunca le pedirá contraseñas ni códigos por correo.</p>
      </td></tr>
    </table>
  </td></tr></table>
</body></html>`;

  const text = [
    `Estimado(a) ${bankName(email.customerName)}.`, '',
    ...email.intro, '',
    email.detailsTitle, '',
    ...email.details.map(([label, value]) => `${label}: ${value}`), '',
    ...(email.closing ?? []),
    email.button ? `\n${email.button.label}: ${email.button.url}` : '',
    email.video ? `\nVideo: ${email.video.title} — ${email.video.url}` : '',
    '', 'Atentamente,', 'Banco Agrícola', '',
    'Mensaje automático, por favor no responder.',
    'Mensaje de demostración · datos ficticios.',
  ].join('\n');

  return { html, text };
}
