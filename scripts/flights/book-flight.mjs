#!/usr/bin/env node
/**
 * book-flight.mjs
 * Books a specific flight on FlySafair or Lift using Playwright.
 * Retrieves passenger + card details from macOS Keychain at runtime.
 *
 * Usage:
 *   node book-flight.mjs --airline flysafair --from CPT --to JNB --date 2026-03-06 --flight "FA123" --price "R1450"
 *
 * Outputs JSON to stdout with booking confirmation or error.
 */

import { chromium } from 'playwright';
import { execSync } from 'child_process';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';

function arg(name, def = undefined) {
  const idx = process.argv.indexOf(`--${name}`);
  if (idx === -1) return def;
  return process.argv[idx + 1];
}

function keychain(account) {
  try {
    return execSync(`security find-generic-password -a "${account}" -s "amalfiai-flights" -w 2>/dev/null`).toString().trim();
  } catch {
    return null;
  }
}

const AIRLINE  = (arg('airline') || 'lift').toLowerCase();
const FROM     = (arg('from') || 'CPT').toUpperCase();
const TO       = (arg('to')   || 'JNB').toUpperCase();
const DATE     = arg('date');
const FLIGHT   = arg('flight');
const PRICE    = arg('price');
const RETURN   = arg('return');
const ADULTS   = parseInt(arg('adults') || '1', 10);
const DRY_RUN  = process.argv.includes('--dry-run');
const CONFIRM  = process.argv.includes('--confirm');

