'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, 'scripts', name), 'utf8');
const match = read('Po0fw.js').match(/function sameC24\(a, b\) \{[\s\S]*?\n  \}/)[0];
const context = vm.createContext({});
vm.runInContext(match, context);
for (const [a,b,expected] of [
  ['192.0.2.0/24','192.0.2.5',true], ['192.0.2.5','192.0.2.0/24',true],
  ['192.0.2.5','192.0.2.6',false], ['192.0.2.0/24','192.0.3.5',false],
  ['192.0.2.999/24','192.0.2.5',false], ['bad','bad',false],
  ['192.0.2.0/16','192.0.2.5',false], ['::1','::1',true],
  [':::1',':::1',false], ['2001:db8::1','2001:db8::2',false]
]) assert.equal(context.sameC24(a,b), expected, `${a} / ${b}`);
assert.equal(read('po0fw-panel.js').match(/function sameC24\(a, b\) \{[\s\S]*?\n  \}/)[0], match);

function panel(body, status=200, error=null) {
  let result, calls=0, done=0, timer;
  vm.runInNewContext(read('po0fw-panel.js'), {
    $argument:'token=pgnfw_TEST',
    $httpClient:{get(options, cb) { calls++; assert.equal(options.policy,'DIRECT'); cb(error,{status},JSON.stringify(body)); }},
    setTimeout(cb) { timer=cb; return 1; },
    $done(value) { result=value; done++; }
  });
  timer();
  assert.equal(done,1);
  assert.equal(calls,1);
  return result;
}
assert.equal(panel({whitelist:[{ip:'192.0.2.0/24',slot:0}],currentIp:'192.0.2.5',limit:3}).style,'good');
assert.equal(panel({whitelist:[{ip:'192.0.2.0/24',slot:null}],currentIp:'192.0.3.5',limit:3}).style,'alert');
assert.equal(panel({whitelist:[]},401).style,'error');
assert.equal(panel({unexpected:true}).style,'error');
assert.equal(panel({},200,'offline').style,'error');

function wifi({ssid='home', initial=true, failure='', argument='home|office', async=false}={}) {
  let enabled=initial, calls=[], logs=[], completions=0, timer, callbacks=[];
  const moduleName='po0 防火墙自动加白';
  const env={
    $argument:argument, $network:{wifi:{ssid}},
    console:{log(message) { logs.push(message); }},
    setTimeout(cb) { timer=cb; return 1; }, clearTimeout() {},
    $done() { completions++; },
    $httpAPI(method, url, body, cb) {
      calls.push(method);
      if (method==='POST' && failure==='throw') throw Error('unavailable');
      const response=method==='GET'
        ? (failure==='query' ? {} : {available:failure==='missing'?[]:[moduleName],enabled:enabled?[moduleName]:[]})
        : (failure==='post' ? {error:'denied'} : {});
      if (method==='POST' && !failure) enabled=body[moduleName];
      if (async) callbacks.push(() => cb(response)); else cb(response);
    }
  };
  vm.runInNewContext(read('wifi-module-switch.js'),env);
  while(callbacks.length) callbacks.shift()();
  timer();
  assert.equal(completions,1);
  return {enabled,calls,logs:logs.join('\n')};
}
assert.equal(wifi().enabled,false);
assert.equal(wifi({ssid:null,initial:false}).enabled,true);
assert.deepEqual(wifi({initial:false}).calls,['GET']);
for (const failure of ['post','query','missing','throw','no-effect']) {
  const result=wifi({failure,async:true});
  assert.equal(result.enabled,true);
  assert(!result.logs.includes('已确认模块状态'));
}
assert.equal(wifi({ssid:'home&100%',argument:'wifi_list=home&100%|office&module_name=po0 防火墙自动加白'}).enabled,false);
for (const filename of ['po0fw.sgmodule','Wifi-po0fw.sgmodule']) {
  assert(!read(filename).includes('raw.githubusercontent.com/mozisen/'));
  assert(read(filename).includes('raw.githubusercontent.com/ErWenF/surge/'));
}
console.log('PASS Po0 /24 matching, panel errors, WiFi verified state/no-op/errors/async exceptions and module source');
