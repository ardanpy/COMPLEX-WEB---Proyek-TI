import { auth, db, firebaseConfigured } from "./firebase.js";
import {
  createUserWithEmailAndPassword,
  updateProfile,
  signOut,
  onAuthStateChanged,
} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js";
import {
  doc,
  setDoc,
  serverTimestamp,
} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js";

const form = document.getElementById("registerForm");
const submitButton = document.getElementById("btnDaftar");
const toast = document.getElementById("toastNotif");

function notify(message, type = "info") {
  if (typeof window.showToast === "function") {
    window.showToast(message, type);
    return;
  }
  if (toast) {
    toast.textContent = message;
    toast.dataset.type = type;
    toast.classList.add("is-visible");
    window.clearTimeout(notify._timer);
    notify._timer = window.setTimeout(
      () => toast.classList.remove("is-visible"),
      4500,
    );
  } else {
    window.alert(message);
  }
}

function setBusy(button, busy, busyText = "Menyimpan...") {
  if (!button) return;
  if (busy) {
    button.dataset.originalText = button.textContent.trim();
    button.textContent = busyText;
    button.disabled = true;
    button.setAttribute("aria-busy", "true");
  } else {
    button.textContent = button.dataset.originalText || button.textContent;
    button.disabled = false;
    button.removeAttribute("aria-busy");
  }
}

function fieldError(groupId, errorId, message) {
  const group = document.getElementById(groupId);
  const error = document.getElementById(errorId);
  if (typeof window.showFieldError === "function") {
    window.showFieldError(groupId, error, message);
  } else {
    if (group) group.classList.add("has-error");
    if (error) error.textContent = message;
  }
}

function clearError(groupId, errorId) {
  const group = document.getElementById(groupId);
  const error = document.getElementById(errorId);
  if (typeof window.clearFieldError === "function") {
    window.clearFieldError(groupId, error);
  } else {
    if (group) group.classList.remove("has-error");
    if (error) error.textContent = "";
  }
}

function saveResidentProfile(profile) {
  try {
    localStorage.setItem("cx_profile", JSON.stringify(profile));
    sessionStorage.setItem("cx_active_profile", JSON.stringify(profile));
    const legacyKeys = {
      cx_nama: profile.nama,
      cx_telp: profile.telp,
      cx_email: profile.email,
      cx_blok: profile.blok,
      cx_noRumah: profile.noRumah,
    };
    Object.entries(legacyKeys).forEach(([key, value]) => {
      localStorage.setItem(key, value || "");
      sessionStorage.setItem(key, value || "");
    });
  } catch (error) {
    console.warn(
      "Profil warga tidak dapat disimpan ke penyimpanan browser:",
      error,
    );
  }
}

function validateForm(isGoogleRegistration) {
  let valid = true;
  const nama = document.getElementById("regNama").value.trim();
  const email = document.getElementById("regEmail").value.trim();
  const hp = document.getElementById("regHP").value.trim();
  const blok = document.getElementById("regBlok").value;
  const noRumah = document.getElementById("regNoRumah").value.trim();

  if (!nama) {
    fieldError("rg-fg-nama", "rg-err-nama", "Nama lengkap wajib diisi.");
    valid = false;
  } else clearError("rg-fg-nama", "rg-err-nama");

  if (!email) {
    fieldError("rg-fg-email", "rg-err-email", "Email wajib diisi.");
    valid = false;
  } else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    fieldError("rg-fg-email", "rg-err-email", "Format email tidak valid.");
    valid = false;
  } else clearError("rg-fg-email", "rg-err-email");

  if (!hp) {
    fieldError("rg-fg-hp", "rg-err-hp", "Nomor HP wajib diisi.");
    valid = false;
  } else if (!/^[0-9+\-\s]{7,15}$/.test(hp)) {
    fieldError("rg-fg-hp", "rg-err-hp", "Format nomor HP tidak valid.");
    valid = false;
  } else clearError("rg-fg-hp", "rg-err-hp");

  if (!blok) {
    fieldError("rg-fg-blok", "rg-err-blok", "Pilih blok tempat tinggal.");
    valid = false;
  } else clearError("rg-fg-blok", "rg-err-blok");

  if (!noRumah) {
    fieldError("rg-fg-norumah", "rg-err-norumah", "Nomor rumah wajib diisi.");
    valid = false;
  } else clearError("rg-fg-norumah", "rg-err-norumah");

  if (!isGoogleRegistration) {
    const password = document.getElementById("regPass").value;
    const confirm = document.getElementById("regKonfPass").value;

    if (password.length < 6) {
      fieldError("rg-fg-pass", "rg-err-pass", "Password minimal 6 karakter.");
      valid = false;
    } else clearError("rg-fg-pass", "rg-err-pass");

    if (!confirm) {
      fieldError(
        "rg-fg-konfpass",
        "rg-err-konfpass",
        "Konfirmasi password wajib diisi.",
      );
      valid = false;
    } else if (password !== confirm) {
      fieldError(
        "rg-fg-konfpass",
        "rg-err-konfpass",
        "Password dan konfirmasi tidak cocok.",
      );
      valid = false;
    } else clearError("rg-fg-konfpass", "rg-err-konfpass");
  }

  return valid;
}

