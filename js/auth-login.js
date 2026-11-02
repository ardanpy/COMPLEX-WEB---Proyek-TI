import { auth, db, firebaseConfigured } from "./firebase.js";
import {
  signInWithEmailAndPassword,
  signInWithPopup,
  GoogleAuthProvider,
  sendPasswordResetEmail,
  setPersistence,
  browserLocalPersistence,
  browserSessionPersistence,
  signOut
} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js";
import {
  doc,
  getDoc
} from "https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js";

const form = document.getElementById("loginForm");
const googleButton = document.getElementById("btnGoogle");
const submitButton = document.getElementById("btnSignIn");
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
    notify._timer = window.setTimeout(() => toast.classList.remove("is-visible"), 4200);
  } else {
    window.alert(message);
  }
}

function setBusy(button, busy, busyText = "Memproses...") {
  if (!button) return;
  if (busy) {
    button.dataset.originalHtml = button.innerHTML;
    button.textContent = busyText;
    button.disabled = true;
    button.setAttribute("aria-busy", "true");
  } else {
    button.innerHTML = button.dataset.originalHtml || button.innerHTML;
    button.disabled = false;
    button.removeAttribute("aria-busy");
  }
}

function saveResidentProfile(data, user) {
  const profile = {
    nama: data.nama || user.displayName || "",
    telp: data.telp || "",
    email: user.email || data.email || "",
    blok: data.blok || "",
    noRumah: data.noRumah || ""
  };

  try {
    localStorage.setItem("cx_profile", JSON.stringify(profile));
    sessionStorage.setItem("cx_active_profile", JSON.stringify(profile));
    const legacyKeys = {
      cx_nama: profile.nama,
      cx_telp: profile.telp,
      cx_email: profile.email,
      cx_blok: profile.blok,
      cx_noRumah: profile.noRumah
    };
    Object.entries(legacyKeys).forEach(([key, value]) => {
      localStorage.setItem(key, value);
      sessionStorage.setItem(key, value);
    });
    sessionStorage.setItem("cx_login_completed", "true");
    sessionStorage.setItem("cx_fromSigap", "false");
  } catch (error) {
    console.warn("Profil COMPLEX tidak dapat disimpan ke penyimpanan browser:", error);
  }
}

async function setLoginPersistence() {
  const remember = document.getElementById("rememberMe")?.checked;
  await setPersistence(
    auth,
    remember ? browserLocalPersistence : browserSessionPersistence
  );
}

function showFirebaseSetupMessage() {
  notify(
    "Autentikasi belum diaktifkan. Isi konfigurasi Firebase pada js/firebase-config.js terlebih dahulu.",
    "warning"
  );
}

// Pindahkan data profil pendaftaran ke kolom login tanpa menyimpan password.
try {
  const pendingProfile = sessionStorage.getItem("cx_pending_profile");
  if (pendingProfile) {
    const data = JSON.parse(pendingProfile);
    const fields = {
      loginNama: data.nama,
      loginTelp: data.telp,
      loginEmail: data.email,
      loginBlok: data.blok,
      loginNoRumah: data.noRumah
    };
    Object.entries(fields).forEach(([id, value]) => {
      const field = document.getElementById(id);
      if (field && typeof value === "string") field.value = value;
    });
    sessionStorage.removeItem("cx_pending_profile");
  }
} catch (error) {
  console.warn("Data profil sementara tidak dapat dibaca:", error);
}

// Toggle password.
document.getElementById("toggleLoginPass")?.addEventListener("click", () => {
  const field = document.getElementById("loginPassword");
  if (!field) return;
  field.type = field.type === "password" ? "text" : "password";
});

