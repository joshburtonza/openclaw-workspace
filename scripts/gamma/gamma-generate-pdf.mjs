#!/usr/bin/env node
/**
 * Gamma Generate API → PDF export
 *
 * Requirements:
 * - env GAMMA_API_KEY (load from ~/.openclaw/secrets/gamma.env)
 *
 * Usage:
 *   node gamma-generate-pdf.mjs --title "Ascend Weekly Report" --themeId chimney-smoke --numCards 18 --in input.md --out /tmp/ascend-weekly.pdf
 */

import fs from 'node:fs/promises';
import path from 'node:path';

const API_BASE = 'https://public-api.gamma.app/v1.0';
const UA = 'Mozilla/5.0 (OpenClaw)';

function arg(name, def = undefined) {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx === -1) return def;
  const val = process.argv[idx + 1];
  if (!val || val.startsWith('--')) return true;
  return val;
}

async function sleep(ms) {
  await new Promise(r => setTimeout(r, ms));
}

async function requestJson(url, { method = 'GET', headers = {}, body } = {}) {
  const res = await fetch(url, {
    method,
    headers: {
      'User-Agent': UA,
      'accept': 'application/json',
      ...headers,
    },
    body,
  });

  const text = await res.text();
  let json;
  try { json = text ? JSON.parse(text) : null; } catch { json = { raw: text }; }

  if (!res.ok) {
    const err = new Error(`HTTP ${res.status} ${res.statusText}`);
    err.details = json;
    throw err;
  }

  return json;
}

async function downloadFile(url, outPath) {
  const res = await fetch(url, { headers: { 'User-Agent': UA } });
  if (!res.ok) throw new Error(`Download failed: HTTP ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  await fs.mkdir(path.dirname(outPath), { recursive: true });
  await fs.writeFile(outPath, buf);
  return { bytes: buf.length };
}

async function main() {
  const apiKey = process.env.GAMMA_API_KEY;
  if (!apiKey) {
    console.error('Missing env GAMMA_API_KEY');
    process.exit(2);
  }

  const title = arg('title', 'Weekly Client Report');
  const themeId = arg('themeId', 'chimney-smoke');
  const numCards = Number(arg('numCards', '16'));
  const inFile = arg('in');
  const outFile = arg('out', `/tmp/gamma-${Date.now()}.pdf`);

  if (!inFile) {
    console.error('Missing --in <input.md>');
    process.exit(2);
  }

  const inputText = await fs.readFile(inFile, 'utf8');

  const createPayload = {
    inputText,
    textMode: 'generate',
    format: 'presentation',
    themeId,
    numCards,
    cardSplit: 'auto',
    additionalInstructions: `Use the Chimney Smoke theme. Make this card-heavy. Title: ${title}. Use clear sections: What we shipped last week, What we are doing next week, Risks or blockers, Decisions needed. Keep it client-friendly.`,
    exportAs: 'pdf',
  };

  const create = await requestJson(`${API_BASE}/generations`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-API-KEY': apiKey,
    },
    body: JSON.stringify(createPayload),
  });

  const generationId = create?.generationId;
  if (!generationId) throw new Error(`No generationId in response: ${JSON.stringify(create)}`);

  const startedAt = Date.now();
  const timeoutMs = 5 * 60 * 1000;

  while (true) {
    const status = await requestJson(`${API_BASE}/generations/${generationId}`, {
      headers: { 'X-API-KEY': apiKey },
    });

    if (status?.status === 'completed') {
      if (!status.exportUrl) throw new Error(`Completed but missing exportUrl: ${JSON.stringify(status)}`);
      const dl = await downloadFile(status.exportUrl, outFile);
      console.log(JSON.stringify({
        ok: true,
        generationId,
        gammaUrl: status.gammaUrl,
        exportUrl: status.exportUrl,
        outFile,
        bytes: dl.bytes,
        credits: status.credits,
      }, null, 2));
      return;
    }

    if (status?.status === 'failed') {
      throw new Error(`Generation failed: ${JSON.stringify(status)}`);
    }

    if (Date.now() - startedAt > timeoutMs) {
      throw new Error(`Timed out waiting for generation ${generationId}`);
    }

    await sleep(3000);
  }
}

main().catch(err => {
  console.error(err?.message || err);
  if (err?.details) console.error(JSON.stringify(err.details, null, 2));
  process.exit(1);
});
