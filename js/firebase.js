import { initializeApp } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-app.js";
import { getAuth } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-auth.js";
import { getFirestore } from "https://www.gstatic.com/firebasejs/10.14.1/firebase-firestore.js";
import { firebaseConfig } from "./firebase-config.js";

const requiredConfig = ["apiKey", "authDomain", "projectId", "appId"];
export const firebaseConfigured = requiredConfig.every((key) => {
  const value = firebaseConfig[key];
  return (
    typeof value === "string" &&
    value.trim() !== "" &&
    !value.startsWith("GANTI_")
  );
});

let app = null;
export let auth = null;
export let db = null;

if (firebaseConfigured) {
  app = initializeApp(firebaseConfig);
  auth = getAuth(app);
  db = getFirestore(app);
} else {
  console.warn(
    "[COMPLEX] Firebase belum dikonfigurasi. Isi js/firebase-config.js terlebih dahulu.",
  );
}
