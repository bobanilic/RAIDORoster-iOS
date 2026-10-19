"""Run the production relocation classifier and duty grouping in Node."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / 'RAIDORoster-Web2IPA/RAIDORoster/RosterEnhancements.js').read_text()

def function(name):
    start = source.index('  function ' + name + '(')
    end = source.index('\n  function ', start + 1)
    return source[start:end]

functions = '\n'.join(function(name) for name in [
    'stamp', 'utcStamp', 'category', 'priority', 'combineRoute', 'publicActivity', 'groupDays',
    'isAuxiliary', 'activityEpoch', 'activityStartEpoch',
    'activityEndEpoch', 'isDutyCore', 'dutyGapStartsNew', 'dutyGroupsForDate',
])
checks = r'''
const assert = require('node:assert/strict');
const upper = value => String(value || '').trim().toUpperCase();
assert.equal(category('RLCN','Hotel relocation',''),'RELOCATION');
assert.equal(category('RLCN','HOTEL RELOCATION',''),'RELOCATION');
assert.equal(category('HTL','Hotel',''),'HOTEL');
assert.equal(category('STA32','STB Afternoon320 ADHOC',''),'STANDBY');
function activity(code, description, start, end) {
  return {code, category:category(code,description,''), sourceIndex:0, dateISO:'2026-10-23', title:description, cells:[],
    start:{dateISO:'2026-10-23',localTime:start}, end:{dateISO:'2026-10-23',localTime:end}};
}
const standby=activity('STA32','STB Afternoon320 ADHOC','11:00','21:00');
const move=activity('RLCN','Hotel relocation','12:00','13:00');
const hotel=activity('HTL','Hotel','00:00','23:59');
const groups=dutyGroupsForDate([hotel,move,standby]);
assert.equal(groups.length,1);
assert.deepEqual(groups[0].map(a=>a.code),['STA32','RLCN']);
assert.equal(groups[0][0].end.localTime,'21:00');
assert.ok(dutyGroupsForDate([move])[0].includes(move));
const later=activity('STA32','STB Afternoon320 ADHOC','23:00','23:59');
const separate=dutyGroupsForDate([standby,move,later]);
assert.equal(separate.length,1); // A two-hour gap does not invent another duty.
const rows=groupDays([standby,move]);
assert.equal(rows[0].category,'STANDBY');
assert.ok(rows[0].activities.some(a=>a.category==='RELOCATION'));
const off=activity('OFF','Day off','00:00','23:59');
const offRows=groupDays([off,move]);
assert.equal(offRows[0].category,'OFF');
assert.ok(offRows[0].activities.some(a=>a.category==='RELOCATION'));
console.log('Passed relocation classification and standby-day retention checks');
'''
subprocess.run(['node', '-e', functions + '\n' + checks], check=True)
