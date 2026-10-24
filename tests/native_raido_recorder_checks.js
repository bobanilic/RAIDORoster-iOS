const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8').replace('__CAPTURE_TOKEN__', 'synthetic-token');
const origin = 'https://gjt.noc.vmc.navblue.cloud';
const url = origin + '/synthetic/GetRoster';
const body = JSON.stringify({month:10,year:2026,hrId:42});
let assertions = 0;
const check = (value, message) => { assert.ok(value, message); assertions++; };

function harness(hostname = 'gjt.noc.vmc.navblue.cloud', frame = false) {
  const messages = [], sent = [], fetches = [];
  class XHR {
    constructor() { this.listeners = []; this.responseType = ''; }
    open(method, url) { this.opened = {method,url}; return 'open-result'; }
    send(value) { sent.push({xhr:this,value}); return 'send-result'; }
    addEventListener(name, listener) { if (name === 'load') this.listeners.push(listener); }
    finish(value, options = {}) {
      this.status = options.status || 200; this.responseURL = options.url || url;
      this.responseType = options.type || ''; this.responseText = value; this.response = value;
      for (const listener of this.listeners.splice(0)) listener();
    }
  }
  let nextFetch = () => new Response('{"days":[]}', {headers:{'content-type':'application/json'}});
  const originalFetch = (...args) => {
    fetches.push(args); const response = nextFetch();
    Object.defineProperty(response, 'url', {value: url}); return Promise.resolve(response);
  };
  const window = {fetch:originalFetch, webkit:{messageHandlers:{nativeRAIDOProbe:{postMessage:value=>messages.push(value)}}}};
  const context = vm.createContext({window,top:frame?{}:window,location:{protocol:'https:',hostname,origin:'https://'+hostname,href:'https://'+hostname+'/'},
    URL,TextEncoder,TextDecoder,Uint8Array,WeakMap,XMLHttpRequest:XHR,console});
  const originalOpen = XHR.prototype.open, originalSend = XHR.prototype.send;
  vm.runInContext(source,context);
  return {window,XHR,messages,sent,fetches,originalFetch,originalOpen,originalSend,setNextFetch:fn=>nextFetch=fn};
}

async function run() {
  let h = harness('example.invalid');
  check(h.window.fetch === h.originalFetch, 'wrong origin must not be hooked');
  h = harness('gjt.noc.vmc.navblue.cloud', true);
  check(h.window.fetch === h.originalFetch, 'subframes must not be hooked');
  h = harness();
  let xhr = new h.XHR();
  check(xhr.open('POST',url) === 'open-result', 'preserve open result');
  check(xhr.send(body) === 'send-result', 'preserve send result');
  xhr.finish('{"days":[]}');
  check(h.sent[0].value === body, 'original request body is untouched');
  check(h.messages.length === 1 && h.messages[0].token === 'synthetic-token', 'one bounded matching request captured');
  xhr = new h.XHR(); xhr.open('POST',url); xhr.send(body); xhr.finish('{"days":[]}');
  check(h.messages.length === 1, 'capture exactly one response');

  for (const [method,target,request] of [['GET',url,body],['POST',origin+'/ConfirmRevision',body],
    ['POST','https://example.invalid/GetRoster',body],['POST',url+'?x=1',body],
    ['POST',url+'#x',body],['POST',origin+'/%47etRoster',body],
    ['POST',url,'{"month":10,"year":2026,"hrId":42,"confirm":true}'],['POST',url,'not-json']]) {
    h=harness(); xhr=new h.XHR(); xhr.open(method,target); xhr.send(request); xhr.finish('{"days":[]}');
    check(h.messages.length === 0,'reject unsupported operation, origin, URL, or body');
    check(h.sent.length === 1,'unsupported requests still reach original XHR');
  }
  h=harness(); xhr=new h.XHR(); xhr.open('POST',url); xhr.send(body);
  xhr.finish('x'.repeat(4*1024*1024+1));
  check(h.messages.length===0,'oversized response not sent through bridge');
  h=harness(); xhr=new h.XHR(); xhr.open('POST',url); xhr.send(body); xhr.finish('<html>Login</html>');
  check(h.messages.length===0,'HTML not captured as JSON');
  h=harness(); xhr=new h.XHR(); xhr.open('POST',url); xhr.send(body); xhr.finish('{"days":[]}',{status:401});
  check(h.messages.length===0,'authentication failure not a successful contract');
  h=harness(); xhr=new h.XHR(); xhr.open('POST',url); xhr.send(body); xhr.finish('{"days":[]}',{url:'https://example.invalid/GetRoster'});
  check(h.messages.length===0,'redirected response not captured');
  h=harness(); xhr=new h.XHR(); xhr.open('POST',url); xhr.send(body);
  xhr.responseType='arraybuffer'; xhr.status=200; xhr.responseURL=url;
  Object.defineProperty(xhr,'responseText',{get(){throw Error('must not read binary responseText');}});
  for(const listener of xhr.listeners) listener();
  check(h.messages.length===0,'binary response does not break the page');

  h=harness(); xhr=new h.XHR(); xhr.open('POST',url); xhr.send(body); h.window.__RAIDONativeExperiment.stop(); xhr.finish('{"days":[]}');
  check(h.messages.length===0,'stop discards pending responses');
  check(h.window.fetch===h.originalFetch && h.XHR.prototype.open===h.originalOpen && h.XHR.prototype.send===h.originalSend,'stop restores owned hooks');
  h=harness(); const replacement=()=>{}; h.window.fetch=replacement; h.window.__RAIDONativeExperiment.stop();
  check(h.window.fetch===replacement,'stop preserves newer page hooks');

  h=harness(); const response=await h.window.fetch(url,{method:'POST',body});
  check(await response.text()==='{"days":[]}', 'fetch caller retains original body');
  for(let i=0;i<20 && !h.messages.length;i++) await new Promise(resolve=>setImmediate(resolve));
  check(h.messages.length===1,'fetch clone captures matching response');
  check(h.fetches.length===1,'recorder does not make extra network requests');
  console.log(`Native RAIDO recorder: ${assertions} behavior checks passed`);
}
run().catch(error=>{console.error(error);process.exitCode=1;});
