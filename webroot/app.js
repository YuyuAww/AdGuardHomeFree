/* AdGuardHomeFree webroot/app.js (P0-T2)
 * Bridge probe: prefer fetch(127.0.0.1:3001/status) (AGHF_BRIDGE_FETCH=1),
 * fall back to the KSU webview exec channel (window.ksu.exec, ksu_exec=1),
 * else render BRIDGE_UNREACHABLE (non-blocking, read-only degrade per §9).
 * INV-03: no AGH admin credentials in this file.
 * INV-02: only the probe flag is kept in sessionStorage; no user rules,
 * subscriptions or stats are ever written here.
 */
(function () {
  "use strict";

  var BRIDGE_URL = "http://127.0.0.1:3001/status";
  var PROBE_FILE = "/data/adb/aghf/logs/probe.txt"; // §1.1 fixed AGHF data path

  var probeCard = document.getElementById("probe-card");
  var statusCard = document.getElementById("status-card");

  function renderProbe(result) {
    var lines = [];
    lines.push('<p>' +
      'bridge_fetch=<span class="' + (result.bridge_fetch ? "ok" : "err") + '">' +
      result.bridge_fetch + '</span> · ksu_exec=<span class="' +
      (result.ksu_exec ? "ok" : "warn") + '">' + result.ksu_exec + '</span></p>');
    if (result.status) {
      lines.push("<p>" + JSON.stringify(result.status) + "</p>");
    }
    if (result.unreachable) {
      lines.push('<p class="err">BRIDGE_UNREACHABLE — WebUI in read-only mode (§9)</p>');
    }
    probeCard.innerHTML = lines.join("");
    if (result.status) {
      statusCard.innerHTML =
        "<h3>AGH Status</h3><p>" +
        'agh_running=<span class="' +
        (result.status.agh_running ? "ok" : "warn") + '">' + result.status.agh_running +
        '</span> · impl=<code>' + (result.status.impl || "unknown") + "</code></p>";
    }
  }

  function writeProbeFile(result) {
    // Best-effort persistent marker readable by P0-T4 acceptance.
    var text = "ts=" + new Date().toISOString() +
      " bridge_fetch=" + result.bridge_fetch +
      " ksu_exec=" + result.ksu_exec +
      (result.status ? " status=" + JSON.stringify(result.status) : " unreachable=1");
    if (window.ksu && window.ksu.exec) {
      var cmd = "printf '%s\\n' '" + text.replace(/'/g, "") + "' >> " + PROBE_FILE;
      try { window.ksu.exec(cmd); } catch (e) { /* best effort only */ }
    }
  }

  function viaFetch(onDone) {
    fetch(BRIDGE_URL, { method: "GET", cache: "no-store" })
      .then(function (r) {
        if (!r.ok) { throw new Error("HTTP " + r.status); }
        return r.json();
      })
      .then(function (status) {
        sessionStorage.setItem("AGHF_BRIDGE_FETCH", "1");
        var res = { bridge_fetch: 1, ksu_exec: 0, status: status };
        renderProbe(res);
        writeProbeFile(res);
        onDone(res);
      })
      .catch(function () { onKsuExec(onDone); });
  }

  function onKsuExec(onDone) {
    if (window.ksu && window.ksu.exec) {
      var cmd = "curl -s " + BRIDGE_URL + " 2>/dev/null || wget -qO- " + BRIDGE_URL +
        " 2>/dev/null || echo BRIDGE_DOWN";
      try {
        window.ksu.exec(cmd, function (err, stdout) {
          var res = { bridge_fetch: 0, ksu_exec: 1 };
          var s = String(stdout == null ? "" : stdout).trim();
          if (s && s !== "BRIDGE_DOWN") {
            try { res.status = JSON.parse(s); } catch (e) { res.status = null; }
          }
          if (!res.status) { res.unreachable = 1; }
          renderProbe(res);
          writeProbeFile(res);
          onDone(res);
        });
        return;
      } catch (e) { /* fall through */ }
    }
    var res2 = { bridge_fetch: 0, ksu_exec: 0, unreachable: 1 };
    renderProbe(res2);
    writeProbeFile(res2);
    onDone(res2);
  }

  viaFetch(function () { /* rendered */ });
})();