// Login email dan password hanya berhasil jika profil warga sudah terdaftar di Firestore.
form?.addEventListener("submit", async (event) => {
  event.preventDefault();

  const email = document.getElementById("loginEmail")?.value.trim() || "";
  const password = document.getElementById("loginPassword")?.value || "";

  if (!email || !password) {
    notify("Masukkan email dan password untuk melanjutkan.", "warning");
    return;
  }
  if (!firebaseConfigured || !auth || !db) {
    showFirebaseSetupMessage();
    return;
  }

  setBusy(submitButton, true, "Memverifikasi...");
  try {
    await setLoginPersistence();
    const credential = await signInWithEmailAndPassword(auth, email, password);
    const user = credential.user;
    const residentRef = doc(db, "residents", user.uid);
    const residentSnap = await getDoc(residentRef);

    if (!residentSnap.exists() || residentSnap.data().registered !== true) {
      await signOut(auth);
      notify(
        "Akun ini belum menyelesaikan pendaftaran warga. Silakan daftar terlebih dahulu.",
        "warning"
      );
      return;
    }

    saveResidentProfile(residentSnap.data(), user);
    window.location.replace("beranda.html");
  } catch (error) {
    const messages = {
      "auth/invalid-credential": "Email atau password tidak sesuai.",
      "auth/user-not-found": "Akun belum terdaftar. Silakan buat akun melalui menu Daftar.",
      "auth/wrong-password": "Password yang Anda masukkan salah.",
      "auth/invalid-email": "Format email tidak valid.",
      "auth/too-many-requests": "Terlalu banyak percobaan. Coba kembali beberapa saat lagi."
    };
    notify(messages[error.code] || "Login gagal. Periksa koneksi dan data akun Anda.", "error");
    console.error("Login COMPLEX gagal:", error);
  } finally {
    setBusy(submitButton, false);
  }
});

// Google: akun baru wajib melengkapi formulir Daftar sebelum dapat membuka Beranda.
googleButton?.addEventListener("click", async () => {
  if (!firebaseConfigured || !auth || !db) {
    showFirebaseSetupMessage();
    return;
  }

  setBusy(googleButton, true, "Menghubungkan Google...");
  try {
    await setLoginPersistence();
    const provider = new GoogleAuthProvider();
    provider.setCustomParameters({ prompt: "select_account" });
    const credential = await signInWithPopup(auth, provider);
    const user = credential.user;
    const residentSnap = await getDoc(doc(db, "residents", user.uid));

    if (residentSnap.exists() && residentSnap.data().registered === true) {
      saveResidentProfile(residentSnap.data(), user);
      window.location.replace("beranda.html");
      return;
    }

    sessionStorage.setItem("cx_google_registration_pending", "true");
    sessionStorage.setItem("cx_google_pending_email", user.email || "");
    sessionStorage.setItem("cx_google_pending_name", user.displayName || "");
    window.location.href = "daftar.html?source=google";
  } catch (error) {
    if (error.code === "auth/popup-closed-by-user") {
      notify("Proses masuk Google dibatalkan.", "info");
    } else if (error.code === "auth/account-exists-with-different-credential") {
      notify(
        "Email ini sudah menggunakan metode login lain. Silakan masuk dengan email dan password yang terdaftar.",
        "warning"
      );
    } else {
      notify("Masuk dengan Google gagal. Pastikan Google provider sudah aktif di Firebase.", "error");
      console.error("Google sign-in COMPLEX gagal:", error);
    }
  } finally {
    setBusy(googleButton, false);
  }
});

// Reset password melalui email.
document.getElementById("btnLupaPassword")?.addEventListener("click", async () => {
  const email = document.getElementById("loginEmail")?.value.trim() || "";
  if (!email) {
    notify("Masukkan email terlebih dahulu, lalu pilih Lupa Password.", "warning");
    return;
  }
  if (!firebaseConfigured || !auth) {
    showFirebaseSetupMessage();
    return;
  }
  try {
    await sendPasswordResetEmail(auth, email);
    notify("Tautan reset password telah dikirim jika email tersebut terdaftar.", "success");
  } catch (error) {
    notify("Email reset password belum dapat dikirim. Periksa alamat email Anda.", "error");
    console.error("Reset password gagal:", error);
  }
});

const params = new URLSearchParams(window.location.search);
if (params.get("registered") === "1") {
  notify("Pendaftaran berhasil. Silakan masuk menggunakan email dan password Anda.", "success");
} else if (params.get("required") === "1") {
  notify("Silakan login atau daftar terlebih dahulu untuk mengakses COMPLEX.", "info");
}
