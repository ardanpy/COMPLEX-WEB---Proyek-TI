(function () {
  "use strict";

  var REPORTS_KEY = "cx_security_reports_v1";
  var GUARDS_KEY = "cx_security_guards_v1";

  var seedReports = [
    {
      id: "wireframe-1",
      title: "Orang tidak dikenal di Blok B",
      dateLabel: "Hari ini, 08.30",
      status: "Baru",
      location: "Blok B",
      description:
        "Laporan contoh dari wireframe. Keterangan tambahan belum tersedia.",
    },
    {
      id: "wireframe-2",
      title: "Gerbang utama rusak",
      dateLabel: "Kemarin, 19.15",
      status: "Ditangani",
      location: "Gerbang utama",
      description:
        "Laporan contoh dari wireframe. Keterangan tambahan belum tersedia.",
    },
    {
      id: "wireframe-3",
      title: "Kendaraan parkir sembarangan",
      dateLabel: "12 Okt, 14.00",
      status: "Selesai",
      location: "Area parkir",
      description:
        "Laporan contoh dari wireframe. Keterangan tambahan belum tersedia.",
    },
    {
      id: "wireframe-4",
      title: "Lampu jalan mati di Blok C",
      dateLabel: "10 Okt, 20.40",
      status: "Selesai",
      location: "Blok C",
      description:
        "Laporan contoh dari wireframe. Keterangan tambahan belum tersedia.",
    },
    {
      id: "wireframe-5",
      title: "Patroli malam tambahan",
      dateLabel: "08 Okt, 21.00",
      status: "Selesai",
      location: "Lingkungan COMPLEX",
      description:
        "Laporan contoh dari wireframe. Keterangan tambahan belum tersedia.",
    },
  ];

  var defaultGuards = {
    guards: [
      { name: "Petugas Keamanan 1", phone: "" },
      { name: "Petugas Keamanan 2", phone: "" },
    ],
    shiftStart: "07:00",
    configured: false,
  };

  var reports = readStorage(REPORTS_KEY, null);
  if (!Array.isArray(reports)) {
    reports = seedReports.slice();
    writeStorage(REPORTS_KEY, reports);
  }

  var guardSettings = readStorage(GUARDS_KEY, null);
  if (
    !guardSettings ||
    !Array.isArray(guardSettings.guards) ||
    guardSettings.guards.length !== 2
  ) {
    guardSettings = clone(defaultGuards);
  }

  var activeFilter = "Semua";
  var toastTimer = null;

  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function readStorage(key, fallback) {
    try {
      var raw = window.localStorage.getItem(key);
      return raw ? JSON.parse(raw) : fallback;
    } catch (error) {
      return fallback;
    }
  }

  function writeStorage(key, value) {
    try {
      window.localStorage.setItem(key, JSON.stringify(value));
      return true;
    } catch (error) {
      return false;
    }
  }

  function byId(id) {
    return document.getElementById(id);
  }

  function safeText(value) {
    return String(value == null ? "" : value);
  }

  function showToast(message, isError) {
    var toast = byId("securityToast");
    if (!toast) return;
    toast.textContent = message;
    toast.classList.toggle("error", !!isError);
    toast.classList.add("show");
    if (toastTimer) window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      toast.classList.remove("show");
    }, 2800);
  }

  function statusClass(status) {
    if (status === "Baru") return "status-baru";
    if (status === "Ditangani") return "status-ditangani";
    return "status-selesai";
  }

  function makeSvg(className) {
    var wrap = document.createElement("span");
    wrap.className = className;
    wrap.setAttribute("aria-hidden", "true");
    wrap.innerHTML =
      '<svg viewBox="0 0 24 24"><path d="M12 3 4.5 6v5.2c0 4.7 3.2 7.9 7.5 9.8 4.3-1.9 7.5-5.1 7.5-9.8V6L12 3Z"/><path d="m9 12 2 2 4-4"/></svg>';
    return wrap;
  }

  function renderReports() {
    var list = byId("securityReportList");
    var empty = byId("securityEmptyState");
    var total = byId("reportTotal");
    if (!list) return;

    var query = ((byId("reportSearch") && byId("reportSearch").value) || "")
      .trim()
      .toLowerCase();
    var filtered = reports.filter(function (report) {
      var matchesStatus =
        activeFilter === "Semua" || report.status === activeFilter;
      var searchable = [
        report.title,
        report.location,
        report.description,
        report.dateLabel,
      ]
        .join(" ")
        .toLowerCase();
      return matchesStatus && searchable.indexOf(query) !== -1;
    });

    list.textContent = "";
    filtered.forEach(function (report) {
      var button = document.createElement("button");
      button.type = "button";
      button.className = "security-report-item";
      button.setAttribute(
        "aria-label",
        "Buka detail laporan: " + safeText(report.title),
      );

      button.appendChild(makeSvg("security-report-icon"));

      var copy = document.createElement("span");
      copy.className = "security-report-copy";

      var title = document.createElement("strong");
      title.className = "security-report-title";
      title.textContent = safeText(report.title);

      var meta = document.createElement("span");
      meta.className = "security-report-meta";

      var date = document.createElement("span");
      date.textContent = safeText(report.dateLabel);

      var separator = document.createElement("span");
      separator.className = "security-meta-separator";
      separator.setAttribute("aria-hidden", "true");

      var location = document.createElement("span");
      location.textContent = safeText(report.location || "Lokasi belum diisi");

      meta.appendChild(date);
      meta.appendChild(separator);
      meta.appendChild(location);
      copy.appendChild(title);
      copy.appendChild(meta);

      var badge = document.createElement("span");
      badge.className = "security-status-badge " + statusClass(report.status);
      badge.textContent = safeText(report.status);

      button.appendChild(copy);
      button.appendChild(badge);
      button.addEventListener("click", function () {
        openReportDetail(report);
      });
      list.appendChild(button);
    });

    if (empty) empty.hidden = filtered.length > 0;
    if (total)
      total.textContent =
        filtered.length + (filtered.length === 1 ? " laporan" : " laporan");
  }

  function setFilter(status) {
    activeFilter = status;
    document.querySelectorAll(".security-filter").forEach(function (button) {
      var selected = button.getAttribute("data-status") === status;
      button.classList.toggle("active", selected);
      button.setAttribute("aria-pressed", selected ? "true" : "false");
    });
    renderReports();
  }

  function openModal(id) {
    var modal = byId(id);
    if (!modal) return;
    modal.hidden = false;
    document.body.classList.add("security-modal-open");
    var focusTarget = modal.querySelector("input, textarea, button");
    if (focusTarget)
      window.setTimeout(function () {
        focusTarget.focus();
      }, 30);
  }

  function closeModal(modal) {
    if (!modal) return;
    modal.hidden = true;
    if (!document.querySelector(".security-modal-overlay:not([hidden])")) {
      document.body.classList.remove("security-modal-open");
    }
  }

  function openReportDetail(report) {
    byId("detailModalTitle").textContent = safeText(report.title);
    byId("detailReportDate").textContent = safeText(report.dateLabel);
    byId("detailReportLocation").textContent = safeText(
      report.location || "Belum dicantumkan",
    );
    byId("detailReportDescription").textContent = safeText(
      report.description || "Belum ada keterangan tambahan.",
    );
    var badge = byId("detailReportStatus");
    badge.className = "security-status-badge " + statusClass(report.status);
    badge.textContent = safeText(report.status);
    openModal("reportDetailModal");
  }

  function formatTime(date) {
    return (
      String(date.getHours()).padStart(2, "0") +
      "." +
      String(date.getMinutes()).padStart(2, "0")
    );
  }

  function parseTime(value) {
    var parts = String(value || "07:00").split(":");
    var hour = Math.max(0, Math.min(23, parseInt(parts[0], 10) || 0));
    var minute = Math.max(0, Math.min(59, parseInt(parts[1], 10) || 0));
    return { hour: hour, minute: minute };
  }

  function shiftRange(startDate, durationHours) {
    var endDate = new Date(
      startDate.getTime() + durationHours * 60 * 60 * 1000,
    );
    return formatTime(startDate) + "–" + formatTime(endDate) + " WIB";
  }

  function calculateDuty(now) {
    var start = parseTime(guardSettings.shiftStart);
    var firstStart = new Date(
      now.getFullYear(),
      now.getMonth(),
      now.getDate(),
      start.hour,
      start.minute,
      0,
      0,
    );
    if (now.getTime() < firstStart.getTime()) {
      firstStart.setDate(firstStart.getDate() - 1);
    }

    var shiftMs = 12 * 60 * 60 * 1000;
    var elapsed = Math.max(0, now.getTime() - firstStart.getTime());
    var shiftNumber = Math.floor(elapsed / shiftMs);
    var currentIndex = shiftNumber % 2;
    var currentStart = new Date(firstStart.getTime() + shiftNumber * shiftMs);
    var nextStart = new Date(currentStart.getTime() + shiftMs);
    var nextIndex = (currentIndex + 1) % 2;

    return {
      currentIndex: currentIndex,
      nextIndex: nextIndex,
      currentStart: currentStart,
      nextStart: nextStart,
      currentRange: shiftRange(currentStart, 12),
      nextStartText: formatTime(nextStart) + " WIB",
    };
  }

  function normalizePhone(phone) {
    var digits = safeText(phone).replace(/\D/g, "");
    if (!digits) return "";
    if (digits.indexOf("0") === 0) digits = "62" + digits.slice(1);
    else if (digits.indexOf("8") === 0) digits = "62" + digits;
    if (digits.length < 8 || digits.length > 15) return "";
    return digits;
  }

  function makeGuardAction(label, href, iconMarkup, disabled) {
    var element = href
      ? document.createElement("a")
      : document.createElement("button");
    element.className = "security-guard-action";
    element.setAttribute("aria-label", label);
    element.setAttribute("title", label);
    if (href) {
      element.href = href;
      if (href.indexOf("wa.me") !== -1) {
        element.target = "_blank";
        element.rel = "noopener noreferrer";
      }
    } else {
      element.type = "button";
      element.disabled = true;
    }
    if (disabled) element.disabled = true;
    element.innerHTML = iconMarkup;
    return element;
  }

  function renderGuards() {
    var list = byId("securityGuardList");
    if (!list) return;

    var duty = calculateDuty(new Date());
    var currentGuard =
      guardSettings.guards[duty.currentIndex] ||
      defaultGuards.guards[duty.currentIndex];
    var nextGuard =
      guardSettings.guards[duty.nextIndex] ||
      defaultGuards.guards[duty.nextIndex];

    byId("currentGuardName").textContent = safeText(
      currentGuard.name || "Petugas belum diatur",
    );
    byId("currentShiftRange").textContent = duty.currentRange;
    byId("nextGuardName").textContent = safeText(
      nextGuard.name || "Petugas belum diatur",
    );
    byId("nextShiftInfo").textContent = "Mulai pukul " + duty.nextStartText;

    var dutyLabel = byId("dutyLabel");
    var dutyBadge = byId("currentDutyBadge");
    if (guardSettings.configured) {
      dutyLabel.textContent = "JADWAL PETUGAS AKTIF";
      dutyBadge.textContent = "Sedang jaga";
    } else {
      dutyLabel.textContent = "JADWAL CONTOH";
      dutyBadge.textContent = "Contoh";
    }

    list.textContent = "";
    guardSettings.guards.forEach(function (guard, index) {
      var card = document.createElement("article");
      card.className = "security-guard-card";

      var avatar = document.createElement("div");
      avatar.className =
        "security-guard-avatar" +
        (index === 1 ? " security-guard-avatar-alt" : "");
      avatar.textContent = String(index + 1);

      var info = document.createElement("div");
      info.className = "security-guard-info";

      var name = document.createElement("strong");
      name.textContent = safeText(
        guard.name || "Petugas Keamanan " + (index + 1),
      );

      var phone = document.createElement("span");
      phone.textContent = guard.phone
        ? safeText(guard.phone)
        : "Nomor belum diatur";

      info.appendChild(name);
      info.appendChild(phone);

      var actions = document.createElement("div");
      actions.className = "security-guard-actions";
      var normalized = normalizePhone(guard.phone);

      var callIcon =
        '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M22 16.9v3a2 2 0 0 1-2.2 2A19.8 19.8 0 0 1 11.2 19a19.4 19.4 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7l.4 2.8a2 2 0 0 1-.6 1.7L7.1 10a16 16 0 0 0 6 6l1.8-1.8a2 2 0 0 1 1.7-.6l2.8.4a2 2 0 0 1 1.6 2.9Z"/></svg>';
      var waIcon =
        '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20.5 11.7a8.5 8.5 0 0 1-12.6 7.4L3 20l.9-4.7a8.5 8.5 0 1 1 16.6-3.6Z"/><path d="M8.4 8.3c.3-.6.6-.6.9-.6h.5c.2 0 .4.1.5.4l.7 1.7c.1.2.1.4-.1.6l-.5.6c-.2.2-.2.4-.1.6.4.7 1 1.3 1.7 1.7.2.1.4.1.6-.1l.6-.5c.2-.2.4-.2.6-.1l1.7.7c.3.1.4.3.4.5v.5c0 .3 0 .6-.6.9-.5.3-1.2.4-2 .1-1.1-.4-2.4-1.2-3.5-2.3-1.1-1.1-1.9-2.4-2.3-3.5-.3-.8-.2-1.5.1-2Z"/></svg>';

      actions.appendChild(
        makeGuardAction(
          "Telepon " + name.textContent,
          normalized ? "tel:+" + normalized : "",
          callIcon,
          !normalized,
        ),
      );
      actions.appendChild(
        makeGuardAction(
          "WhatsApp " + name.textContent,
          normalized ? "https://wa.me/" + normalized : "",
          waIcon,
          !normalized,
        ),
      );

      card.appendChild(avatar);
      card.appendChild(info);
      card.appendChild(actions);
      list.appendChild(card);
    });
  }

  function fillGuardForm() {
    byId("guardOneName").value = guardSettings.guards[0].name || "";
    byId("guardOnePhone").value = guardSettings.guards[0].phone || "";
    byId("guardTwoName").value = guardSettings.guards[1].name || "";
    byId("guardTwoPhone").value = guardSettings.guards[1].phone || "";
    byId("guardShiftStart").value = guardSettings.shiftStart || "07:00";
    openModal("guardSettingsModal");
  }

  function updateIdentity() {
    function readJson(storage, key) {
      try {
        var raw = storage.getItem(key);
        var value = raw ? JSON.parse(raw) : {};
        return value && typeof value === "object" ? value : {};
      } catch (error) {
        return {};
      }
    }
    function readValue(storage, key) {
      try {
        return (storage.getItem(key) || "").trim();
      } catch (error) {
        return "";
      }
    }
    var sessionStore;
    var localStore;
    try {
      sessionStore = window.sessionStorage;
    } catch (error) {
      sessionStore = {
        getItem: function () {
          return null;
        },
      };
    }
    try {
      localStore = window.localStorage;
    } catch (error) {
      localStore = {
        getItem: function () {
          return null;
        },
      };
    }
    var active = readJson(sessionStore, "cx_active_profile");
    var stored = readJson(localStore, "cx_profile");
    var name =
      active.nama ||
      readValue(sessionStore, "cx_nama") ||
      stored.nama ||
      readValue(localStore, "cx_nama") ||
      active.namaLengkap ||
      stored.namaLengkap ||
      "Pengguna";
    var firstName = String(name).trim().split(/\s+/)[0] || "Pengguna";
    var topbarName = byId("topbarUsername");
    if (topbarName) topbarName.textContent = firstName;
  }

  function openNewReport() {
    byId("securityReportForm").reset();
    openModal("reportFormModal");
  }

  function handleNewReport(event) {
    event.preventDefault();
    var title = byId("newReportTitle").value.trim();
    var location = byId("newReportLocation").value.trim();
    var description = byId("newReportDescription").value.trim();

    if (!title || !location || !description) {
      showToast("Lengkapi semua informasi laporan terlebih dahulu.", true);
      return;
    }

    var now = new Date();
    var report = {
      id: "resident-" + Date.now(),
      title: title,
      dateLabel: "Hari ini, " + formatTime(now),
      status: "Baru",
      location: location,
      description: description,
    };
    reports.unshift(report);
    var saved = writeStorage(REPORTS_KEY, reports);

    if (
      window.ComplexNotifications &&
      typeof window.ComplexNotifications.add === "function"
    ) {
      window.ComplexNotifications.add({
        category: "Sistem",
        title: "Laporan keamanan baru",
        description:
          report.title + " di " + report.location + " telah dicatat.",
        link: "keamanan.html",
        sourceKey: "feature:cx_security_reports_v1::" + report.id,
      });
    }

    closeModal(byId("reportFormModal"));
    renderReports();
    showToast(
      saved
        ? "Laporan berhasil ditambahkan."
        : "Laporan ditambahkan sementara, tetapi browser tidak mengizinkan penyimpanan.",
      !saved,
    );
  }

  function handleGuardSettings(event) {
    event.preventDefault();
    var nameOne = byId("guardOneName").value.trim();
    var phoneOne = byId("guardOnePhone").value.trim();
    var nameTwo = byId("guardTwoName").value.trim();
    var phoneTwo = byId("guardTwoPhone").value.trim();
    var shiftStart = byId("guardShiftStart").value || "07:00";

    if (!nameOne || !nameTwo) {
      showToast("Nama kedua petugas wajib diisi.", true);
      return;
    }

    guardSettings = {
      guards: [
        { name: nameOne, phone: phoneOne },
        { name: nameTwo, phone: phoneTwo },
      ],
      shiftStart: shiftStart,
      configured: true,
    };

    var saved = writeStorage(GUARDS_KEY, guardSettings);
    closeModal(byId("guardSettingsModal"));
    renderGuards();
    showToast(
      saved
        ? "Data petugas dan jadwal shift berhasil disimpan."
        : "Pengaturan tersimpan sementara di halaman ini.",
      !saved,
    );
  }

  function bindEvents() {
    document.querySelectorAll(".security-filter").forEach(function (button) {
      button.addEventListener("click", function () {
        setFilter(button.getAttribute("data-status") || "Semua");
      });
    });

    var reportSearch = byId("reportSearch");
    if (reportSearch) reportSearch.addEventListener("input", renderReports);

    var topSearch = byId("searchInput");
    if (topSearch) {
      topSearch.addEventListener("input", function () {
        if (reportSearch) {
          reportSearch.value = topSearch.value;
          renderReports();
        }
      });
    }

    var openReportButton = byId("btnOpenReportForm");
    if (openReportButton)
      openReportButton.addEventListener("click", openNewReport);

    var manageGuardsButton = byId("btnManageGuards");
    if (manageGuardsButton)
      manageGuardsButton.addEventListener("click", fillGuardForm);

    var reportForm = byId("securityReportForm");
    if (reportForm) reportForm.addEventListener("submit", handleNewReport);

    var guardForm = byId("guardSettingsForm");
    if (guardForm) guardForm.addEventListener("submit", handleGuardSettings);

    document.querySelectorAll("[data-close-modal]").forEach(function (button) {
      button.addEventListener("click", function () {
        closeModal(button.closest(".security-modal-overlay"));
      });
    });

    document
      .querySelectorAll(".security-modal-overlay")
      .forEach(function (overlay) {
        overlay.addEventListener("click", function (event) {
          if (event.target === overlay) closeModal(overlay);
        });
      });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        document
          .querySelectorAll(".security-modal-overlay:not([hidden])")
          .forEach(closeModal);
      }
    });

    window.addEventListener("storage", function (event) {
      if (event.key === GUARDS_KEY) {
        guardSettings =
          readStorage(GUARDS_KEY, clone(defaultGuards)) || clone(defaultGuards);
        renderGuards();
      }
      if (event.key === REPORTS_KEY) {
        reports =
          readStorage(REPORTS_KEY, seedReports.slice()) || seedReports.slice();
        renderReports();
      }
    });
  }

  // Fallback for the existing header/sidebar buttons that are still placeholders.
  window.showPlaceholder =
    window.showPlaceholder ||
    function (featureName) {
      showToast(
        safeText(featureName) + " akan dikembangkan pada tahap berikutnya.",
      );
    };

  document.addEventListener("DOMContentLoaded", function () {
    updateIdentity();
    renderReports();
    renderGuards();
    bindEvents();
    window.addEventListener("pageshow", updateIdentity);
    window.addEventListener("focus", updateIdentity);

    // Refresh the duty indicator when the page remains open across a shift change.
    window.setInterval(renderGuards, 60000);
  });
})();
