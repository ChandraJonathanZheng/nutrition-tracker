# Sprint 2 — Monetization & Image Credit System

## Goal

Mengubah Intake Nutrition Tracker menjadi produk freemium: user mendapat trial upload terbatas, lalu dapat berlangganan paket berbayar berbasis kuota analisis foto bulanan dalam USD.

**Durasi:** 2 minggu  
**Outcome:** User dapat mencoba analisis foto gratis hingga `{N}` kali, lalu berlangganan untuk mendapat kuota foto setiap periode billing.

## Product Decisions

| Keputusan | Rekomendasi awal |
| --- | --- |
| Free trial | `{N} = 5` analisis foto per user |
| Billing period | Bulanan; credit reset pada awal billing cycle |
| Mata uang | USD |
| Credit deduction | Hanya setelah analisis foto berhasil menghasilkan result |
| Quota habis | Tampilkan paywall dengan upgrade dan opsi top-up sebagai stretch goal |

## Pricing Proposal

| Paket | Kuota | Harga awal | Target user |
| --- | ---: | ---: | --- |
| Basic | 50 foto/bulan | $5.99/bulan | User yang mulai rutin mencatat makanan |
| Medium | 150 foto/bulan | $11.99/bulan | User aktif dengan beberapa meal log per hari |
| Premium | 300 foto/bulan | $19.99/bulan | Power user atau penggunaan keluarga |

Harga perlu dievaluasi berdasarkan biaya vision/AI, storage, payment fee, conversion rate, dan churn setelah soft launch.

## User Stories

- Sebagai user baru, saya dapat menganalisis hingga `{N}` foto gratis sebelum diminta berlangganan.
- Sebagai user berbayar, saya dapat melihat paket aktif, sisa kuota foto, dan tanggal reset quota.
- Sebagai user, saya dapat memilih Basic, Medium, atau Premium dan membayar dalam USD.
- Sebagai user, credit hanya berkurang bila analisis foto sukses.
- Sebagai user dengan quota habis, saya diarahkan untuk upgrade paket atau membeli add-on credit.
- Sebagai admin, saya dapat menelusuri penggunaan credit dan status pembayaran user.

## Scope Fitur

| Area | Deliverable |
| --- | --- |
| Free trial | Maksimum `{N}` analisis foto gratis per user |
| Paket berbayar | Basic, Medium, dan Premium dengan quota bulanan |
| Paywall | Ditampilkan saat trial atau quota habis |
| Checkout | Pembayaran subscription dalam USD |
| Credit engine | Reserve dan deduct credit secara aman serta idempotent |
| Usage UI | Meter sisa quota dan tanggal reset pada dashboard/upload flow |
| Billing UI | Paket aktif, status subscription, renewal date, serta manage subscription |
| Monitoring | Log penggunaan, payment event, dan kegagalan deduction |

## Technical Design

### Data model

Tambahkan atau perluas model berikut:

```text
subscriptions
  id
  profile_id
  provider_customer_id
  provider_subscription_id
  plan                # basic | medium | premium
  status              # active | past_due | canceled | incomplete
  current_period_start
  current_period_end
  cancel_at_period_end
  created_at
  updated_at

usage_credits
  id
  profile_id
  period_start
  period_end
  included_credits
  used_credits
  created_at
  updated_at

usage_events
  id
  profile_id
  image_job_id
  event_type          # trial_used | credit_reserved | credit_used | credit_reversed
  credits_delta
  idempotency_key
  metadata
  created_at
```

`image_jobs` atau record analisis perlu menyimpan `credit_charged` dan `idempotency_key` agar retry, double-submit, atau webhook yang terkirim ulang tidak mengurangi credit lebih dari sekali.

### Entitlement flow

```text
User submit foto
  → cek free trial / subscription / remaining credit
  → reserve satu credit secara atomik
  → proses image analysis
  → sukses: finalize penggunaan credit
  → gagal: reverse reservation
  → quota habis: tampilkan paywall
```

