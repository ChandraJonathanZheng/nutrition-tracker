import liff from "@line/liff";

const functionsUrl = import.meta.env.VITE_SUPABASE_FUNCTIONS_URL;

let liffInit;
async function getIdToken() {
  if (!import.meta.env.VITE_LIFF_ID) return null;
  liffInit ??= liff.init({ liffId: import.meta.env.VITE_LIFF_ID });
  await liffInit;
  if (!liff.isInClient() && !liff.isLoggedIn()) {
    liff.login({ redirectUri: window.location.href });
    throw new Error("Redirecting to LINE Login…");
  }
  return liff.getIDToken();
}

async function request(path, options = {}) {
  if (!functionsUrl) throw new Error("VITE_SUPABASE_FUNCTIONS_URL is not configured.");
  const idToken = await getIdToken();
  const response = await fetch(`${functionsUrl.replace(/\/$/, "")}/${path}`, {
    ...options,
    headers: {
      ...(options.body instanceof FormData ? {} : { "Content-Type": "application/json" }),
      ...(idToken ? { Authorization: `Bearer ${idToken}` } : {}),
      ...options.headers,
    },
  });
  if (!response.ok) throw new Error((await response.json().catch(() => null))?.message || "Request failed.");
  return response.status === 204 ? null : response.json();
}

async function normalizeFoodPhoto(file) {
  const needsConversion = file.type === "image/heic" || file.type === "image/heif" || /\.hei[cf]$/i.test(file.name);
  if (!needsConversion) return file;

  try {
    const { heicTo } = await import("heic-to");
    const jpeg = await heicTo({ blob: file, type: "image/jpeg", quality: 0.85 });
    return new File([jpeg], `${file.name.replace(/\.hei[cf]$/i, "") || "food"}.jpg`, { type: "image/jpeg" });
  } catch {
    throw new Error("This HEIC photo could not be converted. Take a new photo in JPEG/Most Compatible format, or choose a JPEG, PNG, or WebP image.");
  }
}

export const api = {
  bootstrap: () => request("profile/bootstrap", { method: "POST" }),
  dashboard: () => request("dashboard/today"),
  history: () => request("meals/history?limit=30"),
  analyzeMeal: async (file) => { const body = new FormData(); body.append("photo", await normalizeFoodPhoto(file)); return request("meal-analyze", { method: "POST", body }); },
  saveMeal: (draft) => request("meals", { method: "POST", body: JSON.stringify(draft) }),
  completeOnboarding: (profile) => request("profile/onboarding", { method: "POST", body: JSON.stringify(profile) }),
};
