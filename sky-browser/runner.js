/**
 * Sky Browser Runner v2 — Full Agent Loop
 *
 * Persistent headless browser process controlled by Sky Swift app.
 * Implements Perceive-Reason-Act loop for autonomous web task completion.
 *
 * Commands (stdin JSON lines):
 *   {"action": "navigate", "url": "..."}
 *   {"action": "snapshot"}
 *   {"action": "click", "target": "..."}
 *   {"action": "type", "target": "...", "text": "..."}
 *   {"action": "geturl"}
 *   {"action": "scroll", "direction": "down", "amount": 300}
 *   {"action": "wait", "ms": 2000}
 *   {"action": "runflow", "goal": "...", "startUrl": "...", "skillHint": "...", "apiKey": "...", "apiProvider": "anthropic|openai", "maxSteps": 12}
 *   {"action": "close"}
 *
 * Output (stdout JSON lines):
 *   {"type": "progress", "message": "..."}
 *   {"type": "snapshot", "content": "...", "url": "...", "title": "...", "elementCount": N}
 *   {"type": "result", "success": true|false, "message": "..."}
 *   {"type": "flowcomplete", "success": true|false, "summary": "...", "steps": N}
 *   {"type": "error", "message": "..."}
 */

const { chromium } = require('playwright');
const readline = require('readline');
const https = require('https');

var browser = null;
var context = null;
var page = null;
var pendingResolve = null; // Resolves interactive waits (login done, confirm, cancel)

// ─── Output helpers ───────────────────────────────────────────────────────────

function send(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function progress(message) {
  send({ type: 'progress', message: message });
}

function result(success, message, extra) {
  send(Object.assign({ type: 'result', success: success, message: message }, extra || {}));
}

function sendError(message) {
  send({ type: 'error', message: message });
}

// ─── Browser lifecycle ────────────────────────────────────────────────────────

async function init() {
  progress('Launching headless Chromium...');

  browser = await chromium.launch({
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-gpu',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-background-networking',
      '--disable-sync',
      '--disable-translate',
      '--disable-extensions',
      '--metrics-recording-only',
      '--safebrowsing-disable-auto-update',
      '--disable-features=TranslateUI',
      '--disable-ipc-flooding-protection'
    ]
  });

  var storagePath = getStorageStatePath();
  var contextOptions = {
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    viewport: { width: 1280, height: 900 },
    locale: 'en-IN',
    timezoneId: 'Asia/Kolkata',
    acceptDownloads: false
  };
  if (storagePath) {
    contextOptions.storageState = storagePath;
  }

  context = await browser.newContext(contextOptions);
  page = await context.newPage();

  page.on('dialog', async function(dialog) {
    progress('Auto-dismissing dialog: ' + dialog.type() + ' — ' + dialog.message().substring(0, 80));
    await dialog.dismiss().catch(function() {});
  });

  page.on('pageerror', function(err) {
    process.stderr.write('[Page error] ' + err.message + '\n');
  });

  progress('Browser ready');
  result(true, 'Browser initialized');
}

// ─── Session persistence ──────────────────────────────────────────────────────

function getStorageStatePath() {
  var os = require('os');
  var path = require('path');
  var fs = require('fs');
  var dir = path.join(os.homedir(), 'Library', 'Application Support', 'Sky', 'browser-sessions');
  var file = path.join(dir, 'default.json');
  try {
    fs.mkdirSync(dir, { recursive: true });
    if (fs.existsSync(file)) return file;
  } catch (e) {}
  return null;
}

async function saveSession(sessionName) {
  try {
    var os = require('os');
    var path = require('path');
    var fs = require('fs');
    sessionName = sessionName || 'default';
    var dir = path.join(os.homedir(), 'Library', 'Application Support', 'Sky', 'browser-sessions');
    var file = path.join(dir, sessionName + '.json');
    fs.mkdirSync(dir, { recursive: true });
    await context.storageState({ path: file });
    progress('Session saved to ' + file);
  } catch (e) {
    process.stderr.write('[Session] Save failed: ' + e.message + '\n');
  }
}

