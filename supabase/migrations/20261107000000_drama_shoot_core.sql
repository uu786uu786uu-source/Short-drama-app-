begin;

create extension if not exists pgcrypto;

create schema if not exists app_private;
revoke all on schema app_private from public, anon, authenticated;
grant usage on schema app_private to authenticated;

create table if not exists app_private.admin_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'editor')),
  granted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

alter table app_private.admin_members enable row level security;
drop policy if exists "admin members can read their own role" on app_private.admin_members;
create policy "admin members can read their own role"
  on app_private.admin_members
  for select
  to authenticated
  using (user_id = (select auth.uid()));

grant select on app_private.admin_members to authenticated;

create or replace function app_private.is_creator()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from app_private.admin_members m
    where m.user_id = (select auth.uid())
      and m.role in ('owner', 'admin', 'editor')
  );
$$;

create or replace function app_private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from app_private.admin_members m
    where m.user_id = (select auth.uid())
      and m.role in ('owner', 'admin')
  );
$$;

revoke all on function app_private.is_creator() from public, anon;
revoke all on function app_private.is_admin() from public, anon;
grant execute on function app_private.is_creator() to authenticated;
grant execute on function app_private.is_admin() to authenticated;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  username_locked boolean not null default false,
  display_name text not null default 'Viewer',
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_username_format check (username ~ '^[a-z0-9_]{3,24}$')
);

create unique index if not exists profiles_username_lower_uidx
  on public.profiles (lower(username));

create table if not exists public.dramas (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  cover_path text,
  status text not null default 'draft'
    check (status in ('draft', 'published', 'archived')),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz
);

create index if not exists dramas_status_published_idx
  on public.dramas (status, published_at desc);

create table if not exists public.episodes (
  id uuid primary key default gen_random_uuid(),
  drama_id uuid not null references public.dramas(id) on delete cascade,
  episode_number integer not null check (episode_number > 0),
  title text not null,
  description text,
  video_path text,
  thumbnail_path text,
  duration_seconds integer check (duration_seconds is null or duration_seconds >= 0),
  coins_cost integer not null default 0 check (coins_cost >= 0),
  is_published boolean not null default false,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (drama_id, episode_number)
);

create index if not exists episodes_drama_order_idx
  on public.episodes (drama_id, episode_number);

create table if not exists public.coin_wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance integer not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.coin_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  amount integer not null check (amount <> 0),
  reason text not null check (reason in ('welcome', 'ad_reward', 'purchase', 'episode_unlock', 'admin_adjustment', 'refund')),
  reference_id uuid,
  idempotency_key text unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists coin_transactions_user_created_idx
  on public.coin_transactions (user_id, created_at desc);

create table if not exists public.episode_unlocks (
  user_id uuid not null references auth.users(id) on delete cascade,
  episode_id uuid not null references public.episodes(id) on delete cascade,
  coins_paid integer not null default 0 check (coins_paid >= 0),
  transaction_id uuid references public.coin_transactions(id),
  unlocked_at timestamptz not null default now(),
  primary key (user_id, episode_id)
);

create table if not exists public.watch_progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  episode_id uuid not null references public.episodes(id) on delete cascade,
  progress_seconds integer not null default 0 check (progress_seconds >= 0),
  completed boolean not null default false,
  last_watched_at timestamptz not null default now(),
  primary key (user_id, episode_id)
);

create index if not exists watch_progress_user_recent_idx
  on public.watch_progress (user_id, last_watched_at desc);

create table if not exists public.ad_reward_claims (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null,
  provider_transaction_id text not null,
  reward_coins integer not null check (reward_coins > 0),
  status text not null default 'pending'
    check (status in ('pending', 'verified', 'rejected')),
  created_at timestamptz not null default now(),
  verified_at timestamptz,
  unique (provider, provider_transaction_id)
);

create index if not exists ad_reward_claims_user_created_idx
  on public.ad_reward_claims (user_id, created_at desc);

