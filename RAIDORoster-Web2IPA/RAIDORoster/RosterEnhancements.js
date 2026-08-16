(() => {
  const VERSION = '2.1.0';
  if (window.RAIDOPlus && window.RAIDOPlus.version === VERSION) {
    window.RAIDOPlus.extractNow();
    window.RAIDOPlus.goToday();
    return;
  }

  let observer = null;
  let timer = null;
  let lastDigest = '';

  const compact = value => (value || '').replace(/\s+/g, ' ').trim();
  const upper = value => compact(value).toUpperCase();
  const weekdays = ['SUN','MON','TUE','WED','THU','FRI','SAT'];
  const monthNames = [
    'JANUARY','FEBRUARY','MARCH','APRIL','MAY','JUNE',
    'JULY','AUGUST','SEPTEMBER','OCTOBER','NOVEMBER','DECEMBER'
  ];
  const shortMonths = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];

  function pad2(n) { return String(n).padStart(2, '0'); }
  function validDate(y, m, d) {
    const dt = new Date(y, m - 1, d);
    return dt.getFullYear() === y && dt.getMonth() === m - 1 && dt.getDate() === d;
  }
  function iso(y, m, d) { return validDate(y, m, d) ? `${y}-${pad2(m)}-${pad2(d)}` : null; }

  function pageMonthYear() {
    const candidates = Array.from(document.querySelectorAll('h1,h2,h3,h4,strong,b,caption,div,span,td'));
    let fallback = null;
    for (const el of candidates) {
      const text = compact(el.innerText || el.textContent);
      if (!text || text.length > 60) continue;
      const m = upper(text).match(/\b(JANUARY|FEBRUARY|MARCH|APRIL|MAY|JUNE|JULY|AUGUST|SEPTEMBER|OCTOBER|NOVEMBER|DECEMBER)\s+(20\d{2})\b/);
      if (m) {
        const month = monthNames.indexOf(m[1]) + 1;
        const result = { year: Number(m[2]), month, label: `${monthNames[month - 1][0]}${monthNames[month - 1].slice(1).toLowerCase()} ${m[2]}` };
        if (/^(H1|H2|H3|H4|CAPTION|STRONG|B)$/.test(el.tagName)) return result;
        fallback = fallback || result;
      }
    }

    const body = upper(document.body?.innerText || '').slice(0, 50000);
    const m = body.match(/\b(JANUARY|FEBRUARY|MARCH|APRIL|MAY|JUNE|JULY|AUGUST|SEPTEMBER|OCTOBER|NOVEMBER|DECEMBER)\s+(20\d{2})\b/);
    if (m) {
      const month = monthNames.indexOf(m[1]) + 1;
      return { year: Number(m[2]), month, label: `${monthNames[month - 1][0]}${monthNames[month - 1].slice(1).toLowerCase()} ${m[2]}` };
    }
    return fallback;
  }

  function directCells(row) {
    let nodes = Array.from(row.querySelectorAll(':scope > th, :scope > td'));
    if (!nodes.length) nodes = Array.from(row.querySelectorAll(':scope > [role="cell"], :scope > [role="gridcell"]'));
    return nodes.map(node => compact(node.innerText || node.textContent)).filter(Boolean);
  }

  function dayFromCell(text) {
    const t = upper(text);
    let m = t.match(/^(SUN|MON|TUE|WED|THU|FRI|SAT)\s+(\d{1,2})$/);
    if (!m) m = t.match(/^(SUN|MON|TUE|WED|THU|FRI|SAT)\s*[-/]?\s*(\d{1,2})\b/);
    if (!m) return null;
    const day = Number(m[2]);
    return day >= 1 && day <= 31 ? { weekday: m[1], day } : null;
  }

  function candidateDayRows() {
    const rows = Array.from(document.querySelectorAll('tr, [role="row"]'));
    const found = [];
    const seen = new Set();
    for (const row of rows) {
      if (seen.has(row)) continue;
      seen.add(row);
      const cells = directCells(row);
      if (!cells.length) continue;
      const day = dayFromCell(cells[0]);
      if (!day) continue;
      found.push({ row, cells, day });
    }
    return found;
  }

  function unique(list) { return Array.from(new Set(list.filter(Boolean))); }

  function airportCodes(text) {
    const excluded = new Set([
      ...weekdays, ...shortMonths,
      'GJT','RAI','NOC','DUT','DUTY','FLT','FLIGHT','OFF','DND','RES','SBY','STB','STBY','POS','UTC','LOC','LOCAL',
      'REST','VAC','SIM','THE','AND','FROM','END','CAT','STD','STA','DEP','ARR','CREW','BOARD','SHOW','PRINT','PRE','NEXT'
    ]);
    return unique((upper(text).match(/\b[A-Z]{3}\b/g) || []).filter(code => !excluded.has(code)));
  }

  function activityCategory(text) {
    const t = upper(text);
    if (/\bDND\b/.test(t)) return 'DND';
    if (/\b(VAC|VACATION|HOLIDAY|HOL)\b/.test(t)) return 'VACATION';
    if (/\bLEAVE\b/.test(t)) return 'LEAVE';
    if (/\bREST\b/.test(t)) return 'REST';
    if (/\bOFF(?:\s+D)?\b/.test(t)) return 'OFF';
    if (/\b(TRAINING|TRAIN|SIM|SIMULATOR|RECURRENT)\b/.test(t)) return 'TRAINING';
    if (/\b(POSITIONING|POSITION|POS|DEADHEAD|DEAD[- ]?HEAD|DH)\b/.test(t)) return 'POSITIONING';
    if (/\b(STANDBY|STBY|SBY)\b/.test(t)) return 'STANDBY';
    if (/\b(RESERVE|RES)\b/.test(t)) return 'RESERVE';

    const codes = airportCodes(t);
    const flightNo = /\b[A-Z0-9]{2,3}\s?\d{2,4}[A-Z]?\b/.test(t);
    if (flightNo || codes.length >= 2) return 'FLIGHT';
    return 'OTHER';
  }

  function routeFor(text, category) {
    if (!['FLIGHT','POSITIONING'].includes(category)) return '';
    const codes = airportCodes(text);
    if (codes.length >= 2) return codes.slice(0, 5).join(' → ');
    return '';
  }

  function extractTimes(text) {
    const out = [];
    const push = value => { if (!out.includes(value)) out.push(value); };
    for (const m of text.matchAll(/\b(?:[01]?\d|2[0-3]):[0-5]\d\b/g)) push(m[0].padStart(5, '0'));
    for (const m of text.matchAll(/\b([01]\d|2[0-3])([0-5]\d)\b/g)) push(`${m[1]}:${m[2]}`);
    return out.slice(0, 6);
  }

  function titleFor(text, category) {
    switch (category) {
      case 'RESERVE': return 'RESERVE';
      case 'STANDBY': return 'STANDBY';
      case 'OFF': return 'OFF';
      case 'DND': return 'DND';
      case 'REST': return 'REST';
      case 'VACATION': return 'VACATION';
      case 'LEAVE': return 'LEAVE';
      case 'TRAINING': return 'TRAINING';
      case 'POSITIONING': return 'POSITIONING';
    }

    if (category === 'FLIGHT') {
      const airports = new Set(airportCodes(text));
      const candidates = unique((upper(text).match(/\b[A-Z0-9]{2,3}\s?\d{2,4}[A-Z]?\b/g) || []).filter(token => {
        const m = token.match(/^([A-Z0-9]{2,3})\s?(\d{2,4})/);
        if (!m) return false;
        if (airports.has(m[1])) return false;
        const n = Number(m[2]);
        if (m[2].length === 4 && n <= 2359 && Number(m[2].slice(2)) <= 59) return false;
        return true;
      }));
      return candidates.length ? candidates.slice(0, 3).join(' / ') : 'FLIGHT';
    }
    return 'OTHER';
  }

  function hashString(s) {
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(36);
  }

  function buildRows() {
    const month = pageMonthYear();
    if (!month) return { rows: [], month: null };

    const byDate = new Map();
    for (const entry of candidateDayRows()) {
      const dateISO = iso(month.year, month.month, entry.day.day);
      if (!dateISO) continue;
      const cells = entry.cells;
      const rawText = compact(cells.join(' | '));
      if (!rawText || rawText.length > 2500) continue;
      const activityText = compact(cells.slice(1).join(' | '));
      const category = activityCategory(activityText);
      const times = extractTimes(activityText);
      const item = {
        id: `d-${dateISO}`,
        index: entry.day.day,
        dateISO,
        dateText: `${entry.day.weekday} ${entry.day.day} ${shortMonths[month.month - 1]} ${month.year}`,
        category,
        title: titleFor(activityText, category),
        route: routeFor(activityText, category),
        timeText: times.join(' – '),
        rawText,
        cells,
        day: entry.day.day,
        weekday: entry.day.weekday
      };

      const old = byDate.get(dateISO);
      const score = cells.length * 100 + activityText.length + (category !== 'OTHER' ? 500 : 0);
      if (!old || score > old._score) byDate.set(dateISO, { ...item, _score: score, _node: entry.row });
    }

    const rows = Array.from(byDate.values())
      .sort((a, b) => a.dateISO.localeCompare(b.dateISO))
      .map(({ _score, _node, ...item }) => item);
    return { rows, month };
  }

  function validationFor(rows, month) {
    const uniqueDates = new Set(rows.map(r => r.dateISO));
    const otherCount = rows.filter(r => r.category === 'OTHER').length;
    const valid = !!month && rows.length >= 5 && uniqueDates.size === rows.length && otherCount <= Math.max(3, Math.floor(rows.length * 0.35));
    return {
      isValid: valid,
      parser: 'raido-mobile-2.1',
      month: month ? `${month.year}-${pad2(month.month)}` : '',
      datedRows: rows.length,
      message: valid ? `${rows.length} dated roster days recognized` : `Parser recognized ${rows.length} dated rows (${otherCount} unclassified)`
    };
  }

  function post(rows, month) {
    if (!window.webkit?.messageHandlers?.rosterCache) return;
    const validation = validationFor(rows, month);
    if (!validation.isValid) return;

    const digest = hashString(rows.map(r => `${r.dateISO}|${r.category}|${r.rawText}`).join('\n'));
    if (digest === lastDigest) return;
    lastDigest = digest;

    window.webkit.messageHandlers.rosterCache.postMessage({
      version: 2.1,
      parser: validation.parser,
      sourceURL: location.origin + location.pathname,
      pageTitle: document.title || 'RAIDO',
      monthLabel: month?.label || '',
      validation,
      rows
    });
  }

  function goToday() {
    try {
      const month = pageMonthYear();
      const now = new Date();
      if (!month || month.year !== now.getFullYear() || month.month !== now.getMonth() + 1) return false;
      const today = now.getDate();
      const target = candidateDayRows().find(entry => entry.day.day === today)?.row;
      if (!target) return false;
      setTimeout(() => target.scrollIntoView({ behavior: 'smooth', block: 'center' }), 120);
      return true;
    } catch (_) { return false; }
  }

  function sanitizedDiagnostics() {
    try {
      const month = pageMonthYear();
      const candidates = candidateDayRows().slice(0, 40).map((entry, index) => ({
        index,
        tag: entry.row.tagName,
        className: compact(entry.row.className || '').slice(0, 160),
        day: entry.day,
        directCells: entry.cells.map(x => x.slice(0, 350)),
        childTags: Array.from(entry.row.children).map(el => ({
          tag: el.tagName,
          className: compact(el.className || '').slice(0, 120)
        })).slice(0, 16)
      }));
      const tables = Array.from(document.querySelectorAll('table')).slice(0, 12).map((table, index) => ({
        index,
        className: compact(table.className || '').slice(0, 160),
        rowCount: table.querySelectorAll(':scope > tbody > tr, :scope > tr').length,
        textSample: compact(table.innerText || table.textContent).slice(0, 500)
      }));
      return JSON.stringify({
        diagnosticVersion: VERSION,
        title: document.title || '',
        path: location.pathname,
        month,
        candidateDayRows: candidates,
        tables
      }, null, 2);
    } catch (error) {
      return JSON.stringify({ diagnosticVersion: VERSION, error: String(error) }, null, 2);
    }
  }

  function extractNow() {
    try {
      const built = buildRows();
      if (built.rows.length >= 5) post(built.rows, built.month);
      goToday();
    } catch (_) {}
  }

  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(extractNow, 500);
  }

  function start() {
    extractNow();
    if (!observer && document.documentElement) {
      observer = new MutationObserver(schedule);
      observer.observe(document.documentElement, { subtree: true, childList: true, characterData: true });
    }
  }

  window.RAIDOPlus = {
    version: VERSION,
    extractNow,
    goToday,
    diagnostics: sanitizedDiagnostics
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