// ─── Login flow (visible browser for manual auth) ─────────────────────────────

async function runLoginFlow(url, sessionName) {
  sessionName = sessionName || 'default';
  progress('Opening visible browser for manual login...');

  // Close headless browser if running
  if (browser) {
    await browser.close().catch(function() {});
    browser = null;
    page = null;
    context = null;
  }

  var visibleBrowser = await chromium.launch({
    headless: false,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  var visibleContext = await visibleBrowser.newContext({
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    viewport: { width: 1280, height: 900 },
    locale: 'en-IN',
    timezoneId: 'Asia/Kolkata'
  });

  var visiblePage = await visibleContext.newPage();
  await visiblePage.goto(url || 'https://www.amazon.in', {
    waitUntil: 'domcontentloaded',
    timeout: 30000
  });

  send({ type: 'loginsession', status: 'waiting', message: 'Browser opened. Log in manually, then say "done" in Sky.' });
  progress('Waiting for login done signal...');

  // Wait for "logindone" signal from Swift via pendingResolve
  await new Promise(function(resolve) { pendingResolve = resolve; });

  // Save session
  var os = require('os');
  var path = require('path');
  var fs = require('fs');
  var dir = path.join(os.homedir(), 'Library', 'Application Support', 'Sky', 'browser-sessions');
  fs.mkdirSync(dir, { recursive: true });
  var sessionFile = path.join(dir, sessionName + '.json');
  await visibleContext.storageState({ path: sessionFile });
  await visibleBrowser.close();

  progress('Session saved. Reinitialising headless browser...');

  // Reinitialise headless browser with saved session
  browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage', '--disable-gpu',
           '--disable-features=TranslateUI', '--disable-ipc-flooding-protection']
  });
  context = await browser.newContext({
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    viewport: { width: 1280, height: 900 },
    locale: 'en-IN',
    timezoneId: 'Asia/Kolkata',
    storageState: sessionFile
  });
  page = await context.newPage();
  page.on('dialog', async function(dialog) { await dialog.dismiss().catch(function() {}); });

  result(true, 'Login complete. Session saved.');
  send({ type: 'loginsession', status: 'complete', message: 'Logged in successfully. Sky will use this session for all future flows.' });
}

// ─── Navigation ───────────────────────────────────────────────────────────────

async function navigate(url) {
  progress('Navigating to ' + url + '...');
  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await page.waitForTimeout(2000);
    var currentUrl = page.url();
    progress('Loaded: ' + currentUrl);
    result(true, 'Navigated to ' + currentUrl, { url: currentUrl });
  } catch (err) {
    sendError('Navigation failed: ' + err.message);
  }
}

async function waitForPageSettle(maxMs) {
  maxMs = maxMs || 4000;
  try {
    await page.waitForLoadState('domcontentloaded', { timeout: maxMs });
  } catch (e) {}
  await page.waitForTimeout(1500);
}

// ─── Snapshot ─────────────────────────────────────────────────────────────────

