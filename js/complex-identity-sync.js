/* COMPLEX — sinkronisasi nama pengguna di topbar halaman turunan. */
(function () {
  "use strict";
  function readJson(storage, key) {
    try {
      var raw = storage.getItem(key);
      var value = raw ? JSON.parse(raw) : {};
      return value && typeof value === "object" ? value : {};
    } catch (error) { return {}; }
  }
  function readValue(storage, key) {
    try { return (storage.getItem(key) || "").trim(); }
    catch (error) { return ""; }
  }
  function firstNonEmpty() {
    for (var i = 0; i < arguments.length; i++) {
      if (typeof arguments[i] === "string" && arguments[i].trim()) return arguments[i].trim();
    }
    return "";
  }
  function renderIdentity() {
    var active = readJson(window.sessionStorage, "cx_active_profile");
    var stored = readJson(window.localStorage, "cx_profile");
    var fullName = firstNonEmpty(
      active.nama,
      readValue(window.sessionStorage, "cx_nama"),
      stored.nama,
      readValue(window.localStorage, "cx_nama"),
      active.namaLengkap,
      stored.namaLengkap
    );
    var topbarName = document.getElementById("topbarUsername");
    if (topbarName) topbarName.textContent = fullName ? fullName.split(/\s+/)[0] : "Pengguna";
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", renderIdentity, { once: true });
  } else { renderIdentity(); }
  window.addEventListener("pageshow", renderIdentity);
  window.addEventListener("focus", renderIdentity);
  window.addEventListener("storage", renderIdentity);
})();
