(() => {
  const VERSION = '2.2.0';
  if (window.RAIDOPlus?.version === VERSION) {
    window.RAIDOPlus.extractNow();
    window.RAIDOPlus.goToday();
    return;
  }

  let observer;
  let timer;
  let lastDigest = '';

  const MONTHS = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
  const MONTH_NAMES = ['JANUARY','FEBRUARY','MARCH','APRIL','MAY','JUNE','JULY','AUGUST','SEPTEMBER','OCTOBER','NOVEMBER','DECEMBER'];
  const WEEKDAYS = ['SUN','MON','TUE','WED','THU','FRI','SAT'];
  const compact = v => (v || '').replace(/\s+/g, ' ').trim();
  const upper = v => compact(v).toUpperCase();
  const pad2 = n => String(n).padStart(2, '0');

  function hash(s) {
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(36);
  }

  function pageMonth() {
    const text = upper(document.body?.innerText || '').slice(0, 70000);
    const m = text.match(/\b(JANUARY|FEBRUARY|MARCH|APRIL|MAY|JUNE|JULY|AUGUST|SEPTEMBER|OCTOBER|NOVEMBER|DECEMBER)\s+(20\d{2})\b/);
    if (!m) return null;
    const month = MONTH_NAMES.indexOf(m[1]) + 1;
    return { year: Number(m[2]), month, label: `${MONTH_NAMES[month - 1][0]}${MONTH_NAMES[month - 1].slice(1).toLowerCase()} ${m[2]}` };
  }

  function parseDateToken(day, mon, yy) {
    const month = MONTHS.indexOf(upper(mon)) + 1;
    const year = Number(yy) < 70 ? 2000 + Number(yy) : 1900 + Number(yy);
    const d = Number(day);
    const test = new Date(Date.UTC(year, month - 1, d));
    if (!month || test.getUTCMonth() !== month - 1 || test.getUTCDate() !== d) return null;
    return { year, month, day: d, iso: `${year}-${pad2(month)}-${pad2(d)}` };
  }

  function displayDate(p) {
    const dt = new Date(Date.UTC(p.year, p.month - 1, p.day));
    return `${WEEKDAYS[dt.getUTCDay()]} ${p.day} ${MONTHS[p.month - 1]} ${p.year}`;
  }

  function parseMeta(text, label) {
    const mon = '(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)';
    const re = new RegExp(`\\b${label}\\s+(\\d{2})${mon}(\\d{2})\\s+(\\d{2}:\\d{2})\\s*\\(LT\\)(?:\\s*\\/\\s*(\\d{2})${mon}(\\d{2})\\s+(\\d{2}:\\d{2})\\s*\\(UTC\\))?`, 'i');
    const m = compact(text).match(re);
    if (!m) return null;
    const local = parseDateToken(m[1], m[2], m[3]);
    if (!local) return null;
    const utc = m[5] ? parseDateToken(m[5], m[6], m[7]) : null;
    return { parts: local, dateISO: local.iso, localTime: m[4], utcDateISO: utc?.iso || '', utcTime: m[8] || '' };
  }

  function activityTables() {
    return Array.from(document.querySelectorAll('table.activity-table'));
  }

  function cells(row) {
    return Array.from(row.children || [])
      .filter(el => el.tagName === 'TD' || el.tagName === 'TH')
      .map(el => compact(el.innerText || el.textContent));
  }

  function key(text) {
    const k = upper(text).replace(/[^A-Z]/g, '');
    if (k === 'ACTIVITY' || k === 'ACT') return 'ACTIVITY';
    if (k === 'CHECKIN') return 'CI';
    if (k === 'DEPARTURE') return 'DEP';
    if (k === 'ARRIVAL') return 'ARR';
    return k;
  }

  function fieldsFor(table) {
    const rows = Array.from(table.querySelectorAll(':scope > tbody > tr, :scope > thead > tr, :scope > tr'));
    const parsed = rows.map(r => cells(r)).filter(r => r.length);
    if (parsed.length < 2) return { fields: {}, headers: [], values: [] };
    let headerIndex = parsed.findIndex(r => r.map(key).includes('ACTIVITY'));
    if (headerIndex < 0) headerIndex = 0;
    const headers = parsed[headerIndex].map(key);
    const values = parsed.slice(headerIndex + 1).find(r => r.length >= 2) || [];
    const fields = {};
    headers.forEach((h, i) => { if (h) fields[h] = compact(values[i] || ''); });
    return { fields, headers, values };
  }

  function clock(v) {
    let m = compact(v).match(/\b([01]\d|2[0-3])([0-5]\d)\b/);
    if (m) return `${m[1]}:${m[2]}`;
    m = compact(v).match(/\b([01]?\d|2[0-3]):([0-5]\d)\b/);
    return m ? `${pad2(Number(m[1]))}:${m[2]}` : '';
  }

  function airport(v) {
    return upper(v).match(/\b([A-Z]{3})\b/)?.[1] || '';
  }

  function activityName(fields, text) {
    let name = compact(fields.ACTIVITY || '');
    if (name) name = name.split(/\s+Activity\s+/i)[0].trim();
    if (!name) name = compact(text).match(/\bActivity\s+([^,]{1,50}),/i)?.[1] || '';
    return compact(name);
  }

  function category(activity, fields, text) {
    const a = upper(activity);
    const t = upper(`${activity} ${text}`);
    if (/\bDND\b/.test(t)) return 'DND';
    if (/\b(VAC|VACATION|HOLIDAY|HOL)\b/.test(t)) return 'VACATION';
    if (/\bLEAVE\b/.test(t)) return 'LEAVE';
    if (/\bREST\b/.test(t)) return 'REST';
    if (/\bOFF(?:\s*D)?\b/.test(a) || /\bDAY OFF\b/.test(t)) return 'OFF';
    if (/\b(TRAINING|TRAIN|SIM|SIMULATOR|RECURRENT)\b/.test(t)) return 'TRAINING';
    if (/\b(POSITIONING|POSITION|POS|DEADHEAD|DEAD[- ]?HEAD|DH)\b/.test(t)) return 'POSITIONING';
    if (/\b(STANDBY|STBY|SBY|STB)\b/.test(t)) return 'STANDBY';
    if (/\b(RESERVE|RES)\b/.test(t)) return 'RESERVE';
    const dep = airport(fields.DEP), arr = airport(fields.ARR);
    if (dep && arr && dep !== arr) return 'FLIGHT';
    if (/\b(FLT|FLIGHT|DUTY|FDP|SECTOR)\b/.test(t)) return 'FLIGHT';
    if (/^[A-Z0-9]{2,3}\s?\d{2,4}[A-Z]?$/i.test(a)) return 'FLIGHT';
    return 'OTHER';
  }

  function title(activity, cat) {
    if (cat === 'FLIGHT') return activity && !/^(FLT|FLIGHT|DUTY|FDP)$/i.test(activity) ? activity : 'FLIGHT';
    if (cat === 'POSITIONING') return 'POSITIONING';
    if (cat === 'RESERVE') return 'RESERVE';
    if (cat === 'STANDBY') return 'STANDBY';
    if (cat === 'OFF') return 'OFF';
    if (cat === 'DND') return 'DND';
    if (cat === 'REST') return 'REST';
    if (cat === 'VACATION') return 'VACATION';
    if (cat === 'LEAVE') return 'LEAVE';
    return activity || cat;
  }

  function parseActivity(table, index) {
    const text = compact(table.innerText || table.textContent);
    const start = parseMeta(text, 'Start');
    if (!start) return null;
    const end = parseMeta(text, 'End');
    const mapped = fieldsFor(table);
    const f = mapped.fields;
    const act = activityName(f, text);
    const cat = category(act, f, text);
    const dep = airport(f.DEP), arr = airport(f.ARR);
    const route = ['FLIGHT','POSITIONING'].includes(cat) && dep && arr ? `${dep} → ${arr}` : '';
    const ci = clock(f.CI), std = clock(f.STD), sta = clock(f.STA);
    const timeText = [ci && ['FLIGHT','POSITIONING'].includes(cat) ? `CI ${ci}` : '', std && sta ? `${std}–${sta}` : `${start.localTime}–${end?.localTime || ''}`]
      .filter(Boolean).join('  •  ');
    const labelled = [];
    mapped.headers.forEach((h, i) => { if (h && mapped.values[i]) labelled.push(`${h}: ${mapped.values[i]}`); });
    labelled.push(`START LT: ${start.dateISO} ${start.localTime}`);
    if (start.utcTime) labelled.push(`START UTC: ${start.utcDateISO} ${start.utcTime}`);
    if (end?.localTime) labelled.push(`END LT: ${end.dateISO} ${end.localTime}`);
    if (end?.utcTime) labelled.push(`END UTC: ${end.utcDateISO} ${end.utcTime}`);
    const sig = `${start.dateISO}|${act}|${f.CI || ''}|${f.STD || ''}|${dep}|${arr}|${f.STA || ''}|${start.localTime}|${end?.localTime || ''}`;
    return { index, dateISO: start.dateISO, dateText: displayDate(start.parts), category: cat, title: title(act, cat), route, timeText, rawText: text, cells: labelled, sig, start, end };
  }

  function priority(cat) {
    return ({ FLIGHT:100, POSITIONING:90, TRAINING:80, RESERVE:70, STANDBY:60, OTHER:50, DND:30, REST:20, VACATION:20, LEAVE:20, OFF:10 })[cat] || 0;
  }

  function combineRoute(items) {
    const routes = items.map(i => i.route).filter(Boolean);
    if (!routes.length) return '';
    const chain = [];
    for (const route of routes) {
      const p = route.split(' → ');
      if (p.length !== 2) continue;
      if (!chain.length) chain.push(p[0], p[1]);
      else if (chain[chain.length - 1] === p[0]) chain.push(p[1]);
      else chain.push(p[0], p[1]);
    }
    return chain.length >= 2 ? chain.join(' → ') : routes[0];
  }

  function groupDays(activities) {
    const map = new Map();
    for (const a of activities) {
      if (!map.has(a.dateISO)) map.set(a.dateISO, []);
      map.get(a.dateISO).push(a);
    }
    return Array.from(map.entries()).map(([dateISO, items]) => {
      items.sort((a,b) => a.index - b.index);
      const primary = [...items].sort((a,b) => priority(b.category) - priority(a.category))[0].category;
      const names = Array.from(new Set(items.map(i => i.title).filter(Boolean)));
      const first = items[0], last = items[items.length - 1];
      const ci = items.map(i => i.timeText.match(/\bCI\s+(\d{2}:\d{2})/)?.[1]).find(Boolean) || '';
      const span = first.start?.localTime && last.end?.localTime ? `${first.start.localTime}–${last.end.localTime}` : first.timeText;
      return {
        id: `d-${dateISO}`,
        index: first.index,
        dateISO,
        dateText: first.dateText,
        category: primary,
        title: names.slice(0, 4).join(' + ') || primary,
        route: combineRoute(items),
        timeText: `${ci ? `CI ${ci}  •  ` : ''}${span}`,
        rawText: items.map((i,n) => `ACTIVITY ${n + 1}: ${i.rawText}`).join('\n\n'),
        cells: items.flatMap((i,n) => [`ACTIVITY ${n + 1}: ${i.title}`, ...i.cells])
      };
    }).sort((a,b) => a.dateISO.localeCompare(b.dateISO));
  }

  function build() {
    const tables = activityTables();
    const activities = [];
    const seen = new Set();
    tables.forEach((table, index) => {
      const a = parseActivity(table, index);
      if (!a || seen.has(a.sig)) return;
      seen.add(a.sig);
      activities.push(a);
    });
    activities.sort((a,b) => a.dateISO === b.dateISO ? a.index - b.index : a.dateISO.localeCompare(b.dateISO));
    return { month: pageMonth(), tables, activities, days: groupDays(activities) };
  }

  function validation(b) {
    const other = b.activities.filter(a => a.category === 'OTHER').length;
    const ratio = b.tables.length ? b.activities.length / b.tables.length : 0;
    const ok = b.days.length >= 5 && b.activities.length >= 5 && ratio >= 0.65 && other <= Math.max(4, Math.floor(b.activities.length * 0.35));
    return {
      isValid: ok,
      parser: 'raido-activity-table-2.2',
      month: b.month ? `${b.month.year}-${pad2(b.month.month)}` : (b.days[0]?.dateISO.slice(0,7) || ''),
      datedRows: b.days.length,
      message: ok ? `${b.activities.length} RAIDO activities recognized across ${b.days.length} roster days` : `Parsed ${b.activities.length}/${b.tables.length} activity tables`
    };
  }

  function post(b) {
    if (!window.webkit?.messageHandlers?.rosterCache) return;
    const v = validation(b);
    if (!v.isValid) return;
    const digest = hash(b.activities.map(a => `${a.sig}|${a.rawText}`).join('\n'));
    if (digest === lastDigest) return;
    lastDigest = digest;
    window.webkit.messageHandlers.rosterCache.postMessage({
      version: 2.2,
      parser: v.parser,
      sourceURL: location.origin + location.pathname,
      pageTitle: document.title || 'RAIDO',
      monthLabel: b.month?.label || '',
      validation: v,
      rows: b.days
    });
  }

  function todayToken() {
    const n = new Date();
    return `${pad2(n.getDate())}${MONTHS[n.getMonth()]}${String(n.getFullYear()).slice(-2)}`;
  }

  function goToday() {
    try {
      const token = todayToken();
      const target = activityTables().find(t => upper(t.innerText || t.textContent).includes(`START ${token}`));
      if (!target) return false;
      target.scrollIntoView({ behavior: 'smooth', block: 'center' });
      const old = target.style.outline;
      target.style.outline = '3px solid #0A84FF';
      setTimeout(() => { target.style.outline = old; }, 1200);
      return true;
    } catch (_) { return false; }
  }

  function diagnostics() {
    try {
      const b = build();
      return JSON.stringify({
        diagnosticVersion: VERSION,
        title: document.title || '',
        path: location.pathname,
        month: b.month,
        activityTableCount: b.tables.length,
        parsedActivityCount: b.activities.length,
        parsedDayCount: b.days.length,
        parsedDays: b.days.slice(0, 20),
        tables: b.tables.slice(0, 40).map((table, index) => {
          const text = compact(table.innerText || table.textContent);
          const mapped = fieldsFor(table);
          return { index, className: compact(table.className || ''), headers: mapped.headers, values: mapped.values, start: parseMeta(text,'Start'), end: parseMeta(text,'End'), textSample: text.slice(0,900) };
        })
      }, null, 2);
    } catch (e) { return JSON.stringify({ diagnosticVersion: VERSION, error: String(e) }, null, 2); }
  }

  function extractNow() {
    try {
      const b = build();
      if (b.days.length >= 5) post(b);
      goToday();
    } catch (_) {}
  }

  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(extractNow, 450);
  }

  function start() {
    extractNow();
    if (!observer && document.documentElement) {
      observer = new MutationObserver(schedule);
      observer.observe(document.documentElement, { subtree:true, childList:true, characterData:true });
    }
  }

  window.RAIDOPlus = { version: VERSION, extractNow, goToday, diagnostics };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once:true });
  else start();
})();