create table if not exists app_private.admin_audit_log (
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table app_private.admin_audit_log enable row level security;
revoke all on app_private.admin_audit_log from public, anon, authenticated;

create or replace function app_private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_display_name text;
begin
  v_display_name := coalesce(
    nullif(new.raw_user_meta_data ->> 'display_name', ''),
    nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
    'Viewer'
  );

  insert into public.profiles (user_id, username, display_name)
  values (
    new.id,
    'viewer_' || substring(replace(new.id::text, '-', '') from 1 for 12),
    v_display_name
  )
  on conflict (user_id) do nothing;

  insert into public.coin_wallets (user_id, balance)
  values (new.id, 0)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

revoke all on function app_private.handle_new_auth_user() from public, anon, authenticated;
drop trigger if exists on_auth_user_created_drama_shoot on auth.users;
create trigger on_auth_user_created_drama_shoot
  after insert on auth.users
  for each row execute function app_private.handle_new_auth_user();

create or replace function public.claim_username(p_username text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;

  if p_username is null or lower(p_username) !~ '^[a-z0-9_]{3,24}$' then
    raise exception 'Username must be 3-24 characters (letters, numbers, underscore only)'
      using errcode = '22023';
  end if;

  update public.profiles
     set username = lower(p_username),
         username_locked = true,
         updated_at = now()
   where user_id = (select auth.uid())
     and username_locked = false
  returning username into v_username;

  if v_username is null then
    raise exception 'Username has already been claimed and cannot be changed'
      using errcode = '42501';
  end if;

  return v_username;
end;
$$;

revoke all on function public.claim_username(text) from public, anon;
grant execute on function public.claim_username(text) to authenticated;

alter table public.profiles enable row level security;
alter table public.dramas enable row level security;
alter table public.episodes enable row level security;
alter table public.coin_wallets enable row level security;
alter table public.coin_transactions enable row level security;
alter table public.episode_unlocks enable row level security;
alter table public.watch_progress enable row level security;
alter table public.ad_reward_claims enable row level security;

drop policy if exists "profiles are readable" on public.profiles;
create policy "profiles are readable"
  on public.profiles for select
  to anon, authenticated
  using (true);

drop policy if exists "users update their own profile" on public.profiles;
create policy "users update their own profile"
  on public.profiles for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "published dramas are visible" on public.dramas;
create policy "published dramas are visible"
  on public.dramas for select
  to anon, authenticated
  using (status = 'published' or (select app_private.is_creator()));

drop policy if exists "creators manage dramas" on public.dramas;
create policy "creators manage dramas"
  on public.dramas for all
  to authenticated
  using ((select app_private.is_creator()))
  with check ((select app_private.is_creator()));

drop policy if exists "published episodes are visible" on public.episodes;
create policy "published episodes are visible"
  on public.episodes for select
  to anon, authenticated
  using (
    (
      is_published = true
      and exists (
        select 1 from public.dramas d
        where d.id = episodes.drama_id
          and d.status = 'published'
      )
    )
    or (select app_private.is_creator())
  );

drop policy if exists "creators manage episodes" on public.episodes;
create policy "creators manage episodes"
  on public.episodes for all
  to authenticated
  using ((select app_private.is_creator()))
  with check ((select app_private.is_creator()));

drop policy if exists "users read own wallet" on public.coin_wallets;
create policy "users read own wallet"
  on public.coin_wallets for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "users read own coin transactions" on public.coin_transactions;
create policy "users read own coin transactions"
  on public.coin_transactions for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "users read own episode unlocks" on public.episode_unlocks;
create policy "users read own episode unlocks"
  on public.episode_unlocks for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "users manage own watch progress" on public.watch_progress;
create policy "users manage own watch progress"
  on public.watch_progress for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "users insert own watch progress" on public.watch_progress;
create policy "users insert own watch progress"
  on public.watch_progress for insert
  to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists "users update own watch progress" on public.watch_progress;
create policy "users update own watch progress"
  on public.watch_progress for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "users read own ad reward claims" on public.ad_reward_claims;
create policy "users read own ad reward claims"
  on public.ad_reward_claims for select
  to authenticated
  using (user_id = (select auth.uid()));

grant usage on schema public to anon, authenticated;
grant select on public.profiles, public.dramas, public.episodes to anon, authenticated;
grant update (display_name, avatar_url) on public.profiles to authenticated;
grant insert, update, delete on public.dramas, public.episodes to authenticated;
grant select on public.coin_wallets, public.coin_transactions, public.episode_unlocks, public.ad_reward_claims to authenticated;
grant select, insert, update on public.watch_progress to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', true, 10485760, array['image/jpeg', 'image/png', 'image/webp']),
  ('drama-covers', 'drama-covers', true, 20971520, array['image/jpeg', 'image/png', 'image/webp']),
  ('drama-videos', 'drama-videos', false, 536870912, array['video/mp4', 'video/webm', 'video/quicktime', 'video/x-m4v'])
on conflict (id) do update
set name = excluded.name,
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "users read own avatar objects" on storage.objects;
create policy "users read own avatar objects"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "users upload own avatar objects" on storage.objects;
create policy "users upload own avatar objects"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "users update own avatar objects" on storage.objects;
create policy "users update own avatar objects"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "users delete own avatar objects" on storage.objects;
create policy "users delete own avatar objects"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "creators upload drama covers" on storage.objects;
create policy "creators upload drama covers"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'drama-covers' and (select app_private.is_creator()));

drop policy if exists "creators update drama covers" on storage.objects;
create policy "creators update drama covers"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'drama-covers' and (select app_private.is_creator()))
  with check (bucket_id = 'drama-covers' and (select app_private.is_creator()));

drop policy if exists "creators delete drama covers" on storage.objects;
create policy "creators delete drama covers"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'drama-covers' and (select app_private.is_creator()));

drop policy if exists "viewers read accessible episode videos" on storage.objects;
create policy "viewers read accessible episode videos"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'drama-videos'
    and (
      (select app_private.is_creator())
      or exists (
        select 1
        from public.episodes e
        join public.dramas d on d.id = e.drama_id
        where e.id::text = (storage.foldername(name))[1]
          and e.is_published = true
          and d.status = 'published'
          and (
            e.coins_cost = 0
            or exists (
              select 1
              from public.episode_unlocks u
              where u.episode_id = e.id
                and u.user_id = (select auth.uid())
            )
          )
      )
    )
  );

drop policy if exists "creators upload episode videos" on storage.objects;
create policy "creators upload episode videos"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'drama-videos'
    and (select app_private.is_creator())
    and exists (
      select 1 from public.episodes e
      where e.id::text = (storage.foldername(name))[1]
    )
  );

drop policy if exists "creators update episode videos" on storage.objects;
create policy "creators update episode videos"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'drama-videos' and (select app_private.is_creator()))
  with check (bucket_id = 'drama-videos' and (select app_private.is_creator()));

drop policy if exists "creators delete episode videos" on storage.objects;
create policy "creators delete episode videos"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'drama-videos' and (select app_private.is_creator()));

commit;
