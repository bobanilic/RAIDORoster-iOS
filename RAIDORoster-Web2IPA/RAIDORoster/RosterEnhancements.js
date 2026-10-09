(() => {
  const VERSION = '3.1.0';
  if (window !== window.top) return;
  const SCHEMA_VERSION = 1;
  if (window.RAIDOPlus?.version === VERSION) {
    window.RAIDOPlus.extractNow();
    return;
  }

  let observer;
  let timer;
  let lastDigest = '';
  let formatFailureSent = false;

  const MONTHS = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
  const MONTH_NAMES = ['JANUARY','FEBRUARY','MARCH','APRIL','MAY','JUNE','JULY','AUGUST','SEPTEMBER','OCTOBER','NOVEMBER','DECEMBER'];
  const WEEKDAYS = ['SUN','MON','TUE','WED','THU','FRI','SAT'];

  const compact = v => (v || '').replace(/\s+/g, ' ').trim();
  const upper = v => compact(v).toUpperCase();
  const pad2 = n => String(n).padStart(2, '0');
  const escapeRE = s => String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

  function hash(s) {
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0).toString(36);
  }

  function monthlyBLH(root = document) {
    const text = compact(root.body?.innerText || root.body?.textContent || '').slice(0, 120000);
    // N-OC renders the monthly summary as "BLH 70:48".
    const match = text.match(/\bBLH\s+(\d{1,3}:\d{2})\b/i);
    if (!match) return '';
    const parts = match[1].split(':');
    const hours = Number(parts[0]);
    const minutes = Number(parts[1]);
    if (!Number.isInteger(hours) || !Number.isInteger(minutes) || hours < 0 || hours > 300 || minutes < 0 || minutes > 59) return '';
    return `${hours}:${String(minutes).padStart(2, '0')}`;
  }

  function pageMonth(root = document) {
    const text = upper(root.body?.innerText || root.body?.textContent || '').slice(0, 120000);
    const m = text.match(/\b(JANUARY|FEBRUARY|MARCH|APRIL|MAY|JUNE|JULY|AUGUST|SEPTEMBER|OCTOBER|NOVEMBER|DECEMBER)\s+(20\d{2})\b/);
    if (!m) return null;
    const month = MONTH_NAMES.indexOf(m[1]) + 1;
    return {
      year: Number(m[2]),
      month,
      label: `${MONTH_NAMES[month - 1][0]}${MONTH_NAMES[month - 1].slice(1).toLowerCase()} ${m[2]}`
    };
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
    return {
      parts: local,
      dateISO: local.iso,
      localTime: m[4],
      utcDateISO: utc?.iso || '',
      utcTime: m[8] || ''
    };
  }

  function stamp(meta) {
    return meta ? `${meta.dateISO} ${meta.localTime}` : '';
  }

  function utcStamp(meta) {
    return meta?.utcTime ? `${meta.utcDateISO} ${meta.utcTime}` : '';
  }

  function activityTables(root = document) {
    return Array.from(root.querySelectorAll('table.activity-table'));
  }

  function markerMatches(text) {
    const re = /\bActivity\s+([A-Z0-9][A-Z0-9 ]{0,11}?)(?=,|\s+Departure\b)/gi;
    const out = [];
    let m;
    while ((m = re.exec(text)) !== null) {
      const code = compact(m[1]);
      if (!code || /^(NOTE|CIS|INFO)$/i.test(code)) continue;
      out.push({ index: m.index, code });
    }
    return out;
  }

  function splitLogicalActivities(text) {
    const markers = markerMatches(text);
    return markers.map((m, i) => ({
      code: m.code,
      segment: text.slice(m.index, markers[i + 1]?.index ?? text.length)
    }));
  }

  function airportAfter(segment, label) {
    const re = new RegExp(`\\b${label}\\s+([A-Z]{3})\\s+-`, 'i');
    return upper(segment).match(re)?.[1] || '';
  }

  function stationFrom(segment) {
    return upper(segment).match(/\bStation\s+([A-Z]{3})\s+-/i)?.[1] || '';
  }

  function hotelName(segment) {
    const m = compact(segment).match(/\bHotel\s+(.{2,100}?)(?=\s+ReservationNo\b|\s+Comment\b|\s+Station\b)/i);
    return m ? compact(m[1]) : '';
  }

  function description(segment, code) {
    const escaped = escapeRE(code);
    const re = new RegExp(`\\bActivity\\s+${escaped}\\s*,\\s*([^\\n]{1,90}?)(?=\\s+(?:Departure|Arrival|Station|CheckIn|Start|End|CheckOut|Hotel|ReservationNo|Station Category|Roster Designators|Activity Note|Day Note|Transfer Note|Crew On Board|STC|Aircraft Reg|A\\/C Phone)\\b|$)`, 'i');
    return compact(segment).match(re)?.[1] || '';
  }

  function cleanNote(value) {
    if (!value) return '';
    let text = String(value)
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/?strong>/gi, '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/gi, ' ')
      .replace(/&amp;/gi, '&');
    text = text
      .replace(/[ \t]+/g, ' ')
      .replace(/\s*\n\s*/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
    return text;
  }

  function labelledText(segment, label, stops) {
    const source = String(segment || '');
    const startRe = new RegExp(`\\b${escapeRE(label)}\\b\\s*`, 'i');
    const match = startRe.exec(source);
    if (!match) return '';
    const tail = source.slice(match.index + match[0].length);
    let end = tail.length;
    for (const stop of stops || []) {
      if (stop.toLowerCase() === label.toLowerCase()) continue;
      const re = new RegExp(`\\b${escapeRE(stop)}\\b`, 'i');
      const hit = re.exec(tail);
      if (hit && hit.index < end) end = hit.index;
    }
    return cleanNote(tail.slice(0, end));
  }

  const NOTE_STOPS = [
    'Activity Note', 'Day Note', 'Transfer Note', 'Crew On Board', 'A/C Phone',
    'Aircraft Reg', 'STC', 'Station Category', 'Roster Designators', 'Reservation number',
    'ReservationNo', 'CheckIn', 'Start', 'End', 'CheckOut'
  ];

  function pickupFrom(note) {
    if (!note) return '';
    let m = note.match(/\bPU\s+at\s+(?:(\d{1,2})([A-Z]{3})\s+)?(\d{1,2}:\d{2})\s*(?:local time|LT)?/i);
    if (m) {
      const date = m[1] && m[2] ? `${Number(m[1])} ${upper(m[2])} • ` : '';
      return `${date}${m[3]} LT`;
    }
    m = note.match(/\bPickup\s+at\s+(\d{1,2}:\d{2})\s*(?:local time|LT)?/i);
    return m ? `${m[1]} LT` : '';
  }

  function aircraftDetails(segment) {
    const text = compact(segment);
    const reg = text.match(/\bAircraft Reg\s+([A-Z0-9-]+)/i)?.[1] || '';
    const version = text.match(/\bVersion\s+([A-Z0-9-]+)/i)?.[1] || '';
    const type = text.match(/\bType\s+([A-Z0-9-]+)/i)?.[1] || '';
    const phone = text.match(/\bA\/C Phone\s+(\+?[\d][\d\s().-]{6,}\d)/i)?.[1] || '';
    return { reg: upper(reg), version: upper(version), type: upper(type), phone: compact(phone) };
  }

  function titleCaseName(value) {
    return compact(value).toLowerCase().replace(/(^|[\s'’-])([a-zà-öø-ÿ])/g, (_, a, b) => a + b.toUpperCase());
  }


  const PHONE_COUNTRIES = [
    ['971','AE'], ['420','CZ'], ['421','SK'], ['351','PT'], ['352','LU'], ['353','IE'],
    ['354','IS'], ['355','AL'], ['356','MT'], ['357','CY'], ['358','FI'], ['359','BG'],
    ['370','LT'], ['371','LV'], ['372','EE'], ['373','MD'], ['374','AM'], ['375','BY'],
    ['376','AD'], ['377','MC'], ['378','SM'], ['380','UA'], ['381','RS'], ['382','ME'],
    ['383','XK'], ['385','HR'], ['386','SI'], ['387','BA'], ['389','MK'], ['995','GE'],
    ['994','AZ'], ['972','IL'], ['996','KG'], ['998','UZ'], ['30','GR'], ['31','NL'],
    ['32','BE'], ['33','FR'], ['34','ES'], ['36','HU'], ['39','IT'], ['40','RO'],
    ['41','CH'], ['43','AT'], ['44','GB'], ['45','DK'], ['46','SE'], ['47','NO'],
    ['48','PL'], ['49','DE'], ['90','TR']
  ];

  function phoneCountry(value) {
    const digits = String(value || '').replace(/\D/g, '');
    if (!digits) return '';
    const hit = PHONE_COUNTRIES.find(([prefix]) => digits.startsWith(prefix));
    return hit?.[1] || '';
  }

  function crewMembers(segment) {
    const block = labelledText(segment, 'Crew On Board', ['Transfer Note', 'A/C Phone', 'Activity Note', 'Day Note']);
    if (!block) return [];
    const marker = /\b(CPT|FO|FA\d+|SCCM|CCM|PUR|PU)\s*-\s*([A-Z0-9]{2,6})\s+/gi;
    const matches = [];
    let m;
    while ((m = marker.exec(block)) !== null) {
      matches.push({ index: m.index, end: marker.lastIndex, role: upper(m[1]), code: upper(m[2]) });
    }
    return matches.map((item, i) => {
      let chunk = block.slice(item.end, matches[i + 1]?.index ?? block.length);
      const phone = chunk.match(/\+\d[\d\s().-]{7,}\d/)?.[0] || '';
      chunk = chunk
        .replace(/\s+[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}.*$/i, '')
        .replace(/\s+\+?\d[\d\s().-]{7,}\d.*$/i, '')
        .trim();
      const parts = chunk.split(',').map(compact);
      const name = parts.length >= 2
        ? `${titleCaseName(parts.slice(1).join(' '))} ${titleCaseName(parts[0])}`.trim()
        : titleCaseName(chunk);
      return {
        role: item.role,
        code: item.code,
        name,
        country: phoneCountry(phone),
        phone: compact(phone)
      };
    }).filter(c => c.name);
  }

  function category(code, desc, segment) {
    const c = upper(code);
    const d = upper(desc);

    if (c === 'DND' || /\bDND\b/.test(d)) return 'DND';
    if (/^(VAC|HOL)/.test(c) || /\b(VACATION|HOLIDAY)\b/.test(d)) return 'VACATION';
    if (c.includes('LEAVE') || /\bLEAVE\b/.test(d)) return 'LEAVE';
    if (c === 'REST' || /\bREST\b/.test(d)) return 'REST';
    if (/^OFF/.test(c) || /\bDAY OFF\b/.test(d)) return 'OFF';
    if (/^(SIM|TRN|TRAIN)/.test(c) || /\b(TRAINING|SIMULATOR|RECURRENT)\b/.test(d)) return 'TRAINING';
    if (/^(POS|DH)$/.test(c) || /\b(AIR POSITIONING|POSITIONING|DEADHEAD)\b/.test(d)) return 'POSITIONING';
    if (/^STB/.test(c) || /\bSTB\b|\bSTANDBY\b/.test(d)) return 'STANDBY';
    if (c === 'RES' || /\bRESERVE\b/.test(d)) return 'RESERVE';
    if (c === 'HTL' || /\bHOTEL\b/.test(d)) return 'HOTEL';
    if (c === 'AEP' || /\bADD EXPENSES\b/.test(d)) return 'EXPENSE';
    if (c === 'RLCN' || /\bHOTEL RELOCATION\b/.test(d)) return 'RELOCATION';
    if (/^[A-Z0-9]{2,3}\d{2,4}[A-Z]?$/.test(c) || /\bDeparture\s+[A-Z]{3}\s+-/.test(segment)) return 'FLIGHT';
    return 'OTHER';
  }

  function titleFor(code, cat, desc, segment) {
    if (cat === 'FLIGHT') return upper(code);
    if (cat === 'POSITIONING') return 'POSITIONING';
    if (cat === 'RESERVE') return 'RESERVE';
    if (cat === 'STANDBY') return upper(code).startsWith('STBM') ? 'STANDBY MORNING' : upper(code).startsWith('STBA') ? 'STANDBY AFTERNOON' : 'STANDBY';
    if (cat === 'OFF') return 'OFF';
    if (cat === 'DND') return 'DND';
    if (cat === 'REST') return 'REST';
    if (cat === 'VACATION') return 'VACATION';
    if (cat === 'LEAVE') return 'LEAVE';
    if (cat === 'TRAINING') return 'TRAINING';
    if (cat === 'HOTEL') return hotelName(segment) || 'HOTEL';
    if (cat === 'EXPENSE') return 'EXPENSE';
    if (cat === 'RELOCATION') return 'HOTEL RELOCATION';
    return desc || upper(code) || 'OTHER';
  }

  function parseLogicalActivity(code, segment, sourceIndex, logicalIndex) {
    const start = parseMeta(segment, 'Start');
    if (!start) return null;

    const end = parseMeta(segment, 'End');
    const checkIn = parseMeta(segment, 'CheckIn');
    const checkOut = parseMeta(segment, 'CheckOut');
    const desc = description(segment, code);
    const cat = category(code, desc, segment);
    const dep = airportAfter(segment, 'Departure');
    const arr = airportAfter(segment, 'Arrival');
    const station = stationFrom(segment);
    const route = ['FLIGHT', 'POSITIONING'].includes(cat) && dep && arr ? `${dep} → ${arr}` : '';

    const activityNote = labelledText(segment, 'Activity Note', NOTE_STOPS);
    const dayNote = labelledText(segment, 'Day Note', NOTE_STOPS);
    const transferNote = labelledText(segment, 'Transfer Note', NOTE_STOPS);
    const pickup = pickupFrom(transferNote) || pickupFrom(activityNote) || pickupFrom(dayNote);
    const aircraft = aircraftDetails(segment);
    const crew = crewMembers(segment);
    const hotel = cat === 'HOTEL' ? hotelName(segment) : '';

    let timeText = '';
    if (['FLIGHT', 'POSITIONING'].includes(cat)) {
      const ci = checkIn?.localTime || '';
      timeText = `${ci ? `CI ${ci}  •  ` : ''}${start.localTime}${end?.localTime ? `–${end.localTime}` : ''}`;
    } else if (start.localTime) {
      const sameDay = !end || start.dateISO === end.dateISO;
      timeText = sameDay
        ? `${start.localTime}${end?.localTime ? `–${end.localTime}` : ''}`
        : `${start.localTime} → ${end?.dateISO || ''} ${end?.localTime || ''}`.trim();
    }

    const cells = [
      `ACTIVITY: ${upper(code)}`,
      desc ? `TYPE: ${desc}` : '',
      dep ? `DEP: ${dep}` : '',
      arr ? `ARR: ${arr}` : '',
      station && !dep ? `STATION: ${station}` : '',
      checkIn ? `CHECK-IN LT: ${stamp(checkIn)}` : '',
      `START LT: ${stamp(start)}`,
      start.utcTime ? `START UTC: ${utcStamp(start)}` : '',
      end ? `END LT: ${stamp(end)}` : '',
      end?.utcTime ? `END UTC: ${utcStamp(end)}` : '',
      checkOut ? `CHECK-OUT LT: ${stamp(checkOut)}` : '',
      pickup ? `PICKUP: ${pickup}` : '',
      aircraft.reg ? `AIRCRAFT: ${aircraft.reg}` : ''
    ].filter(Boolean);

    const sig = [
      upper(code), start.dateISO, start.localTime,
      end?.dateISO || '', end?.localTime || '',
      dep, arr, cat
    ].join('|');

    return {
      sourceIndex,
      logicalIndex,
      sig,
      dateISO: start.dateISO,
      dateText: displayDate(start.parts),
      category: cat,
      title: titleFor(code, cat, desc, segment),
      route,
      timeText,
      cells,
      start,
      end,
      checkIn,
      checkOut,
      code: upper(code),
      description: desc,
      station,
      hotelName: hotel,
      pickup,
      transferNote,
      activityNote,
      dayNote,
      aircraftReg: aircraft.reg,
      aircraftType: aircraft.type,
      aircraftVersion: aircraft.version,
      aircraftPhone: aircraft.phone,
      crew,
      rawText: compact([
        upper(code),
        desc,
        route,
        checkIn ? `CI ${checkIn.localTime}` : '',
        `START ${stamp(start)}`,
        end ? `END ${stamp(end)}` : ''
      ].filter(Boolean).join(' • '))
    };
  }

  function richness(a) {
    return [a.transferNote, a.activityNote, a.dayNote, a.pickup, a.aircraftReg, a.aircraftPhone]
      .reduce((n, v) => n + (v ? String(v).length : 0), 0) + a.crew.length * 50;
  }

  function extractActivities(root = document) {
    const bySignature = new Map();

    activityTables(root).forEach((table, sourceIndex) => {
      const representations = Array.from(new Set([
        compact(table.innerText || ''),
        compact(table.textContent || '')
      ].filter(Boolean)));

      representations.forEach((text, representationIndex) => {
        splitLogicalActivities(text).forEach((logical, logicalIndex) => {
          const activity = parseLogicalActivity(
            logical.code,
            logical.segment,
            sourceIndex,
            logicalIndex + (representationIndex * 1000)
          );
          if (!activity) return;
          const existing = bySignature.get(activity.sig);
          if (!existing || richness(activity) > richness(existing)) {
            bySignature.set(activity.sig, activity);
          }
        });
      });
    });

    const found = Array.from(bySignature.values());
    found.sort((a, b) =>
      a.dateISO.localeCompare(b.dateISO) ||
      a.start.localTime.localeCompare(b.start.localTime) ||
      a.sourceIndex - b.sourceIndex
    );
    return found;
  }

  function priority(cat) {
    return ({
      FLIGHT: 100,
      POSITIONING: 95,
      TRAINING: 90,
      RESERVE: 80,
      STANDBY: 75,
      RELOCATION: 55,
      HOTEL: 30,
      EXPENSE: 25,
      OTHER: 20,
      DND: 15,
      REST: 10,
      VACATION: 10,
      LEAVE: 10,
      OFF: 5
    })[cat] || 0;
  }

  function combineRoute(items) {
    const routes = items.map(i => i.route).filter(Boolean);
    if (!routes.length) return '';
    const chain = [];
    for (const route of routes) {
      const [a, b] = route.split(' → ');
      if (!a || !b) continue;
      if (!chain.length) chain.push(a, b);
      else if (chain[chain.length - 1] === a) chain.push(b);
      else if (!chain.includes(a) || chain[chain.length - 1] !== b) chain.push(a, b);
    }
    return chain.length >= 2 ? chain.join(' → ') : routes[0];
  }

  function isAuxiliary(cat) {
    return ['HOTEL', 'EXPENSE', 'RELOCATION'].includes(cat);
  }

  function publicActivity(a) {
    return {
      id: a.sig,
      code: a.code,
      category: a.category,
      title: a.title,
      description: a.description || '',
      route: a.route || '',
      station: a.station || '',
      checkInLT: stamp(a.checkIn),
      checkInUTC: utcStamp(a.checkIn),
      startLT: stamp(a.start),
      startUTC: utcStamp(a.start),
      endLT: stamp(a.end),
      endUTC: utcStamp(a.end),
      checkOutLT: stamp(a.checkOut),
      checkOutUTC: utcStamp(a.checkOut),
      hotelName: a.hotelName || '',
      pickup: a.pickup || '',
      transferNote: a.transferNote || '',
      activityNote: a.activityNote || '',
      dayNote: a.dayNote || '',
      aircraftReg: a.aircraftReg || '',
      aircraftType: a.aircraftType || '',
      aircraftVersion: a.aircraftVersion || '',
      aircraftPhone: a.aircraftPhone || '',
      crew: a.crew || [],
      rawText: a.rawText || ''
    };
  }

  function activityEpoch(meta) {
    if (!meta) return NaN;
    const iso = meta.utcTime && meta.utcDateISO
      ? `${meta.utcDateISO}T${meta.utcTime}:00Z`
      : `${meta.dateISO}T${meta.localTime}:00Z`;
    const value = Date.parse(iso);
    return Number.isFinite(value) ? value : NaN;
  }

  function activityStartEpoch(a) {
    return activityEpoch(a.checkIn) || activityEpoch(a.start) || NaN;
  }

  function activityEndEpoch(a) {
    return activityEpoch(a.checkOut) || activityEpoch(a.end) || activityStartEpoch(a);
  }

  function isDutyCore(a) {
    return ['FLIGHT', 'POSITIONING', 'TRAINING', 'RESERVE', 'STANDBY'].includes(a.category);
  }

  function dutyGapStartsNew(previous, current, groupStart, groupEnd) {
    const prevEnd = activityEndEpoch(previous);
    const currentStart = activityStartEpoch(current);
    const currentCI = activityEpoch(current.checkIn);
    const previousCO = activityEpoch(previous.checkOut);

    // Explicit release followed by a later explicit check-in is authoritative.
    if (Number.isFinite(previousCO) && Number.isFinite(currentCI) && currentCI > previousCO + 30 * 60 * 1000) {
      return true;
    }

    // If RAIDO repeats duty CI/CO only on the first/last logical activity,
    // a large real gap between core activities still marks a new duty.
    if (Number.isFinite(prevEnd) && Number.isFinite(currentStart) && currentStart - prevEnd >= 4 * 60 * 60 * 1000) {
      return true;
    }

    // A new explicit CI many hours after this group's CI is also a new duty,
    // even if a non-flight administrative activity has a broad time span.
    if (Number.isFinite(currentCI) && Number.isFinite(groupStart) && currentCI - groupStart >= 4 * 60 * 60 * 1000) {
      if (!Number.isFinite(groupEnd) || currentCI > groupEnd + 30 * 60 * 1000) return true;
    }

    return false;
  }

  function dutyGroupsForDate(items) {
    const sorted = [...items].sort((a, b) => {
      const aa = activityStartEpoch(a);
      const bb = activityStartEpoch(b);
      if (Number.isFinite(aa) && Number.isFinite(bb) && aa !== bb) return aa - bb;
      return a.start.localTime.localeCompare(b.start.localTime) || a.sourceIndex - b.sourceIndex;
    });

    const core = sorted.filter(isDutyCore);
    const passive = sorted.filter(a => !isDutyCore(a) && !isAuxiliary(a.category));

    // OFF/REST/etc. dates naturally remain one day record.
    if (!core.length) return [sorted];

    const groups = [];
    let current = [];
    let groupStart = NaN;
    let groupEnd = NaN;

    for (const a of core) {
      if (current.length && dutyGapStartsNew(current[current.length - 1], a, groupStart, groupEnd)) {
        groups.push(current);
        current = [];
        groupStart = NaN;
        groupEnd = NaN;
      }
      current.push(a);
      const s = activityStartEpoch(a);
      const e = activityEndEpoch(a);
      if (Number.isFinite(s)) groupStart = Number.isFinite(groupStart) ? Math.min(groupStart, s) : s;
      if (Number.isFinite(e)) groupEnd = Number.isFinite(groupEnd) ? Math.max(groupEnd, e) : e;
    }
    if (current.length) groups.push(current);

    // Administrative entries such as delayed reporting are attached to the
    // nearest duty envelope, but never allowed to bridge two flight duties.
    for (const a of passive) {
      const t = activityStartEpoch(a);
      let bestIndex = 0;
      let bestDistance = Number.POSITIVE_INFINITY;
      groups.forEach((g, index) => {
        const starts = g.map(activityStartEpoch).filter(Number.isFinite);
        const ends = g.map(activityEndEpoch).filter(Number.isFinite);
        const lo = starts.length ? Math.min(...starts) : NaN;
        const hi = ends.length ? Math.max(...ends) : lo;
        let distance = 0;
        if (Number.isFinite(t) && Number.isFinite(lo)) {
          if (t < lo) distance = lo - t;
          else if (Number.isFinite(hi) && t > hi) distance = t - hi;
        }
        if (distance < bestDistance) {
          bestDistance = distance;
          bestIndex = index;
        }
      });
      groups[bestIndex].push(a);
    }

    return groups.map(g => g.sort((a, b) => {
      const aa = activityStartEpoch(a);
      const bb = activityStartEpoch(b);
      if (Number.isFinite(aa) && Number.isFinite(bb) && aa !== bb) return aa - bb;
      return a.start.localTime.localeCompare(b.start.localTime);
    }));
  }

  function groupDays(activities) {
    const byDate = new Map();
    for (const a of activities) {
      if (!byDate.has(a.dateISO)) byDate.set(a.dateISO, []);
      byDate.get(a.dateISO).push(a);
    }

    const rows = [];
    let rowIndex = 0;

    for (const [dateISO, dayItems] of Array.from(byDate.entries()).sort((a, b) => a[0].localeCompare(b[0]))) {
      const groups = dutyGroupsForDate(dayItems);

      groups.forEach((items, dutyIndex) => {
        const primary = [...items].sort((a, b) => priority(b.category) - priority(a.category))[0];
        const meaningful = items.filter(i => !isAuxiliary(i.category));
        const displayItems = meaningful.length ? meaningful : items;
        const names = Array.from(new Set(displayItems.map(i => i.title).filter(Boolean)));

        const first = displayItems[0] || items[0];
        const last = displayItems[displayItems.length - 1] || items[items.length - 1];
        const ci = displayItems.map(i => i.checkIn?.localTime).find(Boolean) || '';
        const span = first?.start?.localTime
          ? `${first.start.localTime}${last?.end?.localTime ? `–${last.end.localTime}` : ''}`
          : '';

        const activeHotels = activities.filter(a =>
          a.category === 'HOTEL' &&
          a.start?.dateISO <= dateISO &&
          (a.end?.dateISO || a.start.dateISO) >= dateISO
        );

        rows.push({
          id: `d-${dateISO}-${dutyIndex + 1}`,
          index: rowIndex++,
          dateISO,
          dateText: first.dateText,
          category: primary.category,
          title: names.slice(0, 5).join(' + ') || primary.title,
          route: combineRoute(displayItems),
          timeText: `${ci ? `CI ${ci}  •  ` : ''}${span}`,
          rawText: items.map(i => i.rawText).join('\n'),
          cells: items.flatMap((i, n) => [`ACTIVITY ${n + 1}: ${i.title}`, ...i.cells]),
          activities: items.map(publicActivity),
          activeHotels: activeHotels.map(publicActivity)
        });
      });
    }

    return rows.sort((a, b) => a.dateISO.localeCompare(b.dateISO) || a.index - b.index);
  }

  function build(root = document) {
    const month = pageMonth(root);
    const tables = activityTables(root);
    const activities = extractActivities(root);
    const days = groupDays(activities);
    return { month, tables, activities, days };
  }

  function validation(b, sparse = false) {
    const monthPrefix = b.month ? `${b.month.year}-${pad2(b.month.month)}` : '';
    const monthDates = new Set(b.days.filter(d => !monthPrefix || d.dateISO.startsWith(monthPrefix)).map(d => d.dateISO));
    const monthDays = monthDates.size;
    const operational = b.activities.filter(a => ['FLIGHT','POSITIONING','RESERVE','STANDBY','OFF','DND','TRAINING'].includes(a.category)).length;
    const ok = sparse ? !!b.month && b.days.length >= 1 && b.activities.length >= 1
      : b.days.length >= 5 && b.activities.length >= 5 && operational >= 3;
    const expected = b.month ? new Date(b.month.year, b.month.month, 0).getDate() : 0;
    const coverage = expected ? Math.round((monthDays / expected) * 100) : 0;

    return {
      isValid: ok,
      parser: 'raido-duty-envelope-2.17.9',
      month: monthPrefix || (b.days[0]?.dateISO.slice(0, 7) || ''),
      datedRows: b.days.length,
      message: ok
        ? `${b.activities.length} activities across ${b.days.length} dated days${coverage ? ` • ${coverage}% current-month coverage` : ''}`
        : `Parser found ${b.activities.length} activities across ${b.days.length} days`
    };
  }

  function reportFormatFailure() {
    if (!/\/HumanResourceRoster\.aspx$/i.test(location.pathname) || formatFailureSent ||
        !window.webkit?.messageHandlers?.rosterCache) return;
    formatFailureSent = true;
    window.webkit.messageHandlers.rosterCache.postMessage({ schemaVersion: SCHEMA_VERSION,
      error: 'portal-format-changed', sourceURL: location.origin + location.pathname });
  }

  function post(b) {
    if (!window.webkit?.messageHandlers?.rosterCache) return;
    const v = validation(b);
    if (!v.isValid) {
      reportFormatFailure();
      return;
    }
    formatFailureSent = false;

    const digest = hash(b.activities.map(a => `${a.sig}|${a.transferNote}|${a.activityNote}|${a.dayNote}|${a.aircraftReg}`).join('\n'));
    if (digest === lastDigest) return;
    lastDigest = digest;

    window.webkit.messageHandlers.rosterCache.postMessage({
      schemaVersion: SCHEMA_VERSION,
      version: 2.4,
      parser: v.parser,
      sourceURL: location.origin + location.pathname,
      pageTitle: document.title || 'RAIDO',
      monthLabel: b.month?.label || '',
      monthlyBLH: monthlyBLH(),
      validation: v,
      rows: b.days
    });
  }

  function redact(text) {
    return cleanNote(text)
      .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[email]')
      .replace(/\+\d[\d\s().-]{7,}\d/g, '[phone]')
      .replace(/https?:\/\/\S+/gi, '[url]')
      .replace(/(booking ref\.?\s*:?\s*)[A-Z0-9-]+/gi, '$1[redacted]')
      .replace(/(Reservation(?:No| number)?\s*:?\s*)[A-Z0-9-]{5,}/gi, '$1[redacted]');
  }


  function monthNavigationDiagnostics() {
    const controls = Array.from(document.querySelectorAll('button, a, input, select, [role="button"]'));

    function summary(el) {
      const tag = upper(el.tagName || '');
      const text = compact(el.innerText || el.textContent || '');
      const value = compact(el.value || '');
      const title = compact(el.getAttribute?.('title') || '');
      const aria = compact(el.getAttribute?.('aria-label') || '');
      const id = compact(el.id || '');
      const name = compact(el.getAttribute?.('name') || '');
      const cls = compact(typeof el.className === 'string' ? el.className : '');
      const onclick = compact(el.getAttribute?.('onclick') || '');
      const options = tag === 'SELECT'
        ? Array.from(el.options || []).slice(0, 36).map(o => ({ text: compact(o.textContent || ''), value: compact(o.value || ''), selected: !!o.selected }))
        : [];
      return {
        tag,
        text: redact(text).slice(0, 100),
        value: redact(value).slice(0, 100),
        title: redact(title).slice(0, 100),
        aria: redact(aria).slice(0, 100),
        id: redact(id).slice(0, 100),
        name: redact(name).slice(0, 100),
        className: redact(cls).slice(0, 140),
        onclick: redact(onclick).slice(0, 180),
        options
      };
    }

    const summaries = controls.map(summary);
    const monthWords = MONTH_NAMES.join('|');
    const candidateRE = new RegExp(`(?:PREV|NEXT|BACK|FORWARD|MONTH|${monthWords}|[‹›«»])`, 'i');
    const candidates = summaries.filter(item => {
      const haystack = [item.text, item.value, item.title, item.aria, item.id, item.name, item.className, item.onclick].join(' ');
      return candidateRE.test(haystack) || item.tag === 'SELECT' && item.options.some(o => candidateRE.test(o.text));
    });

    const fallbackLabels = summaries
      .filter(item => item.text || item.value || item.title || item.aria || item.onclick)
      .slice(0, 30);

    return {
      controlCount: controls.length,
      candidateControls: candidates.slice(0, 30),
      fallbackControls: candidates.length ? [] : fallbackLabels
    };
  }

  function diagnostics() {
    try {
      const b = build();
      const now = new Date();
      return JSON.stringify({
        diagnosticVersion: VERSION,
        title: document.title || '',
        path: location.pathname,
        month: b.month,
        activityTableCount: b.tables.length,
        parsedActivityCount: b.activities.length,
        parsedDayCount: b.days.length,
        validation: validation(b),
        todayISO: `${now.getFullYear()}-${pad2(now.getMonth() + 1)}-${pad2(now.getDate())}`,
        monthNavigation: monthNavigationDiagnostics(),
        parsedDays: b.days.slice(0, 40).map(d => ({
          id: d.id,
          dateISO: d.dateISO,
          category: d.category,
          title: d.title,
          route: d.route,
          timeText: d.timeText,
          activityCount: d.activities.length,
          activeHotels: d.activeHotels.map(h => h.hotelName || h.title)
        })),
        logicalActivities: b.activities.slice(0, 90).map(a => ({
          dateISO: a.dateISO,
          code: a.code,
          category: a.category,
          title: a.title,
          route: a.route,
          timeText: a.timeText,
          pickup: a.pickup,
          hasTransferNote: !!a.transferNote,
          transferNotePreview: redact(a.transferNote).slice(0, 350),
          hasActivityNote: !!a.activityNote,
          hasDayNote: !!a.dayNote,
          aircraftReg: a.aircraftReg,
          aircraftType: a.aircraftType,
          crewCount: a.crew.length,
          rawText: redact(a.rawText)
        }))
      }, null, 2);
    } catch (error) {
      return JSON.stringify({ diagnosticVersion: VERSION, error: String(error) }, null, 2);
    }
  }

  function extractNow() {
    try {
      const b = build();
      post(b);
    } catch (_) { reportFormatFailure(); }
  }

  // Parse a fetched month without navigating the live portal or executing the
  // fetched page's scripts. Use the same extractor and native validation as live.
  function extractHTML(html, sourceURL, expectedMonth) {
    const url = new URL(sourceURL, location.href);
    if (url.origin !== location.origin || !/\/HumanResourceRoster\.aspx$/i.test(url.pathname)) throw new Error('Invalid roster URL');
    if (typeof html !== 'string' || html.length > 4 * 1024 * 1024) throw new Error('Roster page too large');
    const root = new DOMParser().parseFromString(html, 'text/html');
    const b = build(root), v = validation(b, true);
    if (!v.isValid || v.month !== expectedMonth) throw new Error('Requested month unavailable');
    return {schemaVersion: SCHEMA_VERSION, sourceURL: url.href, pageTitle: root.title || 'RAIDO',
      monthlyBLH: monthlyBLH(root), validation: v, rows: b.days};
  }

  function schedule() {
    clearTimeout(timer);
    timer = setTimeout(extractNow, 650);
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
    extractHTML,
    diagnostics
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  } else {
    start();
  }
})();