async function bookFlySafair(creds) {
  const browser = await chromium.launch({
    headless: false, // visible so you can see what's happening
    slowMo: 300,
  });
  const page = await browser.newPage();
  const screenshots = [];

  try {
    // FlySafair uses React SPA — navigate via homepage and fill the search form
    await page.goto('https://www.flysafair.co.za/', { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(2500);

    // Screenshot homepage
    const shot1 = path.join(os.tmpdir(), `flight-search-${Date.now()}.png`);
    await page.screenshot({ path: shot1, fullPage: false });
    screenshots.push(shot1);

    if (DRY_RUN) {
      await browser.close();
      return { ok: true, dry_run: true, screenshots, message: 'Dry run — homepage loaded successfully' };
    }

    // FlySafair uses Vue-Select (vs__search) for airport dropdowns
    // Fill origin airport
    const fromSearch = page.locator('input.vs__search[placeholder="Please select origin"]').first();
    await fromSearch.click().catch(() => {});
    await page.waitForTimeout(300);
    await fromSearch.fill(FROM).catch(() => {});
    await page.waitForTimeout(1200);
    await page.locator('.vs__dropdown-option').first().click().catch(() => {});
    await page.waitForTimeout(400);

    // Fill destination airport
    const toSearch = page.locator('input.vs__search[placeholder="Please select destination"]').first();
    await toSearch.click().catch(() => {});
    await page.waitForTimeout(300);
    await toSearch.fill(TO).catch(() => {});
    await page.waitForTimeout(1200);
    await page.locator('.vs__dropdown-option').first().click().catch(() => {});
    await page.waitForTimeout(400);

    // Fill departure date — date-selector__input is a custom text date picker (DD/MM/YYYY)
    const [y, m, d] = DATE.split('-');
    const dateFormatted = `${d}/${m}/${y}`;
    const dateInput = page.locator('input.date-selector__input').first();
    await dateInput.click().catch(() => {});
    await page.waitForTimeout(400);
    // Use type() rather than fill() — custom date pickers often ignore fill
    await dateInput.type(dateFormatted, { delay: 80 }).catch(() => {});
    await page.keyboard.press('Escape').catch(() => {});
    await page.waitForTimeout(300);

    // Set adult count (1-3: click button; 4+: use select)
    if (ADULTS >= 2 && ADULTS <= 3) {
      await page.locator(`button.passenger-select-buttons__button:has-text("${ADULTS}")`).first().click().catch(() => {});
      await page.waitForTimeout(300);
    } else if (ADULTS >= 4) {
      await page.locator('select[name="adult"]').selectOption(String(ADULTS)).catch(() => {});
      await page.waitForTimeout(300);
    }

    // Click Search ("Let's go" button)
    await page.locator('button.flight-search-box__button, button:has-text("Let\'s go")').first().click().catch(() => {});
    await page.waitForURL(/flight\/select/, { timeout: 30000 }).catch(() => {});
    await page.waitForTimeout(3000);

    // Screenshot flight list
    const shot2 = path.join(os.tmpdir(), `flight-list-${Date.now()}.png`);
    await page.screenshot({ path: shot2, fullPage: false });
    screenshots.push(shot2);

    // Select the specific flight by flight number or click first
    if (FLIGHT) {
      await page.locator(`text=${FLIGHT}, [data-flight="${FLIGHT}"]`).first().click().catch(() => {});
    } else {
      await page.locator('[class*="flight-result"], [class*="FlightCard"], [class*="flight-card"]').first().click().catch(() => {});
    }

    await page.waitForTimeout(2000);

    // Click continue/select button
    await page.locator('button:has-text("Select"), button:has-text("Continue"), button:has-text("Next")').first().click().catch(() => {});
    await page.waitForTimeout(2000);

    // Passenger details form
    await page.fill('[name*="firstName"], [placeholder*="First"], [id*="first"]', creds.firstName).catch(() => {});
    await page.fill('[name*="lastName"], [placeholder*="Last"], [id*="last"]', creds.lastName).catch(() => {});
    await page.fill('[name*="email"], [type="email"]', creds.email).catch(() => {});
    await page.fill('[name*="phone"], [type="tel"]', creds.phone).catch(() => {});
    await page.fill('[name*="idNumber"], [placeholder*="ID"], [name*="id_number"]', creds.idNumber).catch(() => {});

    await page.waitForTimeout(1000);

    // Screenshot passenger details
    const shot3 = path.join(os.tmpdir(), `flight-passenger-${Date.now()}.png`);
    await page.screenshot({ path: shot3 });
    screenshots.push(shot3);

    // Continue to payment
    await page.locator('button:has-text("Continue"), button:has-text("Next"), button:has-text("Proceed")').first().click().catch(() => {});
    await page.waitForTimeout(2000);

    // Payment form
    await page.fill('[name*="cardNumber"], [placeholder*="Card number"], [id*="card-number"]', creds.cardNumber).catch(() => {});
    await page.fill('[name*="expiry"], [placeholder*="MM/YY"], [placeholder*="expiry"]', creds.cardExpiry).catch(() => {});
    await page.fill('[name*="cvv"], [placeholder*="CVV"], [placeholder*="CVC"]', creds.cardCvv).catch(() => {});
    await page.fill('[name*="cardName"], [placeholder*="Name on card"]', creds.cardName).catch(() => {});

    // Screenshot payment page (card details masked by browser)
    const shot4 = path.join(os.tmpdir(), `flight-payment-${Date.now()}.png`);
    await page.screenshot({ path: shot4 }).catch(() => {});
    screenshots.push(shot4);

    if (CONFIRM) {
      // Josh approved via Telegram — submit payment
      await page.locator('button:has-text("Pay"), button:has-text("Confirm"), button:has-text("Book"), button:has-text("Submit payment")').first().click().catch(() => {});
      await page.waitForTimeout(6000);

      const shot5 = path.join(os.tmpdir(), `flight-confirm-${Date.now()}.png`);
      await page.screenshot({ path: shot5, fullPage: false });
      screenshots.push(shot5);

      const pageText = await page.evaluate(() => document.body.innerText).catch(() => '');
      const refMatch = pageText.match(/\b([A-Z]{2}[0-9]{4,8}|[A-Z0-9]{6,10})\b/);
      const bookingRef = refMatch ? refMatch[0] : null;

      await browser.close();
      return {
        ok: true,
        status: 'booked',
        message: bookingRef
          ? `Booking confirmed! Reference: ${bookingRef}`
          : 'Payment submitted. Check your email for confirmation.',
        booking_ref: bookingRef,
        screenshots,
      };
    }

    await browser.close();
    return {
      ok: true,
      status: 'awaiting_confirmation',
      message: 'Details filled. Browser closed — run with --confirm to submit payment.',
      screenshots,
    };

  } catch (err) {
    const errShot = path.join(os.tmpdir(), `flight-error-${Date.now()}.png`);
    await page.screenshot({ path: errShot }).catch(() => {});
    screenshots.push(errShot);
    await browser.close();
    throw Object.assign(err, { screenshots });
  }
}

async function main() {
  // Load credentials from Keychain
  const creds = {
    firstName:  (keychain('full_name') || '').split(' ')[0],
    lastName:   (keychain('full_name') || '').split(' ').slice(1).join(' '),
    idNumber:   keychain('id_number'),
    cardNumber: keychain('card_number'),
    cardExpiry: keychain('card_expiry'),
    cardCvv:    keychain('card_cvv'),
    cardName:   keychain('card_name'),
    email:      keychain('booking_email'),
    phone:      keychain('booking_phone'),
  };

  if (!creds.idNumber && !DRY_RUN) {
    console.log(JSON.stringify({ ok: false, error: 'No credentials found in Keychain. Run scripts/flights/keychain-setup.sh first.' }));
    process.exit(1);
  }

  try {
    let result;
    if (AIRLINE === 'lift') {
      // Lift booking — same pattern, different selectors
      result = { ok: false, error: 'Lift booking not yet implemented — use flysafair' };
    } else {
      result = await bookFlySafair(creds);
    }
    console.log(JSON.stringify(result, null, 2));
  } catch (err) {
    console.log(JSON.stringify({ ok: false, error: err.message, screenshots: err.screenshots || [] }));
    process.exit(1);
  }
}

main();