Credit **tidak** boleh dikurangi hanya karena file berhasil di-upload. Pengurangan dilakukan setelah AI mengembalikan hasil analisis yang valid.

### Billing integration

Provider pembayaran perlu mendukung recurring subscription USD, webhook, customer portal, serta metadata untuk menghubungkan customer dengan `profile_id` internal.

Webhook minimal yang perlu ditangani:

- Checkout/payment berhasil → aktifkan subscription dan buat/sinkronkan credit period.
- Renewal berhasil → reset quota sesuai paket.
- Payment gagal → tandai `past_due` dan terapkan grace period bila dipilih.
- Subscription dibatalkan/berakhir → hentikan entitlement setelah period aktif berakhir.
- Event webhook duplikat → abaikan dengan event ID/idempotency record.

## Sprint Breakdown

### Hari 1–2 — Product rules & data model

- Finalisasi nilai `{N}`, harga paket, dan grace period pembayaran gagal.
- Definisikan aturan upgrade/downgrade dan reset quota.
- Tambah migration untuk subscription, credit period, dan usage event.
- Tambah feature flag monetization untuk rollout aman.

### Hari 3–5 — Backend entitlement & quota control

- Buat service pengecekan entitlement sebelum proses image analysis.
- Implement reserve/finalize/reverse credit secara atomik dan idempotent.
- Catat event trial, penggunaan credit, dan kegagalan analisis.
- Blok analisis baru saat quota habis.
- Tambahkan API untuk current plan, remaining credits, dan billing period.

### Hari 6–7 — Payment & webhooks

- Konfigurasi tiga recurring price dalam USD.
- Implement checkout dan halaman return sukses/gagal/cancel.
- Implement webhook verification serta sinkronisasi status subscription.
- Tambahkan customer portal untuk cancel atau manage subscription.

### Hari 8–9 — Frontend pricing & billing

- Buat halaman pricing dengan perbandingan Basic, Medium, dan Premium.
- Buat paywall setelah free trial atau quota habis.
- Tampilkan usage meter pada dashboard dan upload flow.
- Tambahkan billing screen: plan aktif, sisa credit, dan renewal date.

### Hari 10 — QA, monitoring & release

- Test trial, checkout, renewal, cancel, payment failure, dan quota habis.
- Test retry image analysis dan concurrent upload untuk mencegah double charge.
- Test webhook replay/idempotency.
- Tambahkan monitoring error dan dashboard penggunaan.
- Soft launch melalui feature flag dan pantau conversion serta cost per image.

## Acceptance Criteria

- Free user tidak dapat menyelesaikan lebih dari `{N}` analisis foto.
- Basic, Medium, dan Premium memberikan entitlement 50, 150, dan 300 foto per billing period aktif.
- Credit tidak berkurang ketika upload atau analisis gagal.
- Concurrent request dan retry tidak dapat memakai satu credit lebih dari satu kali.
- Status billing tersinkron dari webhook secara idempotent.
- User dapat melihat quota tersisa dan opsi upgrade dengan jelas.
- Semua aksi billing dan penggunaan credit dapat ditelusuri melalui log/event.

## Stretch Goals

- Top-up credit sekali beli, misalnya 25 foto seharga $3.99.
- Annual plan dengan diskon.
- Promo code atau referral credit.
- Localized pricing dan mata uang IDR bila Indonesia menjadi market utama.
- Admin dashboard untuk revenue, quota usage, conversion, dan unit economics.

## Open Decisions

1. Konfirmasi final nilai free trial `{N}` — rekomendasi: **5 foto**.
2. Konfirmasi apakah upgrade langsung memberi quota paket baru secara prorata atau berlaku di cycle berikutnya.
3. Tentukan grace period untuk payment gagal.
4. Putuskan apakah top-up credits masuk Sprint 2 atau tetap menjadi stretch goal.
