/* po0fw read-only Surge panel. GET only; no whitelist mutation. */
(function () {
  'use strict';
  var finished = false;
  function done(result) { if (!finished) { finished = true; $done(result); } }
  function error(message) { done({title: 'po0fw · 查询失败', content: message + '\n未展示历史数据，请稍后刷新。', style: 'error'}); }
  function args(text) {
    var result = {};
    String(text || '').split('&').forEach(function (part) {
      var at = part.indexOf('=');
      if (at >= 0) result[part.slice(0, at)] = decodeURIComponent(part.slice(at + 1));
    });
    return result;
  }
  function clean(text) { return String(text).replace(/[\r\n\t]/g, ' '); }
  function integer(value) { return typeof value === 'number' && isFinite(value) && Math.floor(value) === value; }
  function sameC24(a, b) {
    if (!a || !b) return false;
    a = String(a); b = String(b);
    function ipv4(value) {
      var parts = value.replace(/\/24$/, '').split('.');
      if (parts.length !== 4 || !parts.every(function (part) {
        return /^(0|[1-9][0-9]{0,2})$/.test(part) && Number(part) <= 255;
      })) return null;
      return parts;
    }
    var pa = ipv4(a), pb = ipv4(b);
    if (pa && pb) {
      if (a === b) return true;
      return (a.slice(-3) === '/24' || b.slice(-3) === '/24') &&
        pa[0] === pb[0] && pa[1] === pb[1] && pa[2] === pb[2];
    }
    // IPv6 exact matches remain supported; reject malformed strings/CIDRs.
    if (a !== b || !/^[0-9a-f:]+$/i.test(a) || a.indexOf(':') < 0) return false;
    var halves = a.split('::');
    if (halves.length > 2) return false;
    var groups = halves.map(function (half) { return half ? half.split(':') : []; });
    var count = groups.reduce(function (n, group) { return n + group.length; }, 0);
    return groups.every(function (group) { return group.every(function (part) {
      return /^[0-9a-f]{1,4}$/i.test(part);
    }); }) && (halves.length === 2 ? count < 8 : count === 8);
  }
  function render(data) {
    if (!data || !Array.isArray(data.whitelist)) throw new Error('schema');
    var list = data.whitelist;
    var limit = Number(data.limit);
    var knownLimit = data.limit !== null && data.limit !== undefined && integer(limit) && limit >= 0;
    var current = typeof data.currentIp === 'string' ? data.currentIp : '';
    var fixed = [], fifo = [], other = [], hit = false;
    list.forEach(function (entry) {
      if (!entry || typeof entry.ip !== 'string' || !entry.ip) throw new Error('entry');
      if (sameC24(entry.ip, current)) hit = true;
      if (entry.slot === null) fifo.push(entry);
      else if ((typeof entry.slot === 'number' || (typeof entry.slot === 'string' && /^\d+$/.test(entry.slot))) && integer(Number(entry.slot)) && Number(entry.slot) >= 0) fixed.push(entry);
      else other.push(entry);
    });
    fixed.sort(function (a, b) { return Number(a.slot) - Number(b.slot); });
    var lines = ['占用 ' + list.length + '/' + (knownLimit ? limit : '?') + ' · 剩余 ' + (knownLimit ? Math.max(0, limit-list.length) : '?')];
    lines.push('本机出口：' + (current ? clean(current) : '接口未返回'));
    lines.push(current ? (hit ? '✓ 当前出口已在白名单' : '⚠ 当前出口未在白名单') : '当前出口命中状态未知');
    function row(label, entry) { lines.push((sameC24(entry.ip, current) ? '● ' : '○ ') + label + '  ' + clean(entry.ip)); }
    fixed.forEach(function (entry) { row('固定槽 ' + entry.slot, entry); });
    fifo.forEach(function (entry, index) { row('FIFO ' + (index + 1), entry); });
    other.forEach(function (entry, index) { row('未标注槽位 ' + (index + 1), entry); });
    if (!list.length) lines.push('白名单为空');
    lines.push('更新 ' + new Date().toLocaleTimeString());
    done({title: 'po0fw · 全部槽位', content: lines.join('\n'), style: current ? (hit ? 'good' : 'alert') : 'info'});
  }
  var config;
  try { config = args(typeof $argument === 'undefined' ? '' : $argument); }
  catch (_) { error('模块参数格式错误。'); return; }
  var token = String(config.token || '').trim().replace(/@\d+$/, '');
  if (!/^pgnfw_[A-Za-z0-9_-]+$/.test(token) || token === 'pgnfw_REPLACE_ME') {
    done({title: 'po0fw · 待配置', content: '请在模块 TOKEN 参数填写一个有效 token。\n显示此 token 对应的全部白名单记录。', style: 'info'}); return;
  }
  setTimeout(function () { error('查询超时，请检查网络或 API 可用性。'); }, 13000);
  try {
    $httpClient.get({
      url: 'https://124.221.69.228/api/firewall/' + encodeURIComponent(token),
      policy: 'DIRECT', timeout: 10, 'auto-redirect': false, 'auto-cookie': false,
      headers: {Accept: 'application/json'}
    }, function (err, response, body) {
      if (finished) return;
      if (err) { error('网络或 TLS 连接失败。'); return; }
      var status = Number(response && response.status);
      if (status === 401 || status === 403) { error('认证失败，请检查 TOKEN。'); return; }
      if (status < 200 || status >= 300 || !isFinite(status)) { error('接口返回 HTTP ' + status + '。'); return; }
      try { render(JSON.parse(body)); }
      catch (_) { error('接口数据格式不符合预期，无法确认槽位状态。'); }
    });
  } catch (_) { error('无法发起查询，请检查 Surge 脚本配置。'); }
}());
