/* =========================================================
   COMPLEX — Navigasi bersama + pusat notifikasi lokal.
   Tidak mengubah layout halaman; hanya mengaktifkan rute,
   indikator notifikasi, dan penyimpanan notifikasi browser.
   ========================================================= */
(function () {
  "use strict";

  var NOTIFICATION_KEY = "cx_notifications_v1";
  var REPORT_SYNC_KEY = "cx_notification_report_sync_v1";

  var ROUTES = {
    "nav-beranda": "beranda.html",
    "nav-keamanan": "keamanan.html",
    "nav-sigap": "sigap.html",
    "nav-komunitas": "komunitas.html",
    "nav-lapor": "lapor.html",
    "nav-kebersihan": "kebersihan.html",
    "nav-fasilitas": "fasilitas.html",
    "nav-notifikasi": "notifikasi.html",
    "nav-profil": "profil.html",
    btnAvatar: "profil.html",
    cardProfil: "profil.html",
    menuSigap: "sigap.html",
    menuKeamanan: "keamanan.html",
    menuKebersihan: "kebersihan.html",
    menuFasilitas: "fasilitas.html",
  };

  function minutesAgo(minutes) {
    return new Date(Date.now() - minutes * 60000).toISOString();
  }

  function hoursAgo(hours) {
    return new Date(Date.now() - hours * 3600000).toISOString();
  }

  function daysAgo(days) {
    return new Date(Date.now() - days * 86400000).toISOString();
  }

  var DEFAULT_NOTIFICATIONS = [
    {
      id: "seed-announcement-1",
      category: "Pengumuman",
      title: "Pengumuman komplek",
      description: "Kerja bakti warga hari Sabtu pukul 06.30.",
      createdAt: minutesAgo(10),
      read: false,
      link: "beranda.html",
    },
    {
      id: "seed-announcement-2",
      category: "Pengumuman",
      title: "Pengumuman pengurus",
      description: "Jadwal pengajian bulan ini sudah tersedia.",
      createdAt: hoursAgo(2),
      read: false,
      link: "beranda.html",
    },
    {
      id: "seed-announcement-3",
      category: "Pengumuman",
      title: "Pengumuman komplek",
      description: "Pembayaran iuran paling lambat tanggal 10.",
      createdAt: daysAgo(1),
      read: true,
      link: "beranda.html",
    },
    {
      id: "seed-announcement-4",
      category: "Pengumuman",
      title: "Pengumuman keamanan",
      description: "Jam patroli malam diperpanjang.",
      createdAt: daysAgo(19),
      read: true,
      link: "keamanan.html",
    },
    {
      id: "seed-announcement-5",
      category: "Pengumuman",
      title: "Jadwal kebersihan",
      description:
        "Jadwal kebersihan untuk area Jati 1 sampai Jati 7 telah diperbarui.",
      createdAt: daysAgo(3),
      read: true,
      link: "kebersihan.html",
    },
    {
      id: "seed-community-1",
      category: "Komunitas",
      title: "Kegiatan gotong royong",
      description:
        "Informasi kegiatan gotong royong minggu ini tersedia di Komunitas.",
      createdAt: hoursAgo(5),
      read: true,
      link: "komunitas.html",
    },
    {
      id: "seed-community-2",
      category: "Komunitas",
      title: "Aktivitas ruang warga",
      description:
        "Lihat kabar dan percakapan terbaru dari warga di halaman Komunitas.",
      createdAt: daysAgo(2),
      read: true,
      link: "komunitas.html",
    },
    {
      id: "seed-system-1",
      category: "Sistem",
      title: "Pembaruan layanan COMPLEX",
      description: "Fitur dashboard warga dapat diakses melalui menu navigasi.",
      createdAt: daysAgo(2),
      read: true,
      link: "beranda.html",
    },
    {
      id: "seed-system-2",
      category: "Sistem",
      title: "Informasi keamanan akun",
      description: "Pastikan informasi profil dan kontak Anda tetap sesuai.",
      createdAt: daysAgo(7),
      read: true,
      link: "profil.html",
    },
  ];

  var memoryItems = null;
  var CATEGORIES = ["Pengumuman", "Komunitas", "Sistem"];

  function safeGet(key) {
    try {
      return window.localStorage.getItem(key);
    } catch (error) {
      return null;
    }
  }

  function safeSet(key, value) {
    try {
      window.localStorage.setItem(key, value);
      return true;
    } catch (error) {
      return false;
    }
  }

  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function normalizeNotification(item) {
    if (!item || typeof item !== "object" || !item.title) return null;
    return {
      id: String(item.id || "cxn-" + Date.now().toString(36)),
      category:
        CATEGORIES.indexOf(item.category) !== -1 ? item.category : "Sistem",
      title: String(item.title),
      description: String(item.description || ""),
      createdAt: item.createdAt || new Date().toISOString(),
      read: item.read === true,
      link: typeof item.link === "string" ? item.link : "",
      sourceKey: typeof item.sourceKey === "string" ? item.sourceKey : "",
    };
  }

  function loadNotifications() {
    var raw = safeGet(NOTIFICATION_KEY);
    if (raw !== null) {
      try {
        var parsed = JSON.parse(raw);
        if (Array.isArray(parsed)) {
          memoryItems = parsed.map(normalizeNotification).filter(Boolean);
          return memoryItems;
        }
      } catch (error) {
        // Data rusak tidak akan menghentikan halaman; gunakan data awal.
      }
    }

    if (memoryItems) return memoryItems;
    memoryItems = clone(DEFAULT_NOTIFICATIONS);
    safeSet(NOTIFICATION_KEY, JSON.stringify(memoryItems));
    return memoryItems;
  }

  function saveNotifications(items) {
    memoryItems = items;
    safeSet(NOTIFICATION_KEY, JSON.stringify(items));
  }

  function sortedNotifications() {
    return loadNotifications()
      .slice()
      .sort(function (a, b) {
        return (
          new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()
        );
      });
  }

  function unreadCount() {
    return loadNotifications().filter(function (item) {
      return !item.read;
    }).length;
  }

  function updateNotificationBadge() {
    var button = document.getElementById("btnNotif");
    if (!button) return;

    var count = unreadCount();
    var dot = button.querySelector(".notif-dot");
    if (!dot) {
      dot = document.createElement("span");
      dot.className = "notif-dot";
      button.insertBefore(dot, button.firstChild);
    }

    button.style.position = button.style.position || "relative";
    dot.style.position = "absolute";
    dot.style.top = "6px";
    dot.style.right = "6px";
    dot.style.width = "8px";
    dot.style.height = "8px";
    dot.style.borderRadius = "50%";
    dot.style.background = "#dc2626";
    dot.style.border = "2px solid #fff";
    dot.style.pointerEvents = "none";
    dot.style.display = count > 0 ? "block" : "none";
    button.setAttribute(
      "aria-label",
      count > 0 ? "Notifikasi, " + count + " belum dibaca" : "Notifikasi",
    );
    button.title =
      count > 0 ? count + " notifikasi belum dibaca" : "Notifikasi";
  }

  function notifyChanged() {
    updateNotificationBadge();
    try {
      window.dispatchEvent(new CustomEvent("cx:notifications-changed"));
    } catch (error) {
      // CustomEvent tidak tersedia pada browser lama; UI tetap dapat dimuat.
    }
  }

  function addNotification(input) {
    if (!input || !String(input.title || "").trim()) return null;

    var items = loadNotifications();
    var sourceKey = String(input.sourceKey || "");
    if (sourceKey) {
      var existing = items.find(function (item) {
        return item.sourceKey === sourceKey;
      });
      if (existing) return existing;
    }

    var item = normalizeNotification({
      id:
        input.id ||
        "cxn-" +
          Date.now().toString(36) +
          "-" +
          Math.random().toString(36).slice(2, 7),
      category: input.category,
      title: String(input.title).trim(),
      description: String(input.description || "").trim(),
      createdAt: input.createdAt || new Date().toISOString(),
      read: false,
      link: input.link || "",
      sourceKey: sourceKey,
    });

    items.unshift(item);
    saveNotifications(items);
    notifyChanged();
    return item;
  }

  function markRead(id) {
    var items = loadNotifications();
    var changed = false;
    items.forEach(function (item) {
      if (item.id === id && !item.read) {
        item.read = true;
        changed = true;
      }
    });
    if (changed) {
      saveNotifications(items);
      notifyChanged();
    }
  }

  function markAllRead() {
    var items = loadNotifications();
    var changed = false;
    items.forEach(function (item) {
      if (!item.read) {
        item.read = true;
        changed = true;
      }
    });
    if (changed) {
      saveNotifications(items);
      notifyChanged();
    }
  }

  window.ComplexNotifications = {
    getAll: sortedNotifications,
    getUnreadCount: unreadCount,
    add: addNotification,
    markRead: markRead,
    markAllRead: markAllRead,
  };

  function currentFileName() {
    var parts = window.location.pathname.split("/");
    return decodeURIComponent(
      parts[parts.length - 1] || "beranda.html",
    ).toLowerCase();
  }

  function syncLinksAndActiveState() {
    var current = currentFileName();

    Object.keys(ROUTES).forEach(function (id) {
      var element = document.getElementById(id);
      if (!element || id === "btnNotif") return;

      var destination = ROUTES[id];
      if (element.tagName === "A") {
        element.setAttribute("href", destination);
        element.removeAttribute("onclick");
      }

      if (id.indexOf("nav-") === 0) {
        var isCurrentPage = destination.toLowerCase() === current;
        element.classList.toggle("active", isCurrentPage);
        if (isCurrentPage) {
          element.setAttribute("aria-current", "page");
        } else {
          element.removeAttribute("aria-current");
        }
      }
    });

    updateNotificationBadge();
  }

  function readJson(key, fallback) {
    var raw = safeGet(key);
    if (!raw) return fallback;
    try {
      return JSON.parse(raw);
    } catch (error) {
      return fallback;
    }
  }

  // Menangkap laporan baru/perubahan status dari modul yang sudah ada.
  // Data contoh awal hanya ditandai pernah terlihat, bukan dianggap laporan baru.
  function syncReportNotifications() {
    var state = readJson(REPORT_SYNC_KEY, {});
    var initialized = state.__initialized === true;
    var sources = [
      {
        key: "cx_lapor_reports_v1",
        label: "Laporan baru dibuat",
        link: "lapor.html",
      },
      {
        key: "cx_kebersihan_reports_v1",
        label: "Laporan kebersihan terkirim",
        link: "kebersihan.html",
      },
      {
        key: "cx_security_reports_v1",
        label: "Laporan keamanan baru",
        link: "keamanan.html",
      },
    ];

    sources.forEach(function (source) {
      var records = readJson(source.key, []);
      if (!Array.isArray(records)) return;

      records.forEach(function (record) {
        if (!record || !record.id) return;
        var recordId = String(record.id);
        var recordKey = source.key + "::" + recordId;
        var status = String(record.status || "");

        if (!initialized) {
          state[recordKey] = { status: status };
          return;
        }

        if (!state[recordKey]) {
          state[recordKey] = { status: status };
          if (!/^seed-|^wireframe-/.test(recordId)) {
            addNotification({
              category: "Sistem",
              title: source.label,
              description:
                String(record.title || "Laporan warga") +
                " telah tercatat dan dapat dipantau.",
              link: source.link,
              sourceKey: "feature:" + recordKey,
            });
          }
        } else if (status && state[recordKey].status !== status) {
          state[recordKey] = { status: status };
          addNotification({
            category: "Sistem",
            title: "Status laporan diperbarui",
            description:
              String(record.title || "Laporan warga") +
              " sekarang berstatus " +
              status +
              ".",
            link: source.link,
            sourceKey: "status:" + recordKey + ":" + status,
          });
        }
      });
    });

    state.__initialized = true;
    safeSet(REPORT_SYNC_KEY, JSON.stringify(state));
  }

  // Posting komunitas: buat notifikasi hanya jika form berhasil dikosongkan
  // atau jumlah postingan berubah setelah handler komunitas selesai bekerja.
  document.addEventListener(
    "submit",
    function (event) {
      var form = event.target;
      if (!form || form.id !== "postComposer") return;

      var input = form.querySelector("#postText");
      var content = input ? input.value.trim() : "";
      if (!content) return;

      var countNode = document.getElementById("feedCount");
      var beforeCount = countNode ? countNode.textContent : "";

      window.setTimeout(function () {
        var afterCount = countNode ? countNode.textContent : "";
        var cleared = input && !input.value.trim();
        var countChanged = afterCount && afterCount !== beforeCount;
        if (!cleared && !countChanged) return;

        addNotification({
          category: "Komunitas",
          title: "Postingan baru di komunitas",
          description:
            content.length > 150 ? content.slice(0, 147) + "..." : content,
          link: "komunitas.html",
          sourceKey:
            "community-post:" + Date.now() + ":" + content.slice(0, 24),
        });
      }, 500);
    },
    true,
  );

  // Tangkap klik ikon lonceng sebelum onclick placeholder lama dijalankan.
  document.addEventListener(
    "click",
    function (event) {
      var origin = event.target;
      var notificationButton =
        origin && origin.closest ? origin.closest("#btnNotif") : null;

      if (notificationButton) {
        if (
          event.button !== 0 ||
          event.metaKey ||
          event.ctrlKey ||
          event.shiftKey ||
          event.altKey
        )
          return;
        event.preventDefault();
        event.stopImmediatePropagation();
        window.location.assign("notifikasi.html");
        return;
      }

      var link = origin && origin.closest ? origin.closest("a[id]") : null;
      if (!link || !Object.prototype.hasOwnProperty.call(ROUTES, link.id))
        return;
      if (
        event.button !== 0 ||
        event.metaKey ||
        event.ctrlKey ||
        event.shiftKey ||
        event.altKey
      )
        return;

      event.preventDefault();
      event.stopImmediatePropagation();
      window.location.assign(ROUTES[link.id]);
    },
    true,
  );

  window.addEventListener("cx:notifications-changed", updateNotificationBadge);
  window.addEventListener("storage", function (event) {
    if (
      event.key === NOTIFICATION_KEY ||
      event.key === "cx_lapor_reports_v1" ||
      event.key === "cx_kebersihan_reports_v1" ||
      event.key === "cx_security_reports_v1"
    ) {
      syncReportNotifications();
      updateNotificationBadge();
    }
  });

  if (document.readyState === "loading") {
    document.addEventListener(
      "DOMContentLoaded",
      function () {
        syncLinksAndActiveState();
        syncReportNotifications();
      },
      { once: true },
    );
  } else {
    syncLinksAndActiveState();
    syncReportNotifications();
  }

  window.addEventListener("pageshow", function () {
    syncLinksAndActiveState();
    syncReportNotifications();
  });

  function selectRequestedNotificationCategory() {
    var current = currentFileName();
    if (current !== "notifikasi.html") return;
    var category = "";
    try {
      category =
        new URLSearchParams(window.location.search).get("kategori") || "";
    } catch (error) {
      category = "";
    }
    if (!category) return;
    var tab = Array.prototype.find.call(
      document.querySelectorAll(".notification-tab"),
      function (candidate) {
        return candidate.getAttribute("data-category") === category;
      },
    );
    if (tab) tab.click();
  }

  window.addEventListener("load", selectRequestedNotificationCategory);
  window.addEventListener("pageshow", function () {
    window.setTimeout(selectRequestedNotificationCategory, 0);
  });
})();
