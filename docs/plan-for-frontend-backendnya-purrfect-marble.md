# Plan: Full-Stack Build — Intake Nutrition Tracker (LIFF + Supabase + OpenAI)

## Context

`intake-nutrition-tracker` saat ini baru berupa boilerplate `create-liff-app` (Vite + React 19 + `@line/liff`) — `App.jsx` masih default, belum ada router, state management, Supabase client, atau backend sama sekali. Project sudah ter-link ke Netlify (untuk hosting frontend) dan punya GitHub remote. `.env` sudah punya `VITE_LIFF_ID`.

Tujuan produk (dari mockup yang diberikan): sebuah LIFF webapp di dalam LINE yang memudahkan user mencatat makanan hariannya cukup dengan foto — AI mendeteksi makanan & memperkirakan nutrisinya, user bisa review/edit sebelum simpan. Ada dashboard harian (kalori & makro vs target), riwayat per hari, dan target kalori personal dari onboarding (goal + activity level). Selain itu, project ingin menambahkan AI agent yang memberi rekomendasi/insight berdasarkan data historis yang sudah terkumpul di Supabase — fitur ini belum ada di mockup manapun, jadi UI-nya perlu didesain dari nol.

**Keputusan yang sudah dikonfirmasi user:**
1. AI provider: **OpenAI** (GPT-4o untuk vision/deteksi foto, GPT-4o-mini untuk teks insight) — pakai structured outputs (`json_schema`, `strict: true`), bukan parsing teks bebas.
2. Backend hosting: **Supabase Edge Functions** (Deno/TS) — colocated dengan DB, akses langsung via service-role key, timeout budget jauh lebih longgar daripada Netlify Functions (~10-26s) untuk panggilan vision model. Netlify tetap hanya untuk hosting frontend statis.
3. Onboarding: ditambah 1 step baru untuk age/birthdate, sex, height, weight — supaya target kalori dihitung pakai formula BMR/TDEE yang sebenarnya (Mifflin-St Jeor), bukan heuristik kasar.
4. Auth: verifikasi LINE ID token (dari `liff.getIDToken()`) langsung di tiap Edge Function via JWKS LINE — **tidak** dijembatani ke Supabase Auth/RLS-JWT (LINE bukan provider bawaan Supabase Auth). RLS tetap diaktifkan di semua tabel tanpa policy (deny-by-default) sebagai defense-in-depth, karena hanya service-role key yang dipakai di server.
5. Fitur Insights/AI recommendation: jadi **tab ke-3 di bottom nav** (Home / History / Insights), bukan sekadar teaser card.

---

## 1. Database Schema (Supabase Postgres)

### Tabel `profiles`
Identitas internal (`id uuid pk`) terpisah dari `line_user_id text unique not null` (LINE `sub`). Field cache dari LINE profile: `display_name`, `picture_url`. Field penting lain: `timezone text default 'UTC'` (dikirim client dari `Intl.DateTimeFormat`, dipakai untuk batas "hari ini"/streak/history grouping), `birthdate date`, `sex text check (in male/female/other)`, `height_cm numeric(5,2)`, `weight_kg numeric(5,2)`, `goal text check (lose_weight/maintain_weight/gain_weight)`, `activity_level text check (low/moderate/high)`, hasil hitung `bmr`, `tdee`, `daily_calorie_target int`, `protein_target_g`, `carbs_target_g`, `fat_target_g int`, `targets_overridden boolean default false` (true kalau user edit manual di Settings), `onboarding_completed_at timestamptz` (gating routing), `created_at`/`updated_at`.

### Tabel `meal_logs`
`id uuid pk`, `profile_id uuid fk -> profiles on delete cascade`, `photo_path text` (Storage object key `{profile_id}/{uuid}.jpg`, **bukan** full URL), `food_name text`, `meal_type text check (breakfast/lunch/dinner/snack)`, `logged_at timestamptz default now()`, nilai final (bisa hasil edit user): `calories`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `sugar_g`, `sodium_mg`, `note text`, `source text default 'ai_photo'` (future-proof untuk manual entry). Kolom provenance untuk audit: `ai_food_name`, `ai_nutrition jsonb` (snapshot sebelum diedit), `ai_confidence numeric(3,2)`, `ai_raw_response jsonb`, `is_edited boolean` (dihitung server dengan diff submitted vs `ai_nutrition`).

