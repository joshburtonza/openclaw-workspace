#!/usr/bin/env node
/**
 * search-flights.mjs
 * Searches FlySafair or Lift for available flights using Playwright.
 *
 * Usage:
 *   node search-flights.mjs --from CPT --to JNB --date 2026-03-06 --airline flysafair
 *   node search-flights.mjs --from CPT --to JNB --date 2026-03-06 --airline lift
 *
 * Outputs JSON to stdout:
 *   { ok: true, flights: [...], airline, from, to, date }
 *
 * Lift note: results page is protected by Imperva WAF + hCaptcha.
 *   First run: browser opens visibly so you can solve captcha once.
 *   Subsequent runs: persistent profile reuses the bypass cookie automatically.
 */

import { chromium } from 'playwright';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { existsSync, mkdirSync } from 'fs';
import { tmpdir } from 'os';

function arg(name, def = undefined) {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx === -1) return def;
  return process.argv[idx + 1];
}

const FROM    = (arg('from') || 'CPT').toUpperCase();
const TO      = (arg('to')   || 'JNB').toUpperCase();
const DATE    = arg('date');   // YYYY-MM-DD
const AIRLINE = (arg('airline') || 'lift').toLowerCase();
const RETURN  = arg('return'); // YYYY-MM-DD optional
const ADULTS  = parseInt(arg('adults') || '1', 10);

if (!DATE) {
  console.error(JSON.stringify({ ok: false, error: 'Missing --date (YYYY-MM-DD)' }));
  process.exit(1);
}

const __dirname = dirname(fileURLToPath(import.meta.url));

async function searchFlySafair() {
  // FlySafair uses EzyFlight/Sabre API — call it directly, no browser needed.
  // Headers captured from browser session; agi18277 + tenant-identifier are static app-level keys.
  process.stderr.write(`[flysafair] API search: ${FROM}→${TO} on ${DATE}\n`);

  const body = {
    languageCode: 'en-za',
    currency: 'ZAR',
    passengers: [{ code: 'ADT', count: ADULTS }],
    routes: [{
      fromAirport: FROM,
      toAirport: TO,
      startDate: DATE,
      endDate: DATE,
      departureDate: null,
      segmentKey: null,
      cabin: null,
    }],
    promoCode: '',
    filterMethod: '102',
    fareTypeCategories: [1],
    isManageBooking: false,
    sanlamSubscriptionId: null,
    externalProfileId: null,
    fareTypeFilters: [],
    fareClass: null,
  };

  const resp = await fetch('https://safair-api-ase1.ezycommerce.sabre.com/api/v1/Availability/SearchShop', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json;charset=UTF-8',
      'languagecode': 'en-za',
      'agi18277': 'GQC40317MXL60244',
      'tenant-identifier': 'f0fb7f8d0f5e6fc0df2506194e74e94367f1a351de7aee12685e5a1da70464ff',
      'appcontext': 'ibe',
      'x-clientversion': '0.5.3926-safair-2026-02-12',
      'channel': 'web',
      'accept': 'text/plain',
    },
    body: JSON.stringify(body),
  });

  if (!resp.ok) throw new Error(`FlySafair API error: ${resp.status} ${await resp.text().catch(() => '')}`);
  const data = await resp.json();

  const allFlights = data?.routes?.[0]?.flights || [];
  // Filter out flights with no price (lowestPriceTotal === 0 means no fare available)
  const rawFlights = allFlights.filter(f => f.lowestPriceTotal > 0);
  process.stderr.write(`[flysafair] got ${rawFlights.length} priced flights (${allFlights.length - rawFlights.length} unpriceable filtered)\n`);

  return rawFlights.map((f, i) => {
    const dep = f.departureDate ? f.departureDate.split('T')[1].slice(0, 5) : null;
    const arr = f.arrivalDate   ? f.arrivalDate.split('T')[1].slice(0, 5)   : null;
    let duration = null;
    if (f.departureDate && f.arrivalDate) {
      const mins = Math.round((new Date(f.arrivalDate) - new Date(f.departureDate)) / 60000);
      duration = `${Math.floor(mins / 60)}:${String(mins % 60).padStart(2, '0')}`;
    }
    return {
      index:     i + 1,
      departure: dep,
      arrival:   arr,
      duration,
      flight:    `${f.carrierCode}${f.flightNumber}`,
      price:     f.lowestPriceTotal != null ? `R${Math.round(f.lowestPriceTotal)}` : null,
      priceNum:  f.lowestPriceTotal || null,
      stops:     'Non-stop',
      raw:       `${f.carrierCode}${f.flightNumber} ${dep}→${arr} R${Math.round(f.lowestPriceTotal || 0)}`,
    };
  });
}

