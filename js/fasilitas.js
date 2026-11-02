/* COMPLEX — Fasilitas
   Pengajuan disimpan lokal dan dikirim ke pusat notifikasi yang sudah ada. */
(function () {
  "use strict";

  var REQUEST_KEY = "cx_facility_requests_v1";
  var serviceConfig = {
    ambulans: {
      title: "Peminjaman Ambulans",
      notificationTitle: "Pengajuan ambulans baru",
      description: "Lengkapi data kebutuhan ambulans.",
    },
    lapangan: {
      title: "Peminjaman Lapangan",
      notificationTitle: "Pengajuan peminjaman lapangan baru",
      description: "Lengkapi jadwal dan tujuan penggunaan lapangan.",
    },
    mushola: {
      title: "Peminjaman Mushola",
      notificationTitle: "Pengajuan peminjaman mushola baru",
      description: "Lengkapi jadwal dan tujuan penggunaan mushola.",
    },
  };

  var modal = document.getElementById("facilityRequestModal");
  var successModal = document.getElementById("facilitySuccessModal");
  var form = document.getElementById("facilityRequestForm");
  var fields = document.getElementById("facilityFormFields");
  var serviceInput = document.getElementById("facilityServiceType");
  var requestList = document.getElementById("facilityRequestList");
  var toast = document.getElementById("facilityToast");
  var lastTrigger = null;
  var toastTimer = null;

  function safeRead(key, fallback) {
    try {
      var raw = window.localStorage.getItem(key);
      if (!raw) return fallback;
      var value = JSON.parse(raw);
      return value;
    } catch (error) {
      return fallback;
    }
  }

  function safeWrite(key, value) {
    try {
      window.localStorage.setItem(key, JSON.stringify(value));
      return true;
    } catch (error) {
      return false;
    }
  }

  function localDateString() {
    var date = new Date();
    return (
      date.getFullYear() +
      "-" +
      String(date.getMonth() + 1).padStart(2, "0") +
      "-" +
      String(date.getDate()).padStart(2, "0")
    );
  }

  function escapeText(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  function inputField(label, name, type, options) {
    options = options || {};
    var full = options.full ? " full" : "";
    var required = options.required === false ? "" : " required";
    var placeholder = options.placeholder
      ? ' placeholder="' + escapeText(options.placeholder) + '"'
      : "";
    var min = options.min ? ' min="' + escapeText(options.min) + '"' : "";
    var max = options.max ? ' max="' + escapeText(options.max) + '"' : "";
    var id = "facility-field-" + name;

    if (type === "textarea") {
      return (
        '<div class="facility-form-field' +
        full +
        '">' +
        '<label for="' +
        id +
        '">' +
        label +
        "</label>" +
        '<textarea id="' +
        id +
        '" name="' +
        name +
        '"' +
        required +
        placeholder +
        "></textarea>" +
        "</div>"
      );
    }

    if (type === "select") {
      var optionsHtml = (options.choices || [])
        .map(function (choice) {
          return (
            '<option value="' +
            escapeText(choice.value) +
            '">' +
            escapeText(choice.label) +
            "</option>"
          );
        })
        .join("");
      return (
        '<div class="facility-form-field' +
        full +
        '">' +
        '<label for="' +
        id +
        '">' +
        label +
        "</label>" +
        '<select id="' +
        id +
        '" name="' +
        name +
        '"' +
        required +
        ">" +
        '<option value="">Pilih ' +
        label.toLowerCase() +
        "</option>" +
        optionsHtml +
        "</select></div>"
      );
    }

    return (
      '<div class="facility-form-field' +
      full +
      '">' +
      '<label for="' +
      id +
      '">' +
      label +
      "</label>" +
      '<input id="' +
      id +
      '" name="' +
      name +
      '" type="' +
      type +
      '"' +
      required +
      placeholder +
      min +
      max +
      " />" +
      "</div>"
    );
  }

  function commonFields(type) {
    var dateLabel =
      type === "ambulans" ? "Tanggal kebutuhan" : "Tanggal penggunaan";
    var timeLabel = type === "ambulans" ? "Waktu penjemputan" : "Jam mulai";
    var html =
      '<div class="facility-form-grid">' +
      '<p class="facility-form-section-title">Data pemohon</p>' +
      inputField("Nama lengkap", "nama", "text", {
        placeholder: "Nama sesuai data warga",
      }) +
      inputField("Nomor HP aktif", "telepon", "tel", {
        placeholder: "Contoh: 08xxxxxxxxxx",
      }) +
      inputField("Blok dan nomor rumah", "alamat", "text", {
        full: true,
        placeholder: "Contoh: Jati 2 No. 15",
      }) +
      '<p class="facility-form-section-title">Jadwal</p>' +
      inputField(dateLabel, "tanggal", "date", { min: localDateString() }) +
      inputField(timeLabel, "jamMulai", "time");

    if (type !== "ambulans") {
      html += inputField("Jam selesai", "jamSelesai", "time");
    }
    return html + "</div>";
  }

  function serviceFields(type) {
    var detail = "";
    if (type === "ambulans") {
      detail =
        '<div class="facility-form-grid">' +
        '<p class="facility-form-section-title">Rincian kebutuhan ambulans</p>' +
        inputField("Lokasi penjemputan", "penjemputan", "text", {
          full: true,
          placeholder: "Alamat rumah atau titik penjemputan",
        }) +
        inputField("Tujuan", "tujuan", "text", {
          full: true,
          placeholder: "Rumah sakit atau alamat tujuan",
        }) +
        inputField("Jenis kebutuhan", "keperluan", "select", {
          choices: [
            { value: "Antar pasien", label: "Antar pasien" },
            { value: "Jemput pasien", label: "Jemput pasien" },
            { value: "Kontrol / pemeriksaan", label: "Kontrol / pemeriksaan" },
            { value: "Lainnya", label: "Lainnya" },
          ],
        }) +
        inputField("Jumlah pasien", "jumlahPasien", "number", {
          min: "1",
          max: "5",
          placeholder: "1",
        }) +
        inputField("Catatan tambahan", "catatan", "textarea", {
          full: true,
          required: false,
          placeholder: "Informasi yang perlu diketahui petugas.",
        }) +
        "</div>";
    } else if (type === "lapangan") {
      detail =
        '<div class="facility-form-grid">' +
        '<p class="facility-form-section-title">Rincian penggunaan lapangan</p>' +
        inputField("Jenis kegiatan", "keperluan", "select", {
          choices: [
            { value: "Olahraga warga", label: "Olahraga warga" },
            { value: "Latihan rutin", label: "Latihan rutin" },
            { value: "Kegiatan komunitas", label: "Kegiatan komunitas" },
            { value: "Acara warga", label: "Acara warga" },
            { value: "Lainnya", label: "Lainnya" },
          ],
        }) +
        inputField("Jumlah peserta", "jumlahPeserta", "number", {
          min: "1",
          max: "300",
          placeholder: "Perkiraan peserta",
        }) +
        inputField("Catatan tambahan", "catatan", "textarea", {
          full: true,
          required: false,
          placeholder: "Perlengkapan atau kebutuhan lain.",
        }) +
        "</div>";
    } else {
      detail =
        '<div class="facility-form-grid">' +
        '<p class="facility-form-section-title">Rincian penggunaan mushola</p>' +
        inputField("Jenis kegiatan", "keperluan", "select", {
          choices: [
            { value: "Kajian / pengajian", label: "Kajian / pengajian" },
            {
              value: "Kegiatan keagamaan warga",
              label: "Kegiatan keagamaan warga",
            },
            { value: "Kegiatan sosial warga", label: "Kegiatan sosial warga" },
            { value: "Lainnya", label: "Lainnya" },
          ],
        }) +
        inputField("Jumlah peserta", "jumlahPeserta", "number", {
          min: "1",
          max: "200",
          placeholder: "Perkiraan peserta",
        }) +
        inputField("Catatan tambahan", "catatan", "textarea", {
          full: true,
          required: false,
          placeholder: "Perlengkapan atau penataan yang diperlukan.",
        }) +
        "</div>";
    }

    return commonFields(type) + detail;
  }

  function openModal(type, trigger) {
    if (!serviceConfig[type]) return;
    lastTrigger = trigger || document.activeElement;
    serviceInput.value = type;
    document.getElementById("facilityModalTitle").textContent =
      serviceConfig[type].title;
    document.getElementById("facilityModalDescription").textContent =
      serviceConfig[type].description;
    fields.innerHTML = serviceFields(type);
    form.reset();
    serviceInput.value = type;
    modal.hidden = false;
    document.body.classList.add("facility-modal-open");
    var first = fields.querySelector("input, select, textarea");
    if (first) first.focus();
  }

  function closeModal() {
    modal.hidden = true;
    document.body.classList.remove("facility-modal-open");
    if (lastTrigger && typeof lastTrigger.focus === "function")
      lastTrigger.focus();
  }

  function closeSuccess() {
    successModal.hidden = true;
    document.body.classList.remove("facility-modal-open");
  }

  function formatDate(value) {
    if (!value) return "Tanggal belum dipilih";
    var parts = value.split("-");
    if (parts.length !== 3) return value;
    return new Intl.DateTimeFormat("id-ID", {
      day: "2-digit",
      month: "short",
      year: "numeric",
    }).format(
      new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2])),
    );
  }

  function showToast(message) {
    toast.textContent = message;
    toast.classList.add("is-visible");
    if (toastTimer) window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      toast.classList.remove("is-visible");
    }, 2800);
  }

  function renderRequests() {
    var requests = safeRead(REQUEST_KEY, []);
    if (!Array.isArray(requests) || !requests.length) {
      requestList.innerHTML =
        '<div class="facility-empty-state">' +
        '<span class="facility-empty-state-icon" aria-hidden="true">▤</span>' +
        "<strong>Belum ada pengajuan</strong>" +
        "<span>Pengajuan ambulans, lapangan, dan mushola akan tercatat di sini setelah formulir dikirim.</span>" +
        "</div>";
      return;
    }

    requestList.textContent = "";
    requests.slice(0, 8).forEach(function (item) {
      var row = document.createElement("article");
      row.className = "facility-request-item";

      var main = document.createElement("div");
      main.className = "facility-request-main";

      var title = document.createElement("strong");
      title.textContent = item.title || "Pengajuan fasilitas";

      var detail = document.createElement("span");
      detail.textContent =
        formatDate(item.date) +
        " · " +
        (item.startTime || "Waktu belum dipilih") +
        " · " +
        (item.applicant || "Warga");

      main.appendChild(title);
      main.appendChild(detail);

      var status = document.createElement("span");
      status.className = "facility-request-status";
      status.textContent = item.status || "Menunggu konfirmasi";

      row.appendChild(main);
      row.appendChild(status);
      requestList.appendChild(row);
    });
  }

  function addNotification(request) {
    var config = serviceConfig[request.service];
    var title = config.notificationTitle;
    var description =
      request.applicant +
      " mengajukan " +
      config.title.toLowerCase() +
      " pada " +
      formatDate(request.date) +
      " pukul " +
      request.startTime +
      ". Status: menunggu konfirmasi pengurus.";

    if (
      window.ComplexNotifications &&
      typeof window.ComplexNotifications.add === "function"
    ) {
      window.ComplexNotifications.add({
        id: request.id,
        category: "Sistem",
        title: title,
        description: description,
        createdAt: request.createdAt,
        read: false,
        link: "notifikasi.html?kategori=Sistem",
        sourceKey: "facility-request:" + request.id,
      });
      return true;
    }

    // Fallback penyimpanan dengan skema yang dibaca oleh pusat notifikasi COMPLEX.
    var items = safeRead("cx_notifications_v1", []);
    if (!Array.isArray(items)) items = [];
    items.unshift({
      id: request.id,
      category: "Sistem",
      title: title,
      description: description,
      createdAt: request.createdAt,
      read: false,
      link: "notifikasi.html?kategori=Sistem",
      sourceKey: "facility-request:" + request.id,
    });
    return safeWrite("cx_notifications_v1", items.slice(0, 200));
  }

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    if (!form.reportValidity()) return;

    var type = serviceInput.value;
    var config = serviceConfig[type];
    if (!config) return;

    var formData = new FormData(form);
    var values = {};
    formData.forEach(function (value, key) {
      if (key !== "consent" && key !== "serviceType")
        values[key] = String(value).trim();
    });

    if (
      values.jamSelesai &&
      values.jamMulai &&
      values.jamSelesai <= values.jamMulai
    ) {
      showToast("Jam selesai harus lebih akhir daripada jam mulai.");
      var endField = form.querySelector('[name="jamSelesai"]');
      if (endField) endField.focus();
      return;
    }

    var now = new Date();
    var requestId = "FAC-" + now.getTime().toString(36).toUpperCase();
    var request = {
      id: requestId,
      service: type,
      title: config.title,
      applicant: values.nama,
      phone: values.telepon,
      address: values.alamat,
      date: values.tanggal,
      startTime: values.jamMulai,
      endTime: values.jamSelesai || "",
      details: values,
      status: "Menunggu konfirmasi",
      createdAt: now.toISOString(),
    };

    var requests = safeRead(REQUEST_KEY, []);
    if (!Array.isArray(requests)) requests = [];
    requests.unshift(request);

    if (!safeWrite(REQUEST_KEY, requests.slice(0, 100))) {
      showToast(
        "Penyimpanan browser tidak tersedia. Pengajuan belum dapat dicatat.",
      );
      return;
    }

    if (!addNotification(request)) {
      showToast(
        "Pengajuan tersimpan, tetapi notifikasi gagal ditulis. Periksa penyimpanan browser.",
      );
      return;
    }

    closeModal();
    renderRequests();
    document.getElementById("facilitySuccessText").textContent =
      config.title +
      " untuk " +
      formatDate(request.date) +
      " pukul " +
      request.startTime +
      " berhasil dicatat. Notifikasi sudah masuk ke tab Sistem.";
    successModal.hidden = false;
    document.body.classList.add("facility-modal-open");
  });

  document.addEventListener("click", function (event) {
    var opener = event.target.closest("[data-open-request]");
    if (opener) {
      openModal(opener.getAttribute("data-service"), opener);
      return;
    }
    if (event.target.closest("[data-close-request]")) closeModal();
    if (event.target.closest("[data-close-success]")) closeSuccess();
  });

  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      if (!modal.hidden) closeModal();
      if (!successModal.hidden) closeSuccess();
    }
  });

  var search = document.getElementById("searchInput");
  if (search) {
    search.addEventListener("input", function () {
      var query = search.value.trim().toLowerCase();
      document.querySelectorAll("[data-service-card]").forEach(function (card) {
        card.hidden =
          query && card.textContent.toLowerCase().indexOf(query) === -1;
      });
      var mapSection = document.querySelector(".facility-map-section");
      var historySection = document.querySelector(".facility-requests-section");
      if (mapSection)
        mapSection.hidden =
          !!query &&
          "peta google maps cluster jati taman royal 3".indexOf(query) === -1;
      if (historySection)
        historySection.hidden =
          !!query && "pengajuan saya riwayat layanan".indexOf(query) === -1;
    });
  }

  renderRequests();
})();