Index: `(profile_id, logged_at desc)` — dipakai dashboard, history, dan streak function.

### Tabel `insights`
`id uuid pk`, `profile_id fk`, `kind text check (on_demand/weekly_summary)`, `period_start`/`period_end date`, `summary text`, `highlights jsonb` (`[{type: positive|suggestion|watch_out, text}]`), `disclaimer text` (selalu tampil di UI), `metrics_snapshot jsonb` (agregat yang dikirim ke prompt, buat audit), `model text`, `created_at`.

Index: `(profile_id, created_at desc)`; unique partial index `(profile_id, period_start, period_end) where kind='weekly_summary'` untuk cegah duplikat dari cron.

### Derived, bukan stored
Daily totals & streak **tidak** disimpan sebagai kolom/tabel terpisah — dihitung on-the-fly, supaya tidak ada bug drift saat edit/delete lupa update angka agregat:
- View `daily_totals`: `sum(calories/protein_g/.../sodium_mg)` group by `profile_id, (logged_at at time zone profiles.timezone)::date`.
- Function `get_current_streak(profile_id) returns int`: loop mundur dari "hari ini" (di timezone user) selama ada minimal 1 log per hari.

### Storage bucket `food-photos`
**Private**, path `{profile_id}/{uuid}.ext` (pakai internal id, bukan `line_user_id`, supaya path yang bocor tidak bisa dikorelasikan ke identitas LINE). Tidak ada RLS policy untuk `anon`/`authenticated` — upload & read hanya lewat Edge Function pakai service-role key. Frontend selalu terima **signed URL short-TTL** (1 jam), tidak pernah raw URL. Batasi tipe file (jpeg/png/webp) & max size (~8MB) di level bucket sebagai backstop.

---

## 2. API Design (Supabase Edge Functions)

Dikelompokkan per domain (bukan 1 function per route) supaya cold-start lebih sedikit dan `_shared/` middleware bisa dipakai bareng:

```
supabase/functions/
  _shared/
    lineAuth.ts       # verifikasi JWKS LINE, return { lineUserId, profile }
    supabaseAdmin.ts  # service-role client factory
    cors.ts           # allowlist domain Netlify prod/preview + localhost
    openai.ts         # wrapper OpenAI client, ada MOCK_OPENAI toggle utk dev
    targets.ts         # kalkulasi BMR/TDEE Mifflin-St Jeor + target makro (pure function, testable)
    insights.ts         # generateInsightForProfile(profileId) — dipakai on-demand & cron
  profile/index.ts      # POST /bootstrap, GET /me, POST /onboarding, PUT /settings
  meals/index.ts         # POST /analyze, POST /, GET /history, PATCH /:id, DELETE /:id
  dashboard/index.ts      # GET /today
  insights/index.ts        # POST /generate, GET /latest
  insights-cron/index.ts    # auth via secret header, dipanggil pg_cron
```
`supabase/config.toml`: set `verify_jwt = false` di **semua** function (token yang masuk adalah LINE token atau secret header, bukan Supabase JWT).

### Daftar endpoint & screen mapping

| Endpoint | Guna | Screen |
|---|---|---|
| `POST profile/bootstrap` | Verifikasi LINE token, upsert `profiles`, return profile + `onboardingCompleted` | App root load (semua screen gate di sini) |
| `POST profile/onboarding` | Body: goal, activityLevel, birthdate, sex, heightCm, weightKg → hitung & simpan target | Onboarding step terakhir "target ready" |
| `PUT profile/settings` | Update parsial; recompute target kecuali user override manual | Settings (baru) |
| `POST meals/analyze` | Upload foto (multipart) → Storage + panggil OpenAI vision → return **draft, belum disimpan** | Capture screen, langsung setelah shutter |
| `POST meals` | Simpan draft (mungkin sudah diedit user) + provenance | Confirm screen "Save to Log" |
| `GET dashboard/today` | Target + streak + total hari ini (dari view `daily_totals`) + list meal hari ini | Home |
| `GET meals/history?cursor&limit` | Paginated, grouped per hari | History |
| `PATCH/DELETE meals/:id` | Edit/hapus log | Meal edit (UI baru, lihat catatan di bawah) |
| `POST insights/generate` | Agregat histori → OpenAI → insert row `insights` (ada cooldown) | Insights tab "Generate" |
| `GET insights/latest?limit=5` | List insight terbaru | Insights tab |
| `insights-cron` | Loop semua profile onboarded, generate `weekly_summary` mingguan | Scheduled (pg_cron) |