function getCurrentUser() {
  return new Promise((resolve, reject) => {
    if (!auth) return resolve(null);
    let unsubscribe = () => {};
    unsubscribe = onAuthStateChanged(
      auth,
      (user) => {
        unsubscribe();
        resolve(user);
      },
      (error) => {
        unsubscribe();
        reject(error);
      },
    );
  });
}

if (!firebaseConfigured || !auth || !db) {
  notify(
    "Pendaftaran membutuhkan konfigurasi Firebase. Isi js/firebase-config.js terlebih dahulu.",
    "warning",
  );
}

let currentUser = null;
try {
  currentUser = await getCurrentUser();
} catch (error) {
  console.error("Status autentikasi tidak dapat dibaca:", error);
}

const googlePending =
  sessionStorage.getItem("cx_google_registration_pending") === "true" &&
  currentUser &&
  currentUser.providerData.some(
    (provider) => provider.providerId === "google.com",
  );

if (googlePending) {
  document.body.classList.add("google-registration");
  document.getElementById("googleRegisterNote")?.removeAttribute("hidden");

  const nameInput = document.getElementById("regNama");
  const emailInput = document.getElementById("regEmail");
  if (nameInput && !nameInput.value)
    nameInput.value = currentUser.displayName || "";
  if (emailInput) {
    emailInput.value = currentUser.email || "";
    emailInput.readOnly = true;
  }

  document.getElementById("rg-fg-pass")?.setAttribute("hidden", "");
  document.getElementById("rg-fg-konfpass")?.setAttribute("hidden", "");
} else if (
  sessionStorage.getItem("cx_google_registration_pending") === "true" &&
  !currentUser
) {
  sessionStorage.removeItem("cx_google_registration_pending");
  notify(
    "Sesi Google berakhir. Silakan ulangi masuk dengan Google dari halaman Login.",
    "warning",
  );
}

// Toggle visibility for password fields on normal registration.
document.getElementById("toggleRegPass")?.addEventListener("click", () => {
  const field = document.getElementById("regPass");
  if (field) field.type = field.type === "password" ? "text" : "password";
});
document.getElementById("toggleRegKonfPass")?.addEventListener("click", () => {
  const field = document.getElementById("regKonfPass");
  if (field) field.type = field.type === "password" ? "text" : "password";
});

form?.addEventListener("submit", async (event) => {
  event.preventDefault();

  if (!firebaseConfigured || !auth || !db) {
    notify(
      "Autentikasi belum aktif. Lengkapi konfigurasi Firebase terlebih dahulu.",
      "warning",
    );
    return;
  }

  const isGoogleFlow = Boolean(googlePending && currentUser);
  if (!validateForm(isGoogleFlow)) return;

  const profile = {
    nama: document.getElementById("regNama").value.trim(),
    email: document.getElementById("regEmail").value.trim(),
    telp: document.getElementById("regHP").value.trim(),
    blok: document.getElementById("regBlok").value,
    noRumah: document.getElementById("regNoRumah").value.trim(),
    registered: true,
  };

  setBusy(
    submitButton,
    true,
    isGoogleFlow ? "Menyelesaikan..." : "Mendaftarkan...",
  );

  try {
    let user = currentUser;

    if (isGoogleFlow) {
      await updateProfile(user, { displayName: profile.nama });
    } else {
      const password = document.getElementById("regPass").value;
      const credential = await createUserWithEmailAndPassword(
        auth,
        profile.email,
        password,
      );
      user = credential.user;
      profile.email = user.email || profile.email;
      await updateProfile(user, { displayName: profile.nama });
    }

    if (isGoogleFlow) profile.email = user.email || profile.email;

    await setDoc(
      doc(db, "residents", user.uid),
      {
        ...profile,
        uid: user.uid,
        authProvider: isGoogleFlow ? "google" : "password",
        updatedAt: serverTimestamp(),
        ...(isGoogleFlow ? {} : { createdAt: serverTimestamp() }),
      },
      { merge: true },
    );

    saveResidentProfile(profile);

    if (isGoogleFlow) {
      sessionStorage.removeItem("cx_google_registration_pending");
      sessionStorage.removeItem("cx_google_pending_email");
      sessionStorage.removeItem("cx_google_pending_name");
      sessionStorage.setItem("cx_login_completed", "true");
      sessionStorage.setItem("cx_fromSigap", "false");
      window.location.replace("beranda.html");
    } else {
      await signOut(auth);
      sessionStorage.setItem("cx_pending_profile", JSON.stringify(profile));
      window.location.replace("index.html?registered=1");
    }
  } catch (error) {
    const messages = {
      "auth/email-already-in-use":
        "Email ini sudah memiliki akun. Silakan login atau gunakan fitur reset password.",
      "auth/invalid-email": "Format email tidak valid.",
      "auth/weak-password":
        "Password terlalu lemah. Gunakan minimal 6 karakter.",
      "permission-denied":
        "Akun berhasil dibuat, tetapi penyimpanan profil ditolak. Periksa Firestore Rules.",
      unavailable: "Layanan database sedang tidak tersedia. Coba kembali.",
    };
    notify(
      messages[error.code] ||
        "Pendaftaran belum berhasil. Periksa data dan konfigurasi Firebase Anda.",
      "error",
    );
    console.error("Pendaftaran COMPLEX gagal:", error);
  } finally {
    setBusy(submitButton, false);
  }
});