async function takeSnapshot() {
  progress('Taking snapshot...');
  try {
    await waitForPageSettle(3000);
    var currentUrl = page.url();
    var title = await page.title().catch(function() { return ''; });

    var elements = await page.evaluate(function() {
      var seen = new Set();
      var results = [];
      var selectors = [
        { sel: 'button:not([disabled])', role: 'button' },
        { sel: 'input[type="submit"]:not([disabled])', role: 'button' },
        { sel: 'input[type="button"]:not([disabled])', role: 'button' },
        { sel: '[role="button"]:not([disabled])', role: 'button' },
        { sel: 'a[href]', role: 'link' },
        { sel: 'label', role: 'option' },
        { sel: 'input[type="checkbox"]', role: 'checkbox' },
        { sel: 'input[type="radio"]', role: 'radio' },
        { sel: 'select', role: 'select' },
        { sel: 'input[type="text"], input[type="email"], input[type="search"], input:not([type])', role: 'textbox' },
        { sel: 'textarea', role: 'textarea' }
      ];

      for (var i = 0; i < selectors.length; i++) {
        var item = selectors[i];
        var els = document.querySelectorAll(item.sel);
        for (var j = 0; j < els.length; j++) {
          var el = els[j];
          var style = window.getComputedStyle(el);
          if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') continue;
          var rect = el.getBoundingClientRect();
          if (rect.width === 0 || rect.height === 0) continue;
          var ariaLabel = el.getAttribute('aria-label') || '';
          var isInternalId = ariaLabel.includes('=') || ariaLabel.includes('%') ||
                             (ariaLabel.length > 60 && ariaLabel.indexOf(' ') === -1);
          var text = (
            (!isInternalId && ariaLabel) ||
            el.getAttribute('title') ||
            el.textContent ||
            el.value ||
            el.placeholder ||
            el.getAttribute('alt') ||
            ''
          ).trim().replace(/\s+/g, ' ').substring(0, 120);
          if (!text) continue;
          var key = item.role + ':' + text;
          if (seen.has(key)) continue;
          seen.add(key);
          results.push({ role: item.role, text: text });
          if (results.length >= 80) break;
        }
        if (results.length >= 80) break;
      }
      return results;
    });

    var elementLines = elements.map(function(el) {
      return '[' + el.role + '] "' + el.text + '"';
    }).join('\n');
    var snapshotText = 'URL: ' + currentUrl + '\nTitle: ' + title + '\n\nINTERACTIVE ELEMENTS:\n' + (elementLines || 'No interactive elements found');

    progress('Snapshot: ' + elements.length + ' elements');
    send({
      type: 'snapshot',
      content: snapshotText,
      url: currentUrl,
      title: title,
      elementCount: elements.length
    });
  } catch (err) {
    sendError('Snapshot failed: ' + err.message);
  }
}

// ─── Click ────────────────────────────────────────────────────────────────────