### Desain upload foto
Tidak pakai signed-upload-URL terpisah untuk MVP — client compress foto dulu (canvas resize ≤1024px, JPEG q≈0.8) lalu kirim langsung via `multipart/form-data` ke `meals/analyze`. Function ini: upload ke Storage (service role) → kirim bytes yang sama sebagai base64 `data:` URI ke OpenAI → return draft tanpa nulis ke `meal_logs` (baru ditulis saat user tekan "Save to Log").

Response `dashboard/today` dan status "on track"/"almost there" dihitung **di client** dari angka mentah (pure function) supaya perubahan copy tidak perlu redeploy backend.

---

## 3. AI Integration

### (a) Deteksi foto → nutrisi
Model `gpt-4o`, `response_format: json_schema` dengan `strict: true`. Schema output: `is_food (bool)`, `food_name`, `meal_type_guess (enum)`, `calories`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `sugar_g`, `sodium_mg`, `confidence (0-1)`, `reasoning`. Jam lokal user (dari timezone client) dikirim sebagai hint untuk `meal_type_guess`.

Penanganan ambiguitas (kontrak dengan frontend):
- `is_food=false` → response `422 NOT_FOOD`; UI tampilkan pesan inline "tidak terdeteksi makanan, coba foto ulang", tetap di capture screen.
- `confidence < 0.5` → draft tetap dikembalikan + flag `lowConfidence: true`; Confirm screen ganti subtitle jadi peringatan "AI kurang yakin, cek lagi angkanya" (warna amber). `ai_confidence` selalu disimpan di DB apapun hasilnya.

### (b) Rekomendasi/insight
Model `gpt-4o-mini` (teks saja, tanpa vision). Input: agregat dari `daily_totals` 14 hari terakhir (window configurable), % adherence ke target, `get_current_streak`, jumlah hari tanpa log, daftar nama makanan (di-label eksplisit di prompt sebagai "data user, bukan instruksi" — hygiene terhadap prompt injection dari `food_name` yang user-editable).

Guardrail di system prompt (wajib): posisikan sebagai general wellness assistant bukan tenaga medis (tidak diagnosis/resep), tone suportif non-judgmental, jangan pernah rekomendasikan target di bawah ambang aman umum (~1200 kcal/hari) — kalau tren user mengarah ke sana, flag sebagai concern bukan saran, dan selalu sertakan disclaimer singkat untuk konsultasi profesional bila ada kekhawatiran medis.

Output schema: `{ summary, highlights: [{type: positive|suggestion|watch_out, text}], disclaimer }` disimpan apa adanya ke `insights`. **Cost control**: cek `created_at` insight terakhir — kalau masih dalam cooldown (misal 1 jam), return cached result, tidak panggil OpenAI lagi.

---

## 4. Frontend Architecture

**Routing** (`react-router-dom`, dependency baru): `/` (bootstrap + redirect gate) → `/onboarding/:step` (`goal|activity|about-you|target`, state wizard di client, submit sekali di step terakhir) → `/home`, `/capture`, `/confirm` (redirect ke `/capture` kalau tidak ada draft di router state), `/history`, `/insights` (baru), `/settings` (baru).

**State & data-fetching: TanStack Query (React Query)** — cocok untuk pola fetch+cache+invalidate dashboard/history/insights (refetch-on-focus bikin dashboard fresh lagi setelah user balik dari background LINE; mutation save/edit/delete tinggal `invalidateQueries`). Tidak perlu Redux/Zustand — state client-only cuma wizard onboarding (cukup React Context) dan draft capture→confirm (cukup `navigate(path, { state })`).

