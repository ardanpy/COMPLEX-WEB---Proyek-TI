/* =========================================================

   COMPLEX — Interaksi halaman Lapor

   Vanilla JavaScript; data demo disimpan lokal di browser.

   ========================================================= */

(function () {

  "use strict";



  var STORAGE_KEY = "cx_lapor_reports_v1";

  var seedReports = [

    { id: "seed-1", title: "Sampah menumpuk di Blok A", category: "Kebersihan", date: "2026-10-14", status: "Diproses", location: "Blok A", description: "Sampah menumpuk di area tempat pembuangan sementara dan belum diangkut. Mohon dilakukan pengecekan dan pengangkutan.", createdBy: "Warga COMPLEX", createdAt: "2026-10-14T08:00:00" },

    { id: "seed-2", title: "Lampu jalan mati", category: "Fasilitas", date: "2026-10-12", status: "Dikirim", location: "Jalan utama Blok B", description: "Lampu penerangan jalan tidak menyala pada malam hari sehingga area menjadi gelap.", createdBy: "Warga COMPLEX", createdAt: "2026-10-12T19:30:00" },

    { id: "seed-3", title: "Pagar taman rusak", category: "Fasilitas", date: "2026-10-10", status: "Selesai", location: "Taman tengah", description: "Salah satu bagian pagar taman rusak. Perbaikan telah diselesaikan.", createdBy: "Warga COMPLEX", createdAt: "2026-10-10T10:00:00" },

    { id: "seed-4", title: "Orang tidak dikenal", category: "Keamanan", date: "2026-10-08", status: "Selesai", location: "Dekat gerbang utama", description: "Ada orang tidak dikenal yang terlihat berulang kali berada di sekitar gerbang utama. Petugas telah melakukan pengecekan.", createdBy: "Warga COMPLEX", createdAt: "2026-10-08T21:15:00" },

    { id: "seed-5", title: "Saluran air tersumbat", category: "Kebersihan", date: "2026-10-05", status: "Selesai", location: "Saluran Blok C", description: "Saluran air tersumbat oleh sampah dan sudah dibersihkan.", createdBy: "Warga COMPLEX", createdAt: "2026-10-05T07:45:00" },

    { id: "seed-6", title: "Kebisingan malam hari", category: "Lainnya", date: "2026-10-01", status: "Selesai", location: "Area Blok D", description: "Terdapat kebisingan pada malam hari. Pengurus telah memberikan imbauan kepada warga terkait.", createdBy: "Warga COMPLEX", createdAt: "2026-10-01T23:10:00" }

  ];



  var elements = {};

  var reports = [];

  var activeTab = "list";

  var toastTimer = null;

  var lastFocusedElement = null;

  var currentUser = readCurrentUser();



  function byId(id) { return document.getElementById(id); }



  function safeStorageGet(key) {

    try { return window.localStorage.getItem(key); }

    catch (error) { return null; }

  }



  function safeStorageSet(key, value) {

    try { window.localStorage.setItem(key, value); return true; }

    catch (error) { return false; }

  }



  function parseObject(raw) {

    try {

      var value = raw ? JSON.parse(raw) : {};

      return value && typeof value === "object" ? value : {};

    } catch (error) { return {}; }

  }



  function readCurrentUser() {

    var active = {};

    var stored = {};

    try { active = parseObject(window.sessionStorage.getItem("cx_active_profile")); } catch (error) {}

    try { stored = parseObject(window.localStorage.getItem("cx_profile")); } catch (error) {}

    var name = active.nama || active.namaLengkap || stored.nama || stored.namaLengkap || "";

    if (!name) {

      try { name = window.sessionStorage.getItem("cx_nama") || window.localStorage.getItem("cx_nama") || ""; } catch (error) {}

    }

    return String(name || "Pengguna").trim() || "Pengguna";

  }



  function loadReports() {

    var raw = safeStorageGet(STORAGE_KEY);

    if (raw) {

      try {

        var parsed = JSON.parse(raw);

        if (Array.isArray(parsed)) return parsed.filter(isValidReport);

      } catch (error) {}

    }

    var initial = seedReports.map(function (report) { return Object.assign({}, report); });

    safeStorageSet(STORAGE_KEY, JSON.stringify(initial));

    return initial;

  }



  function isValidReport(report) {

    return !!report && typeof report === "object" && typeof report.id === "string" && typeof report.title === "string";

  }



  function saveReports() {

    return safeStorageSet(STORAGE_KEY, JSON.stringify(reports));

  }



  function localDateString(date) {

    var d = date || new Date();

    var year = d.getFullYear();

    var month = String(d.getMonth() + 1).padStart(2, "0");

    var day = String(d.getDate()).padStart(2, "0");

    return year + "-" + month + "-" + day;

  }



  function formatDate(value) {

    if (!value) return "—";

    var parts = String(value).split("-");

    if (parts.length !== 3) return value;

    var date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));

    if (Number.isNaN(date.getTime())) return value;

    return new Intl.DateTimeFormat("id-ID", { day: "2-digit", month: "short", year: "numeric" }).format(date);

  }



  function statusClass(status) {

    var value = String(status || "").toLowerCase();

    if (value === "dikirim") return "lapor-status-dikirim";

    if (value === "diproses") return "lapor-status-diproses";

    if (value === "selesai") return "lapor-status-selesai";

    if (value === "ditolak") return "lapor-status-ditolak";

    return "lapor-status-default";

  }



  function createStatusBadge(status) {

    var badge = document.createElement("span");

    badge.className = "lapor-status-badge " + statusClass(status);

    badge.textContent = status || "Belum diatur";

    return badge;

  }



  function makeCell(text, className) {

    var cell = document.createElement("td");

    if (className) cell.className = className;

    cell.textContent = text == null ? "—" : String(text);

    return cell;

  }



  function getVisibleReports() {

    var query = (elements.search.value || "").trim().toLocaleLowerCase("id-ID");

    var status = elements.statusFilter.value;

    var list = reports.slice();



    if (activeTab === "history") {

      list = list.filter(function (report) { return report.createdBy === currentUser; });

    }

    if (status !== "all") {

      list = list.filter(function (report) { return report.status === status; });

    }

    if (query) {

      list = list.filter(function (report) {

        var searchable = [report.title, report.category, report.location, report.status, report.description].join(" ").toLocaleLowerCase("id-ID");

        return searchable.indexOf(query) !== -1;

      });

    }

    list.sort(function (a, b) {

      var aDate = a.createdAt || a.date || "";

      var bDate = b.createdAt || b.date || "";

      return bDate.localeCompare(aDate);

    });

    return list;

  }



  function render() {

    var visible = getVisibleReports();

    var fragment = document.createDocumentFragment();



    visible.forEach(function (report, index) {

      var row = document.createElement("tr");

      row.appendChild(makeCell(index + 1));

      row.appendChild(makeCell(report.title, "lapor-title-cell"));

      row.appendChild(makeCell(report.category));

      row.appendChild(makeCell(formatDate(report.date)));

      var statusCell = document.createElement("td");

      statusCell.appendChild(createStatusBadge(report.status));

      row.appendChild(statusCell);

      var actionCell = document.createElement("td");

      actionCell.className = "lapor-col-action";

      var detailButton = document.createElement("button");

      detailButton.type = "button";

      detailButton.className = "lapor-detail-button";

      detailButton.textContent = "Detail";

      detailButton.setAttribute("data-report-id", report.id);

      detailButton.setAttribute("aria-label", "Lihat detail: " + report.title);

      actionCell.appendChild(detailButton);

      row.appendChild(actionCell);

      fragment.appendChild(row);

    });



    elements.tableBody.replaceChildren(fragment);

    elements.tableWrap.hidden = visible.length === 0;

    elements.emptyState.hidden = visible.length !== 0;

    elements.resultsCount.textContent = visible.length + (visible.length === 1 ? " laporan" : " laporan");



    if (activeTab === "history" && !reports.some(function (report) { return report.createdBy === currentUser; })) {

      elements.emptyTitle.textContent = "Belum ada riwayat laporan";

      elements.emptyDescription.textContent = "Laporan yang kamu buat akan muncul di sini setelah dikirim.";

    } else {

      elements.emptyTitle.textContent = "Laporan tidak ditemukan";

      elements.emptyDescription.textContent = "Coba ubah kata kunci atau filter status yang dipilih.";

    }



    elements.tabPanel.setAttribute("aria-labelledby", activeTab === "history" ? "tabRiwayatLaporan" : "tabDaftarLaporan");

    elements.tabs.forEach(function (tab) {

      var selected = tab.getAttribute("data-tab") === activeTab;

      tab.classList.toggle("is-active", selected);

      tab.setAttribute("aria-selected", selected ? "true" : "false");

      tab.tabIndex = selected ? 0 : -1;

    });

  }



  function showToast(message) {

    elements.toast.textContent = message;

    elements.toast.classList.add("is-visible");

    if (toastTimer) window.clearTimeout(toastTimer);

    toastTimer = window.setTimeout(function () { elements.toast.classList.remove("is-visible"); }, 3200);

  }



  function openModal(modal, focusTarget) {

    lastFocusedElement = document.activeElement;

    modal.hidden = false;

    document.body.classList.add("lapor-modal-open");

    if (focusTarget) window.setTimeout(function () { focusTarget.focus(); }, 0);

  }



  function closeModal(modal) {

    if (!modal) return;

    modal.hidden = true;

    if (document.querySelectorAll(".lapor-modal:not([hidden])").length === 0) {

      document.body.classList.remove("lapor-modal-open");

    }

    if (lastFocusedElement && typeof lastFocusedElement.focus === "function") lastFocusedElement.focus();

  }



  function openCreateForm() {

    elements.form.reset();

    elements.date.value = localDateString();

    openModal(elements.formModal, elements.titleInput);

  }



  function openDetail(report) {

    if (!report) return;

    elements.detailTitle.textContent = report.title || "Detail laporan";

    elements.detailDate.textContent = formatDate(report.date);

    elements.detailStatus.className = "lapor-status-badge " + statusClass(report.status);

    elements.detailStatus.textContent = report.status || "Belum diatur";

    elements.detailCategory.textContent = report.category || "—";

    elements.detailLocation.textContent = report.location || "—";

    elements.detailReporter.textContent = report.createdBy || "—";

    elements.detailDescription.textContent = report.description || "Tidak ada keterangan tambahan.";

    openModal(elements.detailModal, elements.detailCloseButton);

  }



  function createId() {

    if (window.crypto && typeof window.crypto.randomUUID === "function") return window.crypto.randomUUID();

    return "lapor-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8);

  }



  function handleSubmit(event) {

    event.preventDefault();

    if (!elements.form.reportValidity()) return;



    var report = {

      id: createId(),

      title: elements.titleInput.value.trim(),

      category: elements.category.value,

      date: elements.date.value,

      status: "Dikirim",

      location: elements.location.value.trim(),

      description: elements.description.value.trim(),

      createdBy: currentUser,

      createdAt: new Date().toISOString()

    };



    if (!report.title || !report.location || !report.description) return;

    reports.push(report);

    var stored = saveReports();

    if (window.ComplexNotifications && typeof window.ComplexNotifications.add === "function") {
      window.ComplexNotifications.add({
        category: "Sistem",
        title: "Laporan berhasil dibuat",
        description: report.title + " (" + report.category + ") berhasil dikirim untuk ditindaklanjuti.",
        link: "lapor.html",
        sourceKey: "feature:cx_lapor_reports_v1::" + report.id
      });
    }

    closeModal(elements.formModal);

    activeTab = "list";

    elements.search.value = "";

    elements.statusFilter.value = "all";

    render();

    showToast(stored ? "Laporan berhasil dibuat dan tersimpan di browser ini." : "Laporan dibuat, tetapi penyimpanan browser tidak tersedia.");

  }



  function bindEvents() {

    elements.openForm.addEventListener("click", openCreateForm);

    elements.form.addEventListener("submit", handleSubmit);

    elements.search.addEventListener("input", render);

    elements.statusFilter.addEventListener("change", render);

    elements.resetFilter.addEventListener("click", function () {

      elements.search.value = "";

      elements.statusFilter.value = "all";

      render();

    });



    elements.tabs.forEach(function (tab) {

      tab.addEventListener("click", function () {

        activeTab = tab.getAttribute("data-tab") || "list";

        render();

      });

      tab.addEventListener("keydown", function (event) {

        if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;

        event.preventDefault();

        var nextTab = event.key === "ArrowRight" ? elements.tabs[1] : elements.tabs[0];

        nextTab.focus();

        nextTab.click();

      });

    });



    elements.tableBody.addEventListener("click", function (event) {

      var button = event.target.closest("[data-report-id]");

      if (!button) return;

      var report = reports.find(function (item) { return item.id === button.getAttribute("data-report-id"); });

      openDetail(report);

    });



    document.addEventListener("click", function (event) {

      var closeTarget = event.target.closest("[data-close-lapor-modal]");

      if (!closeTarget) return;

      var modal = closeTarget.closest(".lapor-modal");

      closeModal(modal);

    });



    document.addEventListener("keydown", function (event) {

      if (event.key !== "Escape") return;

      var openModals = document.querySelectorAll(".lapor-modal:not([hidden])");

      if (openModals.length) closeModal(openModals[openModals.length - 1]);

    });

  }



  function init() {

    elements.openForm = byId("btnOpenLaporForm");

    elements.formModal = byId("laporFormModal");

    elements.detailModal = byId("laporDetailModal");

    elements.form = byId("laporForm");

    elements.titleInput = byId("laporTitle");

    elements.category = byId("laporCategory");

    elements.date = byId("laporDate");

    elements.location = byId("laporLocation");

    elements.description = byId("laporDescription");

    elements.search = byId("laporSearch");

    elements.statusFilter = byId("laporStatusFilter");

    elements.tableWrap = byId("laporTableWrap");

    elements.tableBody = byId("laporTableBody");

    elements.emptyState = byId("laporEmptyState");

    elements.emptyTitle = byId("laporEmptyTitle");

    elements.emptyDescription = byId("laporEmptyDescription");

    elements.resultsCount = byId("laporResultsCount");

    elements.resetFilter = byId("btnResetLaporFilter");

    elements.tabs = Array.prototype.slice.call(document.querySelectorAll(".lapor-tab"));

    elements.tabPanel = byId("laporTabPanel");

    elements.toast = byId("laporToast");

    elements.detailTitle = byId("laporDetailTitle");

    elements.detailDate = byId("laporDetailDate");

    elements.detailStatus = byId("laporDetailStatus");

    elements.detailCategory = byId("laporDetailCategory");

    elements.detailLocation = byId("laporDetailLocation");

    elements.detailReporter = byId("laporDetailReporter");

    elements.detailDescription = byId("laporDetailDescription");

    elements.detailCloseButton = elements.detailModal ? elements.detailModal.querySelector(".lapor-modal-close") : null;



    if (!elements.openForm || !elements.form || !elements.tableBody || !elements.detailModal || !elements.formModal || !elements.search || !elements.statusFilter || !elements.tableWrap || !elements.emptyState || !elements.resultsCount || !elements.tabs.length || !elements.tabPanel || !elements.toast) return;

    reports = loadReports();

    bindEvents();

    render();

  }



  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init, { once: true });

  else init();

})();