async function clickElement(target) {
  progress('Clicking: "' + target + '"...');
  try {
    // Checkbox shortcut
    var lowerTarget = target.toLowerCase();
    if (lowerTarget === 'checkbox' || lowerTarget.includes('checkbox')) {
      var checkbox = page.locator('input[type="checkbox"]').first();
      await checkbox.click({ timeout: 5000, force: false });
      await page.waitForTimeout(1000);
      result(true, 'Clicked checkbox');
      return;
    }

    // Select all shortcut
    if (lowerTarget === 'select all') {
      try {
        await page.click('text=Select all', { timeout: 3000 });
        await page.waitForTimeout(500);
        result(true, 'Clicked Select all');
        return;
      } catch (e) {}
    }

    // Strategy 1: getByRole button
    try {
      await page.getByRole('button', { name: target }).first().click({ timeout: 3000 });
      await waitForPageSettle();
      result(true, 'Clicked button "' + target + '"');
      return;
    } catch (e) {}

    // Strategy 2: button locator with hasText
    try {
      await page.locator('button', { hasText: target }).first().click({ timeout: 3000 });
      await waitForPageSettle();
      result(true, 'Clicked button "' + target + '"');
      return;
    } catch (e) {}

    // Strategy 3: exact text
    try {
      await page.click('text="' + target + '"', { timeout: 3000 });
      await waitForPageSettle();
      result(true, 'Clicked "' + target + '"');
      return;
    } catch (e) {}

    // Strategy 4: partial text
    try {
      await page.click('text=' + target, { timeout: 3000 });
      await waitForPageSettle();
      result(true, 'Clicked "' + target + '"');
      return;
    } catch (e) {}

    // Strategy 5: getByRole link
    try {
      await page.getByRole('link', { name: target }).first().click({ timeout: 3000 });
      await waitForPageSettle();
      result(true, 'Clicked link "' + target + '"');
      return;
    } catch (e) {}

    // Strategy 6: interactive element containing text (button/link/role=button only — not divs)
    try {
      var el = page.locator('button, a, [role="button"]').filter({ hasText: target }).first();
      await el.click({ timeout: 3000 });
      await waitForPageSettle();
      result(true, 'Clicked element containing "' + target + '"');
      return;
    } catch (e) {}

    // Strategy 7: JavaScript — find radio/checkbox by nearby label text (e.g. Amazon payment options)
    try {
      var jsClicked = await page.evaluate(function(targetText) {
        var lower = targetText.toLowerCase();

        // Find radio/checkbox whose associated label contains the text
        var inputs = Array.from(document.querySelectorAll('input[type="radio"], input[type="checkbox"]'));
        for (var i = 0; i < inputs.length; i++) {
          var input = inputs[i];
          var lbl = input.closest('label') ||
                    (input.id ? document.querySelector('label[for="' + input.id + '"]') : null) ||
                    input.closest('[class*="payment"], [class*="option"], li') ||
                    input.parentElement;
          if (lbl && lbl.textContent.toLowerCase().includes(lower)) {
            input.click();
            return true;
          }
        }

        // Find label elements containing the text
        var labels = Array.from(document.querySelectorAll('label'));
        for (var j = 0; j < labels.length; j++) {
          if (labels[j].textContent.toLowerCase().includes(lower)) {
            labels[j].click();
            return true;
          }
        }

        // Find span/div with exact text and click its clickable parent
        var allEls = Array.from(document.querySelectorAll('span, div, p'));
        for (var k = 0; k < allEls.length; k++) {
          if (allEls[k].textContent.trim().toLowerCase() === lower) {
            var clickable = allEls[k].closest('button, a, label, [role="button"]') || allEls[k].parentElement;
            if (clickable) { clickable.click(); return true; }
          }
        }

        return false;
      }, target);

      if (jsClicked) {
        await waitForPageSettle();
        result(true, 'Clicked "' + target + '" via JavaScript');
        return;
      }
    } catch (e) {}

    sendError('Could not find element to click: "' + target + '"');
  } catch (err) {
    sendError('Click failed: ' + err.message);
  }
}

// ─── Type ─────────────────────────────────────────────────────────────────────

async function typeText(target, text) {
  progress('Typing "' + text + '" into "' + target + '"...');
  try {
    try {
      await page.getByPlaceholder(target).fill(text, { timeout: 4000 });
      result(true, 'Typed into "' + target + '"');
      return;
    } catch (e) {}

    try {
      await page.getByLabel(target).fill(text, { timeout: 4000 });
      result(true, 'Typed into "' + target + '"');
      return;
    } catch (e) {}

    try {
      await page.locator('input[name*="' + target + '"]').fill(text, { timeout: 4000 });
      result(true, 'Typed into "' + target + '"');
      return;
    } catch (e) {}

    sendError('Could not find input field: "' + target + '"');
  } catch (err) {
    sendError('Type failed: ' + err.message);
  }
}

// ─── Scroll ───────────────────────────────────────────────────────────────────

async function scroll(direction, amount) {
  var y = direction === 'down' ? amount : -amount;
  await page.evaluate(function(scrollY) { window.scrollBy(0, scrollY); }, y);
  await page.waitForTimeout(800);
  result(true, 'Scrolled ' + direction + ' ' + amount + 'px');
}

// ─── API call ─────────────────────────────────────────────────────────────────