**Camera capture**: native `<input type="file" accept="image/*" capture="environment">`, **bukan** `getUserMedia`. Alasan: in-app webview LINE (WKWebView/Chrome Custom Tab) historisnya tidak konsisten soal permission `getUserMedia`, sedangkan native file input delegasi langsung ke OS camera UI — reliable di iOS & Android, dan sekalian cover fallback "browse files" di mockup (input yang sama). Trade-off: tidak ada custom live-preview overlay — screen "Center your food in the frame" tampil sampai user tap shutter, lalu handoff ke OS camera.

**Styling**: Tailwind CSS (dependency baru) — jalan tercepat untuk match aesthetic mockup (dark bg, orange accent, card rounded, progress ring), dibantu 2 primitive custom: `ProgressRing` (SVG) dan `ProgressBar`.

**Env vars** — Frontend (`VITE_`): `VITE_LIFF_ID` (sudah ada), `VITE_SUPABASE_FUNCTIONS_URL`. Tidak ada Supabase anon key di client — client tidak pernah bicara langsung ke Supabase. Edge Function secrets: `LINE_CHANNEL_ID`, `OPENAI_API_KEY`, `CRON_SECRET`, `ALLOW_DEV_AUTH_BYPASS` (local only). `SUPABASE_URL`/`SUPABASE_SERVICE_ROLE_KEY` otomatis dari runtime Supabase.

**Struktur folder representatif**:
```
src/lib/liffClient.ts, src/lib/apiClient.ts   # apiClient baca liff.getIDToken() fresh tiap request
src/app/AuthGate.tsx, src/contexts/ProfileContext.tsx
src/features/onboarding/{GoalStep,ActivityStep,AboutYouStep,TargetSummaryStep}.tsx
src/features/dashboard/{HomeScreen,CalorieRing,MacroBar,StatTile,MealListItem}.tsx
src/features/capture/{CaptureScreen,image.ts}.tsx   # image.ts = util compress canvas
src/features/confirm/{ConfirmScreen,NutrientTile,EditableTitle}.tsx
src/features/history/{HistoryScreen,DayGroup}.tsx
src/features/insights/{InsightsScreen,InsightCard}.tsx
src/features/settings/SettingsScreen.tsx
```
Boilerplate lama (`App.jsx`, `main.jsx`) di-rewrite sebagai bagian Milestone 1 (jadi router root + `AuthGate`), tidak perlu rewrite terpisah sebelumnya.

---

## 5. Auth Flow Detail (LINE ID Token → Edge Function)

`_shared/lineAuth.ts` dipakai semua function yang butuh identitas user:
- Verifikasi JWT pakai `npm:jose` — `createRemoteJWKSet(new URL("https://api.line.me/oauth2/v2.1/certs"))` (auto-cache JWKS, isolate Edge Function tetap warm antar invocation jadi tidak fetch berulang).
- Cek `iss === "https://access.line.me"`, `aud === LINE_CHANNEL_ID` (Login Channel ID — **beda** dari LIFF ID, harus dicek manual di LINE Developers Console, jangan asumsi turunan dari LIFF ID), `clockTolerance: "60s"`.
- `sub` → `line_user_id`, upsert ke `profiles`.
- 401 kalau verifikasi gagal.

Dev/local testing bypass: flag `ALLOW_DEV_AUTH_BYPASS=true` (hanya di `.env.local`, **tidak pernah** di prod secrets) yang menerima header `X-Dev-Line-User-Id` sebagai pengganti verifikasi JWKS — supaya business logic bisa dites via curl/Postman tanpa LINE app asli.

Frontend `apiClient.ts` panggil `liff.getIDToken()` fresh tiap request (bukan di-cache di state) — murah karena baca sinkron dari SDK, dan menghindari kirim token basi.

---

## 6. Milestone Breakdown

