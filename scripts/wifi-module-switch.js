/** Surge WiFi module switch. Legacy SSID1|SSID2 arguments remain supported. */
(function () {
  'use strict';
  var finished = false, timer;
  function finish(message) {
    if (finished) return;
    finished = true;
    if (timer && typeof clearTimeout === 'function') clearTimeout(timer);
    console.log(message);
    $done();
  }
  var argument = typeof $argument === 'string' ? $argument : '';
  var moduleName = 'po0 防火墙自动加白', wifiList = argument;
  try {
    if (/^(wifi_list|module_name)=/.test(argument)) {
      // Module placeholders are substituted literally, not URL encoded.
      var split = argument.lastIndexOf('&module_name=');
      if (argument.indexOf('wifi_list=') === 0) {
        wifiList = argument.slice(10, split >= 0 ? split : argument.length);
        if (split >= 0) moduleName = argument.slice(split + 13) || moduleName;
      } else {
        wifiList = '';
        moduleName = argument.slice(12) || moduleName;
      }
    }
  } catch (_) { finish('WiFi 模块参数格式错误'); return; }
  var targetWiFis = wifiList.split('|').filter(function (item) { return item.length > 0; });
  var wifi = typeof $network === 'object' && $network && $network.wifi;
  var ssid = wifi && wifi.ssid ? wifi.ssid : null;
  var shouldEnable = !(ssid !== null && targetWiFis.indexOf(ssid) !== -1);
  console.log('当前网络：' + (ssid || '蜂窝网络 / 无 WiFi') + '；目标模块：' + moduleName);
  timer = setTimeout(function () { finish('模块切换超时，无法确认实际状态'); }, 12000);
  function readState(callback) {
    $httpAPI('GET', '/v1/modules', {}, function (result) {
      if (finished) return;
      if (!result || result.error || !Array.isArray(result.available) || !Array.isArray(result.enabled)) {
        finish('模块状态查询失败，无法确认实际状态'); return;
      }
      if (result.available.indexOf(moduleName) === -1) {
        finish('找不到模块：' + moduleName + '，请检查模块名称参数'); return;
      }
      callback(result.enabled.indexOf(moduleName) !== -1);
    });
  }
  try {
    readState(function (enabled) {
      if (enabled === shouldEnable) { finish('模块已处于目标状态：' + moduleName + ' → ' + (enabled ? '开启' : '关闭')); return; }
      var body = {};
      body[moduleName] = shouldEnable;
      try { $httpAPI('POST', '/v1/modules', body, function (result) {
        if (finished) return;
        if (result && result.error) { finish('模块切换失败，实际状态未确认'); return; }
        try {
          readState(function (actual) {
            finish(actual === shouldEnable
              ? '已确认模块状态：' + moduleName + ' → ' + (actual ? '开启' : '关闭')
              : '模块切换未生效：' + moduleName);
          });
        } catch (_) { finish('模块状态复查失败'); }
      }); } catch (_) { finish('无法提交 Surge 模块切换'); }
    });
  } catch (_) { finish('无法调用 Surge 模块 API'); }
}());
