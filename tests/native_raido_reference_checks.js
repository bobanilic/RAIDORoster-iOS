const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8');
const script = source.match(/static let referenceScript = #"""\n([\s\S]*?)\n\s*"""#/)[1];
let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; };
const activity = () => ({code:'SYN101',category:'FLIGHT',route:'AAA → BBB',startLT:'2026-10-08 13:00',startUTC:'2026-10-08 10:00',endLT:'2026-10-08 14:00',endUTC:'2026-10-08 11:00',
  crew:[{name:'private person'}],notes:'private note',rawText:'private details',phone:'private phone'});
const ready = () => ({kind:'ready',payload:{validation:{month:'2026-10',isValid:true},rows:[{dateISO:'2026-10-08',activities:[activity()],rawText:'private row'}]}});
function run(options = {}) {
  let calls = 0;
  const fail = () => { throw Error('No navigation, extraction posting, or network requests allowed'); };
  const window = {RAIDOPlus:{history:{inspect:month=>{calls++;assert.equal(month,'2026-10');return options.value ?? ready();},navigate:fail},extractNow:fail},fetch:fail};
  if (options.missingAPI) window.RAIDOPlus = undefined;
  const location = {protocol:'https:',hostname:'gjt.noc.vmc.navblue.cloud',port:'',pathname:'/HumanResourceRoster.aspx',href:'https://gjt.noc.vmc.navblue.cloud/HumanResourceRoster.aspx',...options.location};
  const result = vm.runInNewContext('(function(){'+script+'})()', {window,top:options.frame?{}:window,location,month:'2026-10',TextEncoder}, {timeout:1000});
  return {result,calls};
}
let h = run(), value = JSON.parse(h.result);
check(h.calls===1,'one read-only inspection');
check(value.activities.length===1 && value.activities[0].startUTC==='2026-10-08 10:00','required live timing fields preserved on device');
check(value.activities[0].day==='2026-10-08' && value.month==='2026-10','day and month retained for validation');
for (const secret of ['private person','private note','private details','private phone','private row','crew','rawText']) check(!h.result.includes(secret),'unneeded private fields excluded from reference');
for(const options of [{frame:true},{location:{protocol:'http:'}},{location:{hostname:'example.invalid'}},{location:{port:'444'}},{location:{pathname:'/Login.aspx'}}]) {
  h=run(options);check(h.result===null && h.calls===0,'unapproved context is not inspected');
}
check(run({missingAPI:true}).result===null,'missing extractor is inconclusive');
for (const kind of ['auth','loading','mismatch','empty','format']) check(run({value:{kind}}).result===null,'unready portal cannot become a reference');
for (const mutate of [v=>v.payload.validation.month='2026-09',v=>v.payload.validation.isValid=false,v=>v.payload.rows=[],
  v=>v.payload.rows=Array(401).fill(v.payload.rows[0]),v=>v.payload.rows[0].activities=undefined,
  v=>v.payload.rows[0].activities=Array(101).fill(activity()),v=>v.payload.rows=Array(31).fill({dateISO:'2026-10-08',activities:Array(100).fill(activity())}),
  v=>v.payload.rows[0].activities[0].code='x'.repeat(1024*1024)]) {
  const input=ready();mutate(input);check(run({value:input}).result===null,'bounds and explicit validity enforced');
}
console.log(`Native RAIDO reference: ${checks} behavior checks passed`);
