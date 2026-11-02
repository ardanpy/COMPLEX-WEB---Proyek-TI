/* =========================================================
   COMPLEX — Interaksi halaman Kebersihan
   Laporan disimpan pada localStorage browser (prototipe lokal).
   Tujuan laporan dicatat sebagai Pengurus RT atau Penanggung
   Jawab Kebersihan. Pengiriman notifikasi membutuhkan backend.
   ========================================================= */
(function () {
  "use strict";

  var STORAGE_KEY = "cx_kebersihan_reports_v1";
  var DEFAULT_RECIPIENT = "Penanggung Jawab Kebersihan";
  var seedReports = [
    {
      id: "seed-1",
      title: "Sampah menumpuk Jati 1",
      location: "Jati 1",
      date: "2026-10-14",
      status: "Diproses",
      recipient: DEFAULT_RECIPIENT,
      description:
        "Sampah menumpuk di area Jati 1 dan menunggu penanganan petugas.",
      createdAt: "2026-10-14T08:00:00",
    },
    {
      id: "seed-2",
      title: "Selokan tersumbat Jati 3",
      location: "Jati 3",
      date: "2026-10-14",
      status: "Dikirim",
      recipient: "Pengurus RT",
      description: "Saluran air di Jati 3 tersumbat oleh sampah.",
      createdAt: "2026-10-14T09:00:00",
    },
    {
      id: "seed-3",
      title: "Tong sampah penuh",
      location: "Area taman",
      date: "2026-10-14",
      status: "Selesai",
      recipient: DEFAULT_RECIPIENT,
      description: "Tong sampah di area taman telah dikosongkan.",
      createdAt: "2026-10-14T10:00:00",
    },
  ];

  var modal = document.getElementById("sampahFormModal");
  var form = document.getElementById("sampahForm");
  var openButton = document.getElementById("btnOpenSampahForm");
  var titleInput = document.getElementById("sampahTitle");
  var locationInput = document.getElementById("sampahLocation");
  var recipientInput = document.getElementById("sampahRecipient");
  var descriptionInput = document.getElementById("sampahDescription");
  var statusList = document.getElementById("statusList");
  var toast = document.getElementById("kebersihanToast");
  var reports = loadReports();
  var toastTimer = null;
  var lastFocusedElement = null;

  function safeStorageGet(key) {
    try {
      return window.localStorage.getItem(key);
    } catch (error) {
      return null;
    }
  }

  function safeStorageSet(key, value) {
    try {
      window.localStorage.setItem(key, value);
      return true;
    } catch (error) {
      return false;
    }
  }

  function isValidReport(report) {
    return (
      !!report &&
      typeof report === "object" &&
      typeof report.id === "string" &&
      typeof report.title === "string"
    );
  }

  // Migrasi nama lama agar laporan yang sudah tersimpan ikut memakai Jati 1–7.
  function renameLegacyBlocks(value) {
    return String(value || "")
      .replace(/\bBlok\s+A\b/gi, "Jati 1")
      .replace(/\bBlok\s+B\b/gi, "Jati 2")
      .replace(/\bBlok\s+C\b/gi, "Jati 3");
  }

  function normalizeReport(report) {
    var normalized = Object.assign({}, report);
    ["title", "location", "description"].forEach(function (key) {
      if (typeof normalized[key] === "string") {
        normalized[key] = renameLegacyBlocks(normalized[key]);
      }
    });
    if (!normalized.recipient) normalized.recipient = DEFAULT_RECIPIENT;
    return normalized;
  }

  function loadReports() {
    var raw = safeStorageGet(STORAGE_KEY);

    if (raw) {
      try {
        var parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) {
          var normalized = parsed.filter(isValidReport).map(normalizeReport);
          // Simpan hasil migrasi hanya bila ada perubahan; status/tanggal/id tetap.
          if (JSON.stringify(parsed) !== JSON.stringify(normalized)) {
            safeStorageSet(STORAGE_KEY, JSON.stringify(normalized));
          }
          return normalized;
        }
      } catch (error) {
        // Gunakan data contoh jika data browser tidak dapat dibaca.
      }
    }

    var initial = seedReports.map(function (report) {
      return Object.assign({}, report);
    });
    safeStorageSet(STORAGE_KEY, JSON.stringify(initial));
    return initial;
  }

  function saveReports() {
    return safeStorageSet(STORAGE_KEY, JSON.stringify(reports));
  }

  function localDateString(date) {
    var value = date || new Date();
    var year = value.getFullYear();
    var month = String(value.getMonth() + 1).padStart(2, "0");
    var day = String(value.getDate()).padStart(2, "0");
    return year + "-" + month + "-" + day;
  }

  function formatDate(value) {
    if (!value) return "—";
    var parts = String(value).split("-");
    if (parts.length !== 3) return value;

    var date = new Date(
      Number(parts[0]),
      Number(parts[1]) - 1,
      Number(parts[2]),
    );
    if (Number.isNaN(date.getTime())) return value;

    return new Intl.DateTimeFormat("id-ID", {
      day: "2-digit",
      month: "short",
      year: "numeric",
    }).format(date);
  }

  function statusClass(status) {
    var value = String(status || "").toLowerCase();
    if (value === "dikirim") return "status-dikirim";
    if (value === "diproses") return "status-diproses";
    if (value === "selesai") return "status-selesai";
    if (value === "ditolak") return "status-ditolak";
    return "status-dikirim";
  }

  function createElement(tagName, className, text) {
    var element = document.createElement(tagName);
    if (className) element.className = className;
    if (text != null) element.textContent = text;
    return element;
  }

  function render() {
    var fragment = document.createDocumentFragment();
    var visibleReports = reports.slice().sort(function (a, b) {
      var aDate = a.createdAt || a.date || "";
      var bDate = b.createdAt || b.date || "";
      return bDate.localeCompare(aDate);
    });

    visibleReports.forEach(function (report) {
      var item = createElement("article", "status-item");
      var title = createElement("h3", "", report.title || "Laporan sampah");
      var date = createElement(
        "p",
        "",
        "Dilaporkan " + formatDate(report.date),
      );
      var routing = createElement(
        "p",
        "status-routing",
        "Lokasi: " +
          (report.location || "—") +
          " · Tujuan: " +
          (report.recipient || DEFAULT_RECIPIENT),
      );
      var badge = createElement(
        "span",
        "status-badge " + statusClass(report.status),
        report.status || "Dikirim",
      );

      item.appendChild(title);
      item.appendChild(date);
      item.appendChild(routing);
      item.appendChild(badge);
      fragment.appendChild(item);
    });

    if (visibleReports.length === 0) {
      fragment.appendChild(
        createElement(
          "p",
          "status-empty",
          "Belum ada laporan sampah. Gunakan tombol Laporkan Sampah untuk membuat laporan baru.",
        ),
      );
    }

    statusList.replaceChildren(fragment);
  }

  function showToast(message) {
    toast.textContent = message;
    toast.classList.add("is-visible");

    if (toastTimer) window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      toast.classList.remove("is-visible");
    }, 4200);
  }

  function openModal() {
    lastFocusedElement = document.activeElement;
    form.reset();
    recipientInput.value = DEFAULT_RECIPIENT;
    modal.hidden = false;
    document.body.classList.add("kebersihan-modal-open");
    window.setTimeout(function () {
      titleInput.focus();
    }, 0);
  }

  function closeModal() {
    if (!modal || modal.hidden) return;
    modal.hidden = true;
    document.body.classList.remove("kebersihan-modal-open");

    if (lastFocusedElement && typeof lastFocusedElement.focus === "function") {
      lastFocusedElement.focus();
    }
  }

  function createId() {
    if (window.crypto && typeof window.crypto.randomUUID === "function") {
      return window.crypto.randomUUID();
    }
    return (
      "sampah-" +
      Date.now().toString(36) +
      "-" +
      Math.random().toString(36).slice(2, 8)
    );
  }

  function handleSubmit(event) {
    event.preventDefault();
    if (!form.reportValidity()) return;

    var report = {
      id: createId(),
      title: titleInput.value.trim(),
      location: locationInput.value,
      recipient: recipientInput.value,
      description: descriptionInput.value.trim(),
      date: localDateString(),
      status: "Dikirim",
      createdAt: new Date().toISOString(),
    };

    if (
      !report.title ||
      !report.location ||
      !report.recipient ||
      !report.description
    )
      return;

    reports.push(report);
    var stored = saveReports();

    if (
      window.ComplexNotifications &&
      typeof window.ComplexNotifications.add === "function"
    ) {
      window.ComplexNotifications.add({
        category: "Sistem",
        title: "Laporan kebersihan terkirim",
        description:
          report.title + " telah dikirim kepada " + report.recipient + ".",
        link: "kebersihan.html",
        sourceKey: "feature:cx_kebersihan_reports_v1::" + report.id,
      });
    }

    render();
    closeModal();

    showToast(
      stored
        ? "Laporan tercatat untuk " +
            report.recipient +
            " dan tersimpan di browser ini. Notifikasi langsung belum aktif."
        : "Laporan tercatat untuk " +
            report.recipient +
            ", tetapi penyimpanan browser tidak tersedia.",
    );
  }

  function bindEvents() {
    openButton.addEventListener("click", openModal);
    form.addEventListener("submit", handleSubmit);

    modal.addEventListener("click", function (event) {
      if (event.target.closest("[data-close-sampah-modal]")) {
        closeModal();
      }
    });

    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && !modal.hidden) {
        closeModal();
      }
    });
  }

  render();
  bindEvents();
})();