function callAPI(prompt, apiKey, apiProvider) {
  return new Promise(function(resolve, reject) {
    var isOpenAI = apiProvider === 'openai';
    var body = isOpenAI
      ? JSON.stringify({
          model: 'gpt-4o',
          max_tokens: 300,
          response_format: { type: 'json_object' },
          messages: [{ role: 'user', content: prompt }]
        })
      : JSON.stringify({
          model: 'claude-sonnet-4-6',
          max_tokens: 300,
          messages: [{ role: 'user', content: prompt }]
        });

    var options = {
      hostname: isOpenAI ? 'api.openai.com' : 'api.anthropic.com',
      path: isOpenAI ? '/v1/chat/completions' : '/v1/messages',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body)
      }
    };

    if (isOpenAI) {
      options.headers['Authorization'] = 'Bearer ' + apiKey;
    } else {
      options.headers['x-api-key'] = apiKey;
      options.headers['anthropic-version'] = '2023-06-01';
    }

    var req = https.request(options, function(res) {
      var data = '';
      res.on('data', function(chunk) { data += chunk; });
      res.on('end', function() {
        try {
          var json = JSON.parse(data);
          var text = isOpenAI
            ? (json && json.choices && json.choices[0] && json.choices[0].message && json.choices[0].message.content)
            : (json && json.content && json.content[0] && json.content[0].text);
          resolve(text || '');
        } catch (e) {
          reject(new Error('API parse error: ' + e.message));
        }
      });
    });

    req.on('error', reject);
    req.setTimeout(20000, function() {
      req.destroy();
      reject(new Error('API timeout'));
    });
    req.write(body);
    req.end();
  });
}

// ─── Decision parsing ─────────────────────────────────────────────────────────

function parseDecision(text) {
  var clean = text.replace(/```json/g, '').replace(/```/g, '').trim();
  try {
    return JSON.parse(clean);
  } catch (e) {
    var match = clean.match(/\{[\s\S]*\}/);
    if (match) {
      try { return JSON.parse(match[0]); } catch (e2) {}
    }
    return null;
  }
}

// ─── Autonomous flow loop ─────────────────────────────────────────────────────

