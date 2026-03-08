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
  // Lift.co.za uses a PHP middleware wrapping AeroCRS internally.
  // Strategy: navigate to the results URL (establishes PHPSESSID), then call their
  // internal flightList.php endpoint from within the page context using fetch().
  // This avoids all DOM parsing, screenshots, and element hunting — pure JSON response.

  const LIFT_ROUTES = new Set(['CPT-JNB', 'JNB-CPT', 'CPT-DUR', 'DUR-CPT', 'JNB-DUR', 'DUR-JNB']);
  const route = `${FROM}-${TO}`;
  if (!LIFT_ROUTES.has(route)) {
    throw new Error(`Lift only flies CPT/JNB/DUR — unsupported route: ${route}`);
  }

  const returnPart = RETURN || 'NA';
  const resultsUrl = `https://www.lift.co.za/flight-results/${route}/${DATE}/${returnPart}/${ADULTS}/0/0`;

  const CHROME_PATH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  const profileDir = join(__dirname, `.lift-profile-${FROM}`);
  if (!existsSync(profileDir)) mkdirSync(profileDir, { recursive: true });

  process.stderr.write(`[lift] API fetch via page context: ${resultsUrl}\n`);

  const context = await chromium.launchPersistentContext(profileDir, {
    executablePath: CHROME_PATH,
    headless: true,
    args: ['--no-sandbox', '--disable-blink-features=AutomationControlled'],
    ignoreDefaultArgs: ['--enable-automation'],
  });

  const page = await context.newPage();
  await page.addInitScript(() => {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  });

  try {
    // Navigate to establish PHPSESSID + session route context
    await page.goto(resultsUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(2500);

    // Call their internal flight list API from within the page (session cookie auto-included)
    const raw = await page.evaluate(async () => {
      const resp = await fetch('/controllers/flightresults/flightList.php?action=flightsPull', {
        credentials: 'include',
        headers: { 'X-Requested-With': 'XMLHttpRequest' },
      });
      return resp.text();
    });

    await context.close();

    const data = JSON.parse(raw);
    const outbound = data.outbound || data.flights || [];

    if (!outbound.length) return [];

    return outbound.map((f, i) => {
      // Parse UTC times to SAST (UTC+2)
      const toSAST = (utcStr) => {
        if (!utcStr) return null;
        const d = new Date(utcStr.replace(' ', 'T').replace(/\.000$/, '') + 'Z');
        return d.toLocaleTimeString('en-ZA', { timeZone: 'Africa/Johannesburg', hour: '2-digit', minute: '2-digit', hour12: false });
      };

      const dep = toSAST(f.stdinutc);
      const arr = toSAST(f.stainutc);

      // Duration from UTC timestamps
      let duration = null;
      if (f.stdinutc && f.stainutc) {
        const depD = new Date(f.stdinutc.replace(' ', 'T').replace(/\.000$/, '') + 'Z');
        const arrD = new Date(f.stainutc.replace(' ', 'T').replace(/\.000$/, '') + 'Z');
        const mins = Math.round((arrD - depD) / 60000);
        duration = `${Math.floor(mins / 60)}:${String(mins % 60).padStart(2, '0')}`;
      }

      // Find cheapest bookable class
      const classes = (f.classes || []).filter(c => c.bookable && parseFloat(c.price) > 0);
      const cheapest = classes.sort((a, b) => parseFloat(a.price) - parseFloat(b.price))[0];
      const priceNum = cheapest ? parseFloat(cheapest.price) : null;

      return {
        index:     i + 1,
        departure: dep,
        arrival:   arr,
        duration,
        flight:    f.fltnum || null,
        price:     priceNum != null ? `R${Math.round(priceNum)}` : null,
        priceNum,
        stops:     f.flighttype || 'Direct',
        cabin:     cheapest?.classname || null,
      };
    }).filter(f => f.priceNum != null);

  } catch (err) {
    await context.close().catch(() => {});
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
