/**
 * COMPLEX — Shared JavaScript Utilities
 * Berisi fungsi-fungsi yang digunakan di semua halaman.
 *
 * CATATAN PENTING:
 * File ini hanya berisi logika frontend (UI/UX).
 * Tidak ada autentikasi produksi atau koneksi database.
 * Fungsi-fungsi berikut adalah simulasi alur pengguna untuk
 * keperluan pengembangan dan pengujian tampilan.
 */

'use strict';

// =====================================================
// UTILITAS VALIDASI
// =====================================================

/**
 * Memeriksa apakah sebuah nilai dianggap "sengaja tidak diisi"
 * oleh pengguna — yaitu nilai kosong atau berisi tanda '-'.
 * @param {string} value
 * @returns {boolean}
 */
function isOptionalSkipped(value) {
  if (!value) return true;
  return value.trim() === '-';
}

/**
 * Validasi format email sederhana.
 * @param {string} email
 * @returns {boolean}
 */
function isValidEmail(email) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

// =====================================================
// UTILITAS FORM
// =====================================================

/**
 * Menampilkan pesan error pada sebuah field.
 * @param {string} fgId - ID elemen form-group
 * @param {HTMLElement} errorEl - Elemen span untuk error
 * @param {string} message - Pesan error
 */
function showFieldError(fgId, errorEl, message) {
  const fg = document.getElementById(fgId);
  if (fg) {
    const input = fg.querySelector('.form-input');
    if (input) input.classList.add('is-error');
  }
  if (errorEl) errorEl.textContent = message;
}

/**
 * Menghapus pesan error pada sebuah field.
 * @param {string} fgId
 * @param {HTMLElement} errorEl
 */
function clearFieldError(fgId, errorEl) {
  const fg = document.getElementById(fgId);
  if (fg) {
    const input = fg.querySelector('.form-input');
    if (input) input.classList.remove('is-error');
  }
  if (errorEl) errorEl.textContent = '';
}

/**
 * Toggle visibilitas password pada sebuah field.
 * @param {string} inputId - ID elemen input password
 * @param {string|null} iconId - ID elemen ikon (opsional)
 */
function togglePasswordField(inputId, iconId) {
  const input = document.getElementById(inputId);
  if (!input) return;

  const isPassword = input.type === 'password';
  input.type = isPassword ? 'text' : 'password';

  if (iconId) {
    const icon = document.getElementById(iconId);
    if (icon) {
      // Ganti ikon antara "eye" dan "eye-off"
      if (isPassword) {
        icon.innerHTML = `
          <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/>
          <path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/>
          <line x1="1" y1="1" x2="23" y2="23"/>
        `;
      } else {
        icon.innerHTML = `
          <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/>
          <circle cx="12" cy="12" r="3"/>
        `;
      }
    }
  } else {
    // Ganti ikon SVG di dalam tombol terdekat
    const btn = input.parentElement.querySelector('.toggle-password');
    if (btn) {
      const svg = btn.querySelector('svg');
      if (svg) {
        if (isPassword) {
          svg.innerHTML = `
            <path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/>
            <path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/>
            <line x1="1" y1="1" x2="23" y2="23"/>
          `;
        } else {
          svg.innerHTML = `
            <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/>
            <circle cx="12" cy="12" r="3"/>
          `;
        }
      }
    }
  }
}

// =====================================================
// NOTIFIKASI & MODAL
// =====================================================

let toastTimer = null;

/**
 * Menampilkan toast notification.
 * @param {string} message
 * @param {'info'|'warning'|'success'|'error'} type
 * @param {number} duration - Durasi tampil dalam ms
 */
function showToast(message, type = 'info', duration = 4000) {
  const toast = document.getElementById('toastNotif');
  if (!toast) return;

  // Hapus timer sebelumnya
  if (toastTimer) clearTimeout(toastTimer);

  toast.textContent = message;
  toast.className = 'toast-notif ' + type + ' show';

  toastTimer = setTimeout(() => {
    toast.classList.remove('show');
  }, duration);
}

/**
 * Menampilkan pesan "fitur belum tersedia" (coming soon).
 * @param {string} providerName
 */
function showComingSoon(providerName) {
  showToast(
    `Login dengan ${providerName} belum diaktifkan. Backend belum tersedia.`,
    'info',
    4000
  );
}

/**
 * Menampilkan modal placeholder untuk fitur yang belum dikembangkan.
 * @param {string} featureName - Nama fitur
 */
function showPlaceholder(featureName) {
  const modal = document.getElementById('placeholderModal');
  const title = document.getElementById('placeholderTitle');
  const desc = document.getElementById('placeholderDesc');

  if (!modal) return;

  if (title) title.textContent = featureName + ' — Segera Hadir';
  if (desc) desc.textContent = `Halaman ${featureName} akan dikembangkan pada tahap selanjutnya. Terima kasih atas kesabarannya.`;

  modal.style.display = 'flex';
  document.body.style.overflow = 'hidden';

  // Tutup saat klik overlay
  modal.addEventListener('click', function onOverlayClick(e) {
    if (e.target === modal) {
      closePlaceholderModal();
      modal.removeEventListener('click', onOverlayClick);
    }
  }, { once: false });
}

/**
 * Menutup modal placeholder.
 */
function closePlaceholderModal() {
  const modal = document.getElementById('placeholderModal');
  if (modal) modal.style.display = 'none';
  document.body.style.overflow = '';
}

// =====================================================
// KEYBOARD ACCESSIBILITY
// =====================================================

// Tutup modal dengan tombol Escape
document.addEventListener('keydown', function(e) {
  if (e.key === 'Escape') {
    closePlaceholderModal();
    // Tutup SIGAP confirm modal jika ada
    const sigapModal = document.getElementById('sigapConfirmModal');
    if (sigapModal && sigapModal.style.display !== 'none') {
      sigapModal.style.display = 'none';
      document.body.style.overflow = '';
    }
  }
});

// =====================================================
// SEARCH (DEMO)
// =====================================================

const searchInput = document.getElementById('searchInput');
if (searchInput) {
  searchInput.addEventListener('keydown', function(e) {
    if (e.key === 'Enter' && this.value.trim()) {
      showToast(`Pencarian "${this.value.trim()}" belum tersedia. Fitur pencarian akan dikembangkan.`, 'info');
    }
  });
}
