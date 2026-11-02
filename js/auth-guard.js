import { auth, db, firebaseConfigured } from "./firebase.js";
import { onAuthStateChanged, signOut } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js";
import { doc, getDoc } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js";

// Pasang file ini pada halaman dashboard/fitur yang hanya boleh dibuka warga terdaftar.
// Jangan pasang pada index.html, daftar.html, atau halaman darurat publik SIGAP.
if (!firebaseConfigured || !auth || !db) {
  window.location.replace("index.html?required=1");
} else {
  onAuthStateChanged(auth, async (user) => {
    if (!user) {
      window.location.replace("index.html?required=1");
      return;
    }

    try {
      const resident = await getDoc(doc(db, "residents", user.uid));
      if (!resident.exists() || resident.data().registered !== true) {
        await signOut(auth);
        window.location.replace("index.html?required=1");
      }
    } catch (error) {
      console.error("Pemeriksaan akses COMPLEX gagal:", error);
      window.location.replace("index.html?required=1");
    }
  });
}