| # | Scope | Selesai kalau |
|---|---|---|
| M0 | `supabase init`, migration 3 tabel + view + `get_current_streak` + storage bucket + RLS on/no-policy | `supabase db push` sukses, tabel muncul di Studio |
| M1 | `lineAuth.ts`, `profile/bootstrap`, `liffClient`/`apiClient`/`AuthGate` (rewrite App.jsx) | Buka app → bikin row `profiles`, echo balik ke frontend |
| M2 | Onboarding wizard UI (4 step) + `targets.ts` + `profile/onboarding` | Selesai onboarding → target tersimpan match hitungan manual |
| M3 | Capture screen, `meals/analyze`, Confirm screen (+ meal-type selector, karena mockup tidak menyediakan tapi data wajib ada), `meals` POST | Foto asli → tersimpan di `meal_logs` dengan provenance benar |
| M4 | `dashboard/today` + Home screen | Angka dashboard match jumlah manual data seed; streak match hitungan manual |
| M5 | `meals/history` + History screen | Data multi-hari (seed) tampil grouped/paginated dengan benar |
| M6 | `PATCH`/`DELETE meals/:id` + UI edit/hapus meal (tap on meal row — belum ada di mockup) | Edit/hapus langsung reflect setelah cache invalidation |
| M7 | Settings screen + `profile/settings` | Ubah berat badan → target recompute kecuali di-override manual |
| M8 | `insights.ts`, `insights/generate` + `/latest`, Insights tab (bottom nav ke-3) | Insight yang digenerate mengacu ke pola data seed asli; disclaimer selalu ada; cooldown jalan |
| M9 | pg_cron + `insights-cron` + `CRON_SECRET` | Cron run hasilkan 1 `weekly_summary` per profile onboarded, tidak duplikat |
| M10 | Polish: error/empty state, CORS lockdown, env var prod (Netlify + Supabase), smoke test di device asli dalam LINE app | Full flow jalan end-to-end di HP asli dalam LINE |

---

## 7. Verification Plan

- **Local stack**: `supabase start` (Postgres/Storage/Studio lokal via Docker) + `supabase functions serve --env-file supabase/.env.local` untuk hot-reload Edge Functions.
- **Seed data**: `supabase/seed.sql` — 1 profile test (`line_user_id='dev-test-user'`) sudah onboarded + `meal_logs` tersebar ~10 hari (variasi waktu/makro), auto-apply lewat `supabase db reset`. Cukup untuk test dashboard/history/streak/insights tanpa perlu foto asli tiap kali.
- **Auth tanpa HP**: iterasi logic pakai `ALLOW_DEV_AUTH_BYPASS` + header `X-Dev-Line-User-Id` via curl/frontend lokal. Untuk verifikasi JWKS asli tanpa device: LIFF app juga bisa dibuka via `https://liff.line.me/{liffId}` di browser biasa (LINE Login OAuth prompt) selama scope `openid` diaktifkan.
- **Kontrol biaya OpenAI saat development**: `openai.ts` support `MOCK_OPENAI=true` (return canned structured response) untuk iterasi UI/flow; panggilan asli dipakai khusus saat validasi kualitas prompt.
- **Smoke test wajib device asli** untuk capture flow (M3, M10) — ini satu-satunya behavior yang bisa beda dari testing via browser biasa.
- Kriteria "selesai" tiap milestone di tabel Section 6 dipakai sebagai acceptance test-nya.

---

## Catatan Implementasi / Hal yang Perlu Diverifikasi Saat Eksekusi

- Body-size limit Edge Function saat ini — pastikan cukup longgar untuk foto terkompresi (~150–400KB).
- Mekanisme cron: default pakai `pg_cron` + `pg_net` panggil Edge Function via HTTP + secret header; cek juga apakah Supabase CLI versi terbaru sudah punya native scheduled-function config yang lebih simpel.
- Behavior `liff.init()` untuk `localhost` vs registered endpoint URL saat local dev — cek dokumentasi LIFF terbaru sebelum diandalkan untuk workflow dev.
- Foto Storage yang orphan (diupload saat `analyze`, dibuang lewat "Retake", tidak pernah disave) tidak dibersihkan otomatis di MVP — bisa jadi cron pembersih di iterasi berikutnya.

### File-file kritis
- `supabase/migrations/0001_init.sql` — schema tabel, view, function, storage bucket, RLS
- `supabase/functions/_shared/lineAuth.ts` — verifikasi LINE JWKS, dipakai semua function
- `supabase/functions/meals/index.ts` — analyze (AI loop inti) + save
- `src/lib/apiClient.ts` — attach `liff.getIDToken()` ke tiap request
- `src/App.jsx` — di-rewrite jadi router root + `AuthGate` (saat ini masih boilerplate default)
