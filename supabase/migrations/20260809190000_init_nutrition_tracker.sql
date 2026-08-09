create extension if not exists pgcrypto;

create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  line_user_id text not null unique,
  display_name text,
  picture_url text,
  timezone text not null default 'UTC',
  birthdate date,
  sex text check (sex in ('male', 'female', 'other')),
  height_cm numeric(5,2) check (height_cm > 0),
  weight_kg numeric(5,2) check (weight_kg > 0),
  goal text check (goal in ('lose_weight', 'maintain_weight', 'gain_weight')),
  activity_level text check (activity_level in ('low', 'moderate', 'high')),
  bmr integer check (bmr > 0),
  tdee integer check (tdee > 0),
  daily_calorie_target integer check (daily_calorie_target > 0),
  protein_target_g integer check (protein_target_g > 0),
  carbs_target_g integer check (carbs_target_g > 0),
  fat_target_g integer check (fat_target_g > 0),
  targets_overridden boolean not null default false,
  onboarding_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.meal_logs (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  photo_path text,
  food_name text not null,
  meal_type text not null check (meal_type in ('breakfast', 'lunch', 'dinner', 'snack')),
  logged_at timestamptz not null default now(),
  calories integer not null check (calories >= 0),
  protein_g numeric(7,2) not null default 0 check (protein_g >= 0),
  carbs_g numeric(7,2) not null default 0 check (carbs_g >= 0),
  fat_g numeric(7,2) not null default 0 check (fat_g >= 0),
  fiber_g numeric(7,2) not null default 0 check (fiber_g >= 0),
  sugar_g numeric(7,2) not null default 0 check (sugar_g >= 0),
  sodium_mg numeric(9,2) not null default 0 check (sodium_mg >= 0),
  note text,
  source text not null default 'ai_photo' check (source in ('ai_photo', 'manual')),
  ai_food_name text,
  ai_nutrition jsonb,
  ai_confidence numeric(3,2) check (ai_confidence >= 0 and ai_confidence <= 1),
  ai_raw_response jsonb,
  is_edited boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index meal_logs_profile_logged_at_idx on public.meal_logs (profile_id, logged_at desc);

create table public.insights (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('on_demand', 'weekly_summary')),
  period_start date not null,
  period_end date not null check (period_end >= period_start),
  summary text not null,
  highlights jsonb not null default '[]'::jsonb,
  disclaimer text not null,
  metrics_snapshot jsonb not null default '{}'::jsonb,
  model text not null,
  created_at timestamptz not null default now()
);

create index insights_profile_created_at_idx on public.insights (profile_id, created_at desc);
create unique index insights_weekly_period_unique on public.insights (profile_id, period_start, period_end) where kind = 'weekly_summary';

create view public.daily_totals with (security_invoker = true) as
select
  m.profile_id,
  (m.logged_at at time zone p.timezone)::date as log_date,
  sum(m.calories)::integer as calories,
  sum(m.protein_g) as protein_g,
  sum(m.carbs_g) as carbs_g,
  sum(m.fat_g) as fat_g,
  sum(m.fiber_g) as fiber_g,
  sum(m.sugar_g) as sugar_g,
  sum(m.sodium_mg) as sodium_mg
from public.meal_logs m
join public.profiles p on p.id = m.profile_id
group by m.profile_id, (m.logged_at at time zone p.timezone)::date;

create or replace function public.get_current_streak(target_profile_id uuid)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  current_day date;
  streak integer := 0;
begin
  select (now() at time zone timezone)::date into current_day
  from public.profiles where id = target_profile_id;

  if current_day is null then return 0; end if;

  loop
    if exists (
      select 1 from public.meal_logs m
      join public.profiles p on p.id = m.profile_id
      where m.profile_id = target_profile_id
        and (m.logged_at at time zone p.timezone)::date = current_day
    ) then
      streak := streak + 1;
      current_day := current_day - 1;
    else
      exit;
    end if;
  end loop;
  return streak;
end;
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$ begin new.updated_at = now(); return new; end; $$;

create trigger profiles_set_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create trigger meal_logs_set_updated_at before update on public.meal_logs for each row execute function public.set_updated_at();

alter table public.profiles enable row level security;
alter table public.meal_logs enable row level security;
alter table public.insights enable row level security;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('food-photos', 'food-photos', false, 8388608, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