async function searchLift() {
  // Lift.co.za uses AeroCRS. Direct results URL pattern (bypasses the booking form):
  // https://www.lift.co.za/flight-results/{FROM}-{TO}/{YYYY-MM-DD}/{return-date-or-NA}/1/0/0
  //
  // The results page is protected by Imperva WAF + hCaptcha.
  // Solution: persistent Chrome profile stored in .lift-profile/
  //   - First run: headless=false so Josh can solve the checkbox captcha once
  //   - Subsequent runs: Imperva bypass cookie reused automatically (headless=true)

  const LIFT_ROUTES = new Set(['CPT-JNB', 'JNB-CPT', 'CPT-DUR', 'DUR-CPT', 'JNB-DUR', 'DUR-JNB']);
  const route = `${FROM}-${TO}`;
  if (!LIFT_ROUTES.has(route)) {
    throw new Error(`Lift only flies CPT/JNB/DUR — unsupported route: ${route}`);
  }

  const returnPart = RETURN || 'NA';
  const resultsUrl = `https://www.lift.co.za/flight-results/${route}/${DATE}/${returnPart}/${ADULTS}/0/0`;

  // Use real Chrome binary — far less detectable by Imperva than Playwright's Chromium.
  // Use FROM-specific profile dirs so parallel searches (CPT↔JNB) don't conflict.
  const CHROME_PATH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  const profileDir = join(__dirname, `.lift-profile-${FROM}`);
  if (!existsSync(profileDir)) mkdirSync(profileDir, { recursive: true });

  const hasCookies = existsSync(join(profileDir, 'Default', 'Cookies'));
  process.stderr.write(`[lift] url: ${resultsUrl}\n`);
  process.stderr.write(`[lift] using real Chrome, profile: ${hasCookies ? 'existing' : 'new'}\n`);

  const context = await chromium.launchPersistentContext(profileDir, {
    executablePath: CHROME_PATH,
    headless: false,   // Real Chrome headed mode — Imperva cannot distinguish from a real user
    args: [
      '--no-sandbox',
      '--disable-blink-features=AutomationControlled',
    ],
    ignoreDefaultArgs: ['--enable-automation'],
  });

  const page = await context.newPage();

  // Override webdriver flag regardless
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  });

  try {
    await page.goto(resultsUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(2000);

    // Check if Imperva blocked us
    const isBlocked = await page.evaluate(() =>
      document.title.includes('security') ||
      document.body.innerText.includes('Additional security check') ||
      document.body.innerText.includes('I am human') ||
      document.body.innerText.includes('hcaptcha')
    );

    if (isBlocked) {
      process.stderr.write('[lift] Imperva security check triggered — waiting up to 30s for auto-pass or manual solve...\n');
      // Real Chrome often auto-passes; wait for it
      await page.waitForURL(
        url => !url.toString().includes('_Incapsula') && !url.toString().includes('security'),
        { timeout: 30000 }
      ).catch(() => {});
      await page.waitForTimeout(3000);
    }

    // Dismiss cookie preferences modal if present
    await page.locator('button:has-text("ACCEPT ALL COOKIES"), button:has-text("Accept All Cookies")').first().click().catch(() => {});
    await page.waitForTimeout(500);

    // Dismiss Imperva error modal if it appears (close X button)
    await page.locator('.modal .close, .modal-close, button.close, [aria-label="Close"], .modal × ').first().click().catch(() => {});
    // Also try clicking the X in the error modal
    await page.evaluate(() => {
      const modals = document.querySelectorAll('.modal, [class*="modal"], [id*="modal"]');
      modals.forEach(m => {
        const closeBtn = m.querySelector('.close, [aria-label="Close"], button');
        if (closeBtn) closeBtn.click();
      });
    }).catch(() => {});
    await page.waitForTimeout(1000);

    // Wait for the AeroCRS results widget to fully render
    await page.waitForTimeout(3000);

    // Screenshot for debug
    const shotPath = join(tmpdir(), `lift-results-${Date.now()}.png`);
    await page.screenshot({ path: shotPath, fullPage: false });
    process.stderr.write(`[lift] screenshot: ${shotPath}\n`);

    // Parse flight results: find compact elements containing exactly one FLIGHT code
    const flights = await page.evaluate(() => {
      const results = [];

      // Find elements that contain exactly one "FLIGHT XXXX" code + a price
      // Elements with multiple FLIGHT codes are parent containers — exclude them
      let candidates = Array.from(document.querySelectorAll('*')).filter(el => {
        const t = el.innerText || '';
        const flightMatches = t.match(/FLIGHT\s+[A-Z0-9]+/gi) || [];
        return flightMatches.length === 1 && /R\s?\d[\d,]+/.test(t) && t.length < 500;
      });

      // Sort shortest first (most specific element)
      candidates.sort((a, b) => a.innerText.length - b.innerText.length);

      // Deduplicate by flight code
      const seenFlights = new Set();
      const rows = [];
      for (const el of candidates) {
        const fm = (el.innerText || '').match(/FLIGHT\s+([A-Z0-9]+)/i);
        if (fm && !seenFlights.has(fm[1])) {
          seenFlights.add(fm[1]);
          rows.push(el);
          if (rows.length >= 8) break;
        }
      }

      rows.forEach((card, i) => {
        const text = card.innerText || '';
        // Times appear as: departure (HH:MM) | duration (HH:MM) | arrival (HH:MM)
        const timeMatches = text.match(/\b\d{2}:\d{2}\b/g) || [];
        const priceMatch  = text.match(/R\s?([\d,]+)/);
        const flightMatch = text.match(/FLIGHT\s+([A-Z0-9]+)/i);
        const stopMatch   = text.match(/Non.stop|Connecting/i);
        results.push({
          index:     i + 1,
          departure: timeMatches[0] || null,
          arrival:   timeMatches[2] || timeMatches[1] || null,  // skip duration at index 1
          duration:  timeMatches[1] || null,
          flight:    flightMatch ? flightMatch[1] : null,
          price:     priceMatch  ? 'R' + priceMatch[1].replace(/,/g, '') : null,
          stops:     stopMatch ? stopMatch[0] : null,
          raw:       text.slice(0, 200).replace(/\n+/g, ' | ').trim(),
        });
      });

      return results;
    });

    await context.close();
    return flights;

  } catch (err) {
    await context.close();
    throw err;
  }
}

async function main() {
  try {
    let flights;
    if (AIRLINE === 'lift') {
      flights = await searchLift();
    } else {
      flights = await searchFlySafair();
    }

    console.log(JSON.stringify({
      ok: true,
      airline: AIRLINE,
      from: FROM,
      to: TO,
      date: DATE,
      return: RETURN || null,
      flights,
    }, null, 2));

  } catch (err) {
    console.log(JSON.stringify({ ok: false, error: err.message }));
    process.exit(1);
  }
}

main();
