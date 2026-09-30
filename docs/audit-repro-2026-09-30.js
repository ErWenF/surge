// Audit evidence only: all platform APIs are simulated and no requests are sent.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const repo = path.resolve(__dirname, '..');
const source = name => fs.readFileSync(path.join(repo, 'scripts', name), 'utf8');

let panel;
vm.runInNewContext(source('po0fw-panel.js'), {
  $argument: 'token=pgnfw_SYNTHETIC',
  $done: result => { panel = result; },
  setTimeout: () => {},
  $httpClient: {get: (_options, callback) => callback(null, {status: 200}, JSON.stringify({
    enabled: true, currentIp: '192.0.2.5', limit: 5,
    whitelist: [{ip: '192.0.2.0/24', slot: null}]
  }))}
});
const matcher = source('Po0fw.js').match(/function sameC24\([\s\S]*?^\}/m);
assert(matcher);
assert.equal(vm.runInNewContext(matcher[0] + '; sameC24("192.0.2.0/24", "192.0.2.5");'), true);
assert.equal(panel.style, 'alert');
assert(panel.content.includes('当前出口未在白名单'));
console.log('CONFIRMED panel rejects /24 match accepted by Po0fw.js');

let completed = false;
const messages = [];
vm.runInNewContext(source('wifi-module-switch.js'), {
  $argument: 'SyntheticWiFi', $network: {wifi: {ssid: 'SyntheticWiFi'}},
  console: {log: message => messages.push(String(message))},
  $done: () => { completed = true; },
  $httpAPI: (_method, _url, _body, callback) => callback({error: 'synthetic failure'})
});
assert(completed);
assert(messages.some(message => message.includes('已连接 SyntheticWiFi → 关闭模块')));
console.log('CONFIRMED WiFi switch logs completion for a simulated API error result');
