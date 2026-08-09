import { createClient } from "npm:@supabase/supabase-js@2";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5";

const corsHeaders = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, content-type, x-dev-line-user-id", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const jwks = createRemoteJWKSet(new URL("https://api.line.me/oauth2/v2.1/certs"));
export const json = (body: unknown, status = 200) => Response.json(body, { status, headers: corsHeaders });
export const options = () => new Response(null, { status: 204, headers: corsHeaders });

function secretKey() {
  const modern = Deno.env.get("SUPABASE_SECRET_KEYS");
  return modern ? JSON.parse(modern).default : Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
}
export const admin = () => createClient(Deno.env.get("SUPABASE_URL")!, secretKey());

export async function profileFor(req: Request) {
  const bypass = Deno.env.get("ALLOW_DEV_AUTH_BYPASS") === "true" ? req.headers.get("x-dev-line-user-id") : null;
  const token = req.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  let lineUserId = bypass;
  if (!lineUserId) {
    if (!token) throw new Error("Missing LINE ID token");
    const result = await jwtVerify(token, jwks, { issuer: "https://access.line.me", audience: Deno.env.get("LINE_CHANNEL_ID"), clockTolerance: 60 });
    lineUserId = result.payload.sub as string;
  }
  const db = admin();
  const { data, error } = await db.from("profiles").upsert({ line_user_id: lineUserId }, { onConflict: "line_user_id" }).select().single();
  if (error) throw error;
  return data;
}

export function targets(input: Record<string, unknown>) {
  const age = Math.max(18, Math.floor((Date.now() - new Date(String(input.birthdate)).getTime()) / 31557600000));
  const weight = Number(input.weightKg), height = Number(input.heightCm);
  const base = 10 * weight + 6.25 * height - 5 * age + (input.sex === "male" ? 5 : -161);
  const multiplier = input.activityLevel === "high" ? 1.725 : input.activityLevel === "moderate" ? 1.55 : 1.2;
  const tdee = Math.round(base * multiplier);
  const calories = tdee + (input.goal === "lose_weight" ? -400 : input.goal === "gain_weight" ? 300 : 0);
  return { bmr: Math.round(base), tdee, daily_calorie_target: calories, protein_target_g: Math.round(weight * 1.8), carbs_target_g: Math.round(calories * .5 / 4), fat_target_g: Math.round(calories * .25 / 9) };
}
