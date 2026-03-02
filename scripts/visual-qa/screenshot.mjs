#!/usr/bin/env node
/**
 * visual-qa/screenshot.mjs
 * Logs into a Vite dev server using system Chrome, then screenshots key pages.
 * Usage: node screenshot.mjs <port> <repo_key> <out_dir> [email] [password]
 */

import puppeteer from 'puppeteer-core';
import fs from 'fs';
import path from 'path';

const PORT     = process.argv[2] || '5173';
const REPO     = process.argv[3] || 'unknown';
const OUT_DIR  = process.argv[4] || '/tmp/visual-qa';
const EMAIL    = process.argv[5] || '';
const PASSWORD = process.argv[6] || '';
const BASE     = `http://localhost:${PORT}`;

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// Pages to screenshot after login — auth page always first to confirm load
const ROUTE_MAP = {
  'qms-guard':        ['/', '/nc', '/report', '/activity'],
  'chrome-auto-care': ['/', '/bookings', '/services'],
  'favorite-flow':    ['/', '/dashboard', '/orders'],
  'favorite-flow-9637aff2': ['/', '/dashboard'],
  'metal-solutions':  ['/'],
  'default':          ['/'],
};

const routes = ROUTE_MAP[REPO] || ROUTE_MAP['default'];
fs.mkdirSync(OUT_DIR, { recursive: true });

let browser;
try {
  browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--window-size=1440,900',
    ],
  });
} catch (e) {
  console.error(`FATAL: Could not launch Chrome: ${e.message}`);
  process.exit(1);
}

const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900 });

// ── Login ──────────────────────────────────────────────────────────────────────
// Helper: fill a React controlled input via native setter to trigger onChange
async function fillReactInput(page, selector, value) {
  const handle = await page.$(selector);
  if (!handle) return false;
  await handle.click({ clickCount: 3 });
  // Use native setter to bypass React's synthetic event restrictions
  await page.evaluate((el, val) => {
    const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
    setter.call(el, val);
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }, handle, value);
  return true;
}

if (EMAIL && PASSWORD) {
  try {
    console.log(`LOGIN: navigating to ${BASE}/auth`);
    await page.goto(`${BASE}/auth`, { waitUntil: 'networkidle2', timeout: 20000 });
    await new Promise(r => setTimeout(r, 1500));

    // Screenshot the login page first
    const loginFile = path.join(OUT_DIR, 'login.png');
    await page.screenshot({ path: loginFile });
    console.log(`SCREENSHOT:${loginFile}`);

    // Fill email — try multiple selectors
    const emailFilled = await fillReactInput(page,
      'input[name="email"], input[type="email"], input[placeholder*="company"]',
      EMAIL
    );
    if (!emailFilled) {
      console.error('WARN: No email input found — skipping login');
    }

    // Fill password
    const passFilled = await fillReactInput(page,
      'input[type="password"], input[name="password"]',
      PASSWORD
    );
    if (!passFilled) {
      console.error('WARN: No password input found — skipping login');
    }

    await new Promise(r => setTimeout(r, 500));

    // Submit — look for submit button or Sign In text
    const submitBtn = await page.$('button[type="submit"]');
    if (submitBtn) {
      await submitBtn.click();
    } else {
      await page.keyboard.press('Enter');
    }

    // Wait for redirect away from auth (up to 20s — Supabase auth takes time)
    await page.waitForFunction(
      () => !window.location.pathname.includes('/auth'),
      { timeout: 20000 }
    ).catch(() => console.error('WARN: Still on auth page after login attempt'));

    await new Promise(r => setTimeout(r, 2500));
    console.log(`LOGIN: now at ${await page.url()}`);
  } catch (e) {
    console.error(`LOGIN ERROR: ${e.message}`);
  }
}

// ── Screenshot each route ──────────────────────────────────────────────────────
const taken = [];

for (const route of routes) {
  const url = `${BASE}${route}`;
  try {
    await page.goto(url, { waitUntil: 'networkidle2', timeout: 20000 });
    await new Promise(r => setTimeout(r, 2500));

    const slug = route.replace(/\//g, '_').replace(/^_/, '') || 'home';
    const file = path.join(OUT_DIR, `${slug}.png`);
    await page.screenshot({ path: file, fullPage: false });
    console.log(`SCREENSHOT:${file}`);
    taken.push(file);
  } catch (e) {
    console.error(`FAILED:${route}:${e.message}`);
  }
}

await browser.close();
console.log(`TOTAL:${taken.length}`);
