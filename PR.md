# Intake Nutrition Tracker — Project Context

## Product

A dark, mobile-first LIFF nutrition tracker. Users complete onboarding, photograph a meal, receive an AI nutrition estimate, review it, save it, and see daily totals/history.

The visual source of truth is in `docs/01-screen.png` through `docs/09-screen.png`. The original technical design is `docs/plan-for-frontend-backendnya-purrfect-marble.md`; the current Supabase architecture is summarized in `docs/supabase-backend-plan.md`.

## Frontend

- Stack: Vite, React 19, `@line/liff`, `lucide-react`.
- Entry: `src/App.jsx`; styles: `src/App.css`.
- API client: `src/lib/apiClient.js`.
- In an external browser, the API client redirects an unauthenticated user through `liff.login()` before requesting an ID token. In the LINE in-app browser, LIFF supplies the token during initialization.
- The frontend contains **no static nutrition/history records**. Home, History, Capture, Confirm, and onboarding use Edge Function responses or visible loading/error/empty states.
- Environment values required locally and in Netlify:

  ```text
  VITE_LIFF_ID=<LIFF id>
  VITE_SUPABASE_FUNCTIONS_URL=https://oshavjjtkwdkymfdgaxi.supabase.co/functions/v1
  ```

Never put any Supabase secret key, OpenAI key, database password, or LINE channel secret in `VITE_*` variables or source files.

## Supabase

- Project ref: `oshavjjtkwdkymfdgaxi`.
- Initial migration is applied remotely and saved locally at:
  `supabase/migrations/20260809190000_init_nutrition_tracker.sql`.
- Current PostgreSQL objects:
  - `public.profiles`
  - `public.meal_logs`
  - `public.insights`
  - `public.daily_totals` view
  - `public.get_current_streak(uuid)` function
  - private `food-photos` Storage bucket
- RLS is enabled with no browser policies intentionally. All user data is accessed only through server-side Edge Functions using an admin key after LINE ID-token verification.
- Database was empty at setup time; no seed/mock meals were inserted.

## Deployed Edge Functions

All functions are active and use custom LINE-token verification, so Supabase platform JWT verification is intentionally disabled (`verify_jwt=false`).

| Function | Routes / responsibility |
| --- | --- |
| `profile` | `POST /profile/bootstrap`, `POST /profile/onboarding` |
| `dashboard` | `GET /dashboard/today` |
| `meals` | `GET /meals/history`, `POST /meals` |
| `meal-analyze` | `POST /meal-analyze`; validates a food photo then sends it to OpenAI for structured nutrition analysis |

Shared code is in `supabase/functions/_shared/server.ts`. It validates LINE ID tokens against LINE JWKS and reads the following secrets from Edge Function configuration:

```text
LINE_CHANNEL_ID
OPENAI_API_KEY
```

Supabase-provided server secrets are used internally for database access. Do not create a local committed secret file. In development, use an ignored `supabase/functions/.env.local` file if needed.

## Current known gaps

1. **Onboarding now has an “About you” step.** It collects `birthdate`, `sex`, `heightCm`, and `weightKg` alongside goal/activity before submitting the complete target-calculation payload. Verify it in a real LIFF session after deployment.
2. **No browser/device end-to-end test has been completed.** The available browser automation binary was missing. `yarn build` passes, but verify inside the actual LINE webview after the onboarding change.
3. **Meal photo handling.** `meal-analyze` currently sends the selected image directly to OpenAI and returns a draft. It does not yet upload the original image to `food-photos`; add storage upload and a signed URL only if product requirements need photo retention.
4. **Missing settings, Insights UI, edit/delete meal API/UI, and scheduled weekly insight job.** These are described in the backend plan but not implemented.
5. **Pre-existing Supabase advisor warnings.** The project has an existing `public.rls_auto_enable()` `SECURITY DEFINER` function callable by anon/authenticated roles, plus leaked-password protection is disabled. These predate this implementation and should be reviewed in the Supabase Dashboard.

## Recommended next session

1. Add the demographic onboarding form and submit all required profile fields to `profile/onboarding`.
2. Test bootstrap → onboarding → dashboard against the LIFF app, preferably using a real LINE user.
3. Test one meal photo. Confirm the user-consent copy before enabling production use of OpenAI photo processing.
4. Add client-side query invalidation/loading states with TanStack Query if the data flow grows.
5. Implement meal edit/delete, settings, Insights, and cron in that order.

## Verification performed

- `yarn build` passes after the API client and function wiring changes.
- Supabase migration was applied and verified: the three tables exist, RLS is enabled, and all four Edge Functions report `ACTIVE`.
- No real user data or secrets are stored in this repository.