async function runFlow(cmd) {
  // Guard: page must be initialised — can be null if login flow was interrupted
  if (!page) {
    send({ type: 'flowcomplete', success: false,
           summary: 'Browser not ready — please say "login amazon" first, or restart Sky.', steps: 0 });
    return;
  }

  var goal = cmd.goal;
  var startUrl = cmd.startUrl;
  var skillHint = cmd.skillHint;
  var apiKey = cmd.apiKey;
  var apiProvider = cmd.apiProvider || 'anthropic';
  var maxSteps = cmd.maxSteps || 12;

  progress('Starting flow: "' + goal + '"');

  if (startUrl) {
    progress('Opening ' + startUrl + '...');
    await page.goto(startUrl, { waitUntil: 'domcontentloaded', timeout: 30000 }).catch(function() {});
    await waitForPageSettle(5000);
  }

  var completedSteps = [];
  var clickHistory = {};

  for (var step = 0; step < maxSteps; step++) {
    progress('Step ' + (step + 1) + '/' + maxSteps);

    await waitForPageSettle(2000);
    var currentUrl = page.url();
    var title = await page.title().catch(function() { return ''; });

    var elements = await page.evaluate(function() {
      var seen = new Set();
      var results = [];
      var selectors = [
        { sel: 'button:not([disabled])', role: 'button' },
        { sel: 'input[type="submit"]:not([disabled])', role: 'button' },
        { sel: '[role="button"]:not([disabled])', role: 'button' },
        { sel: 'a[href]', role: 'link' },
        { sel: 'input[type="radio"]', role: 'radio' },
        { sel: 'input[type="checkbox"]', role: 'checkbox' },
        { sel: 'select', role: 'select' },
        { sel: 'input:not([type="hidden"]):not([disabled]):not([type="radio"]):not([type="checkbox"])', role: 'textbox' }
      ];
      for (var i = 0; i < selectors.length; i++) {
        var item = selectors[i];
        var els = document.querySelectorAll(item.sel);
        for (var j = 0; j < els.length; j++) {
          var el = els[j];
          var style = window.getComputedStyle(el);
          if (style.display === 'none' || style.visibility === 'hidden') continue;
          var rect = el.getBoundingClientRect();
          if (rect.width === 0 || rect.height === 0) continue;
          var ariaLabel = el.getAttribute('aria-label') || '';
          var isInternalId = ariaLabel.includes('=') || ariaLabel.includes('%') ||
                             (ariaLabel.length > 60 && ariaLabel.indexOf(' ') === -1);
          var text = (
            (!isInternalId && ariaLabel) ||
            el.getAttribute('title') ||
            el.textContent ||
            el.value ||
            el.placeholder ||
            ''
          ).trim().replace(/\s+/g, ' ').substring(0, 100);
          // For radio buttons: get associated label text instead of internal ID value
          if (el.tagName === 'INPUT' && el.type === 'radio') {
            var radioLabel = el.closest('label') ||
                             (el.id ? document.querySelector('label[for="' + el.id + '"]') : null) ||
                             el.parentElement;
            if (radioLabel) {
              var radioText = radioLabel.textContent.trim().replace(/\s+/g, ' ').substring(0, 100);
              if (radioText && !radioText.includes('=') && !radioText.includes('%')) {
                text = radioText;
              }
            }
            if (!text || text.includes('=') || text.includes('%')) continue;
          }
          if (!text) continue;
          var key = item.role + ':' + text;
          if (seen.has(key)) continue;
          seen.add(key);
          results.push({ role: item.role, text: text });
          if (results.length >= 60) break;
        }
        if (results.length >= 60) break;
      }
      return results;
    });

    var buttons = elements.filter(function(e) { return e.role === 'button'; }).map(function(e) { return '"' + e.text + '"'; }).join(', ');
    var links = elements.filter(function(e) { return e.role === 'link'; }).slice(0, 15).map(function(e) { return '"' + e.text + '"'; }).join(', ');
    var radios = elements.filter(function(e) { return e.role === 'radio'; }).map(function(e) { return '"' + e.text + '"'; }).join(', ');
    var checkboxCount = elements.filter(function(e) { return e.role === 'checkbox'; }).length;
    var selects = elements.filter(function(e) { return e.role === 'select'; }).map(function(e) { return '"' + e.text + '"'; }).join(', ');
    var textboxes = elements.filter(function(e) { return e.role === 'textbox'; }).map(function(e) { return '"' + e.text + '"'; }).join(', ');

    var screenDesc = [
      'URL: ' + currentUrl,
      'Title: ' + title,
      buttons ? 'BUTTONS: ' + buttons : '',
      links ? 'LINKS (top 15): ' + links : '',
      radios ? 'PAYMENT OPTIONS (radio buttons — click by name): ' + radios : '',
      checkboxCount > 0 ? 'CHECKBOXES: ' + checkboxCount + ' checkbox(es) on page' : '',
      selects ? 'DROPDOWNS: ' + selects : '',
      textboxes ? 'INPUT FIELDS: ' + textboxes : ''
    ].filter(Boolean).join('\n');

    var completedSummary = completedSteps.length > 0
      ? completedSteps.map(function(s) { return '- ' + s; }).join('\n')
      : 'Nothing yet';

    var skillSection = skillHint
      ? '\nSKILL INSTRUCTIONS:\n' + skillHint + '\nFollow these instructions. Skip steps already done.\n'
      : '';

    var amazonRules = currentUrl.includes('amazon.')
      ? '\nAMAZON CHECKOUT RULES:\n' +
        '- On payment page: select "Cash on Delivery/Pay on Delivery" from PAYMENT OPTIONS, then click "Use this payment method"\n' +
        '- "Choose an Option" is the Net Banking bank selector — do NOT click it\n' +
        '- Never click targets containing = or % characters\n' +
        '- After "Use this payment method": you will be on order review page — click "Place Your Order" or "Place your order"\n' +
        '- If you already selected COD and clicked "Use this payment method" in a previous step, do NOT select COD again — you are already past that step\n'
      : '';

    var prompt = 'You are an AI agent controlling a headless browser to complete a goal.\n\n' +
      'GOAL: ' + goal + '\n' +
      'STEP: ' + (step + 1) + ' of ' + maxSteps + '\n\n' +
      'COMPLETED SO FAR:\n' + completedSummary + '\n\n' +
      'CURRENT PAGE:\n' + screenDesc + '\n' +
      skillSection +
      amazonRules +
      '\nRULES:\n' +
      '1. Only click elements that exist in BUTTONS, LINKS, PAYMENT OPTIONS, CHECKBOXES, DROPDOWNS, or INPUT FIELDS above\n' +
      '2. NEVER click the same element more than twice\n' +
      '3. If you see CHECKBOXES and need to select an item — use action "click" with target "checkbox"\n' +
      '4. For payment: use the exact name from PAYMENT OPTIONS — never click IDs containing = or %\n' +
      '5. Never click nav elements like cart icons or logos during checkout\n' +
      '6. Near max steps: use "failed" with specific reason\n' +
      '7. COMPLETION — return "done" ONLY when you see confirmed success:\n' +
      '   - Order: "Order placed", "Thank you for your order", confirmation page\n' +
      '   - Cancel: "Cancellation confirmed", "Your cancellation", order shows Cancelled\n' +
      '   - Never return done just because you clicked a button — verify the result\n\n' +
      'Return ONLY raw JSON, no markdown:\n\n' +
      'Click button/link: {"action": "click", "target": "exact text from page", "reasoning": "why"}\n' +
      'Type in field: {"action": "type", "target": "field name", "text": "what to type", "reasoning": "why"}\n' +
      'Scroll down: {"action": "scroll", "direction": "down", "amount": 400, "reasoning": "why"}\n' +
      'Wait for page: {"action": "wait", "ms": 2000, "reasoning": "why"}\n' +
      'Goal achieved: {"action": "done", "summary": "what was accomplished"}\n' +
      'Cannot complete: {"action": "failed", "reason": "specific reason"}';

    var decision;
    try {
      progress('Asking AI for next action...');
      var response = await callAPI(prompt, apiKey, apiProvider);
      process.stderr.write('[AI response] ' + response + '\n');
      decision = parseDecision(response);
    } catch (err) {
      progress('API error: ' + err.message + ', retrying once...');
      await page.waitForTimeout(2000);
      try {
        var response2 = await callAPI(prompt, apiKey, apiProvider);
        decision = parseDecision(response2);
      } catch (err2) {
        send({ type: 'flowcomplete', success: false, summary: 'API error: ' + err2.message, steps: step + 1 });
        return;
      }
    }

    if (!decision) {
      send({ type: 'flowcomplete', success: false, summary: 'Could not parse AI response', steps: step + 1 });
      return;
    }

    progress('Decision: ' + decision.action + ' — ' + (decision.reasoning || decision.target || decision.summary || decision.reason || ''));

    switch (decision.action) {
      case 'click': {
        var target = decision.target || '';

        // Safety pause — confirm before any final/irreversible action
        var orderFinalizers = ['place your order', 'place order', 'confirm order',
          'request cancellation', 'confirm cancellation', 'pay now'];
        var isFinalAction = orderFinalizers.some(function(f) { return target.toLowerCase().includes(f); });

        if (isFinalAction) {
          var confirmUrl = page.url();
          var confirmTitle = await page.title().catch(function() { return ''; });
          send({
            type: 'confirmationneeded',
            target: target,
            url: confirmUrl,
            title: confirmTitle,
            message: 'About to click "' + target + '" — confirm?'
          });
          progress('Waiting for user confirmation...');

          var confirmed = await new Promise(function(resolve) { pendingResolve = resolve; });
          if (!confirmed) {
            send({ type: 'flowcomplete', success: false, summary: 'Cancelled by user', steps: step + 1 });
            return;
          }
          progress('Confirmed — proceeding...');
        }

        clickHistory[target] = (clickHistory[target] || 0) + 1;
        if (clickHistory[target] > 3) {
          send({ type: 'flowcomplete', success: false, summary: 'Stuck — clicked "' + target + '" ' + clickHistory[target] + ' times with no progress', steps: step + 1 });
          return;
        }
        await clickElement(target);
        completedSteps.push('Clicked "' + target + '"');
        await waitForPageSettle(2500);
        break;
      }
      case 'type': {
        await typeText(decision.target || '', decision.text || '');
        completedSteps.push('Typed "' + decision.text + '" into "' + decision.target + '"');
        await page.waitForTimeout(500);
        break;
      }
      case 'scroll': {
        await scroll(decision.direction || 'down', decision.amount || 400);
        completedSteps.push('Scrolled ' + decision.direction);
        break;
      }
      case 'wait': {
        var ms = Math.min(decision.ms || 2000, 8000);
        progress('Waiting ' + ms + 'ms...');
        await page.waitForTimeout(ms);
        completedSteps.push('Waited ' + ms + 'ms');
        break;
      }
      case 'done': {
        await saveSession();
        var doneSummary = decision.summary || 'Task completed';
        progress('Flow complete: ' + doneSummary);
        send({ type: 'flowcomplete', success: true, summary: doneSummary, steps: step + 1 });
        return;
      }
      case 'failed': {
        var failReason = decision.reason || 'Unknown failure';
        progress('Flow failed: ' + failReason);
        send({ type: 'flowcomplete', success: false, summary: failReason, steps: step + 1 });
        return;
      }
      default:
        progress('Unknown action: ' + decision.action);
        break;
    }
  }

  send({ type: 'flowcomplete', success: false, summary: 'Reached maximum ' + maxSteps + ' steps — flow may be incomplete', steps: maxSteps });
}

