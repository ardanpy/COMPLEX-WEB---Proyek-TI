/* COMPLEX — Interaksi halaman Notifikasi */
(function () {
  "use strict";

  var list = document.getElementById("notificationList");
  var tabs = Array.prototype.slice.call(
    document.querySelectorAll(".notification-tab"),
  );
  var markAllButton = document.getElementById("btnMarkAllRead");
  var activeCategory = "Pengumuman";
  var toastTimer = null;

  if (!list || !window.ComplexNotifications) return;

  function formatTime(value) {
    var date = new Date(value);
    if (Number.isNaN(date.getTime())) return "Baru saja";

    var difference = Math.max(0, Date.now() - date.getTime());
    var minutes = Math.floor(difference / 60000);
    var hours = Math.floor(difference / 3600000);
    var days = Math.floor(difference / 86400000);

    if (minutes < 1) return "Baru saja";
    if (minutes < 60) return minutes + " menit lalu";
    if (hours < 24) return hours + " jam lalu";
    if (days < 2) return "Kemarin";

    return new Intl.DateTimeFormat("id-ID", {
      day: "2-digit",
      month: "short",
    }).format(date);
  }

  function showToast(message) {
    var toast = document.getElementById("notificationToast");
    if (!toast) return;
    toast.textContent = message;
    toast.classList.add("is-visible");
    if (toastTimer) window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      toast.classList.remove("is-visible");
    }, 2200);
  }

  function createElement(tag, className, text) {
    var element = document.createElement(tag);
    if (className) element.className = className;
    if (text !== undefined) element.textContent = text;
    return element;
  }

  function setActiveTab(category) {
    activeCategory = category;
    tabs.forEach(function (tab) {
      var active = tab.getAttribute("data-category") === category;
      tab.classList.toggle("is-active", active);
      tab.setAttribute("aria-selected", active ? "true" : "false");
      tab.tabIndex = active ? 0 : -1;
    });
    render();
  }

  function render() {
    var all = window.ComplexNotifications.getAll();
    var filtered = all.filter(function (item) {
      return item.category === activeCategory;
    });

    list.textContent = "";

    if (!filtered.length) {
      var empty = createElement("div", "notification-empty");
      empty.appendChild(createElement("strong", "", "Belum ada notifikasi"));
      empty.appendChild(
        createElement(
          "span",
          "",
          "Belum ada pemberitahuan pada kategori " + activeCategory + ".",
        ),
      );
      list.appendChild(empty);
    } else {
      filtered.forEach(function (item) {
        var button = createElement(
          "button",
          "notification-item" + (item.read ? "" : " is-unread"),
        );
        button.type = "button";
        button.setAttribute("data-notification-id", item.id);
        button.setAttribute(
          "aria-label",
          item.title +
            ". " +
            item.description +
            ". " +
            formatTime(item.createdAt) +
            (item.read ? "" : ". Belum dibaca"),
        );

        var avatar = createElement("span", "notification-avatar");
        avatar.setAttribute("aria-hidden", "true");

        var copy = createElement("span", "notification-copy");
        copy.appendChild(
          createElement("strong", "notification-title", item.title),
        );
        copy.appendChild(
          createElement("span", "notification-description", item.description),
        );

        var time = createElement(
          "span",
          "notification-time",
          formatTime(item.createdAt),
        );
        time.setAttribute("aria-label", "Waktu notifikasi");

        var dot = createElement(
          "span",
          "notification-unread-dot" + (item.read ? " is-hidden" : ""),
        );
        dot.setAttribute("aria-hidden", "true");

        button.appendChild(avatar);
        button.appendChild(copy);
        button.appendChild(time);
        button.appendChild(dot);

        button.addEventListener("click", function () {
          window.ComplexNotifications.markRead(item.id);
          if (item.link) {
            window.location.assign(item.link);
          } else {
            showToast("Notifikasi ditandai sudah dibaca.");
            render();
          }
        });

        list.appendChild(button);
      });
    }

    if (markAllButton) {
      markAllButton.disabled =
        window.ComplexNotifications.getUnreadCount() === 0;
    }
  }

  tabs.forEach(function (tab) {
    tab.addEventListener("click", function () {
      setActiveTab(tab.getAttribute("data-category") || "Pengumuman");
    });
  });

  if (markAllButton) {
    markAllButton.addEventListener("click", function () {
      window.ComplexNotifications.markAllRead();
      showToast("Semua notifikasi sudah ditandai dibaca.");
      render();
    });
  }

  window.addEventListener("cx:notifications-changed", render);
  window.addEventListener("storage", function (event) {
    if (event.key === "cx_notifications_v1") render();
  });

  setActiveTab(activeCategory);
})();