// ─── Command loop ─────────────────────────────────────────────────────────────

async function main() {
  await init();

  var rl = readline.createInterface({
    input: process.stdin,
    terminal: false
  });

  rl.on('line', async function(line) {
    var trimmed = line.trim();
    if (!trimmed) return;

    var cmd;
    try {
      cmd = JSON.parse(trimmed);
    } catch (e) {
      sendError('Invalid JSON: ' + trimmed);
      return;
    }

    switch (cmd.action) {
      case 'navigate': await navigate(cmd.url); break;
      case 'snapshot': await takeSnapshot(); break;
      case 'click': await clickElement(cmd.target); break;
      case 'type': await typeText(cmd.target, cmd.text); break;
      case 'scroll': await scroll(cmd.direction || 'down', cmd.amount || 300); break;
      case 'wait':
        await page.waitForTimeout(Math.min(cmd.ms || 2000, 8000));
        result(true, 'Waited ' + cmd.ms + 'ms');
        break;
      case 'geturl':
        result(true, page.url(), { url: page.url() });
        break;
      case 'runflow': await runFlow(cmd); break;
      case 'loginflow': await runLoginFlow(cmd.url, cmd.sessionName); break;
      case 'logindone':
        if (pendingResolve) { pendingResolve(); pendingResolve = null; }
        break;
      case 'confirmed':
        if (pendingResolve) { pendingResolve(true); pendingResolve = null; }
        break;
      case 'cancelled':
        if (pendingResolve) { pendingResolve(false); pendingResolve = null; }
        break;
      case 'close':
        if (browser) await browser.close();
        result(true, 'Browser closed');
        process.exit(0);
        break;
      default:
        sendError('Unknown action: ' + cmd.action);
    }
  });

  rl.on('close', async function() {
    if (browser) await browser.close();
    process.exit(0);
  });

  process.on('SIGTERM', async function() {
    if (browser) await browser.close();
    process.exit(0);
  });
}

main().catch(function(err) {
  sendError('Fatal: ' + err.message);
  process.exit(1);
});
