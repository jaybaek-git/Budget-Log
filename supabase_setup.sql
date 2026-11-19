-- =====================================================================
--  가계부 (Budget-Log) v1.0 — Supabase 설정 SQL
--  새 Supabase 프로젝트 → SQL Editor → 붙여넣기 → Run
--  ★ 아래 'CHANGE-ME…' 가족 코드와 <PROJECT_ID> 를 바꾸세요.
--  ★ 실제 가족 코드·VAPID 개인키는 저장소(공개)에 올리지 마세요.
-- =====================================================================
create extension if not exists pgcrypto;
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- ── 테이블 ────────────────────────────────────────────────────────────
create table if not exists public.tx (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null default 'out' check (kind in ('out','in')),  -- 지출 / 수입
  amount      bigint not null check (amount >= 0),                        -- 원
  cat         text not null,                                              -- 카테고리 id
  at          timestamptz not null default now(),
  memo        text,
  created_by  text,
  fixed_id    uuid,                                                       -- 고정지출 자동 기록이면 원본 id
  created_at  timestamptz not null default now()
);
create index if not exists tx_at_idx on public.tx (at);

create table if not exists public.fixed (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null default 'out' check (kind in ('out','in')),
  amount     bigint not null check (amount >= 0),
  cat        text not null,
  day        int  not null check (day between 1 and 31),   -- 매달 n일 (말일보다 크면 말일)
  memo       text,
  active     bool not null default true,
  last_month date,                                         -- 마지막으로 기록한 달(1일)
  created_by text,
  created_at timestamptz not null default now()
);

create table if not exists public.app_config (id int primary key default 1 check (id = 1), data jsonb);
create table if not exists public.app_secret (id int primary key default 1 check (id = 1), code text not null,
  vapid_public text, vapid_private text);
create table if not exists public.app_state  (id int primary key default 1 check (id = 1), edge_url text,
  budget_alert_month date, budget_alert_level int default 0);
create table if not exists public.push_subs  (endpoint text primary key, sub jsonb not null, who text,
  created_at timestamptz not null default now());
create table if not exists public.push_queue (id bigserial primary key, title text not null, body text, tag text,
  exclude_who text, created_at timestamptz not null default now(), sent_at timestamptz);

-- 직접 접근 금지 → 아래 RPC(가족 코드 확인)로만 접근
alter table public.tx         enable row level security;
alter table public.fixed      enable row level security;
alter table public.app_config enable row level security;
alter table public.app_secret enable row level security;
alter table public.app_state  enable row level security;
alter table public.push_subs  enable row level security;
alter table public.push_queue enable row level security;
revoke all on public.tx, public.fixed, public.app_config, public.app_secret, public.app_state,
  public.push_subs, public.push_queue from anon, authenticated;
grant all on public.push_subs, public.push_queue, public.app_secret to service_role;
grant usage, select on sequence public.push_queue_id_seq to service_role;

-- ★ 가족 코드 / 알림 함수 주소
insert into public.app_secret (id, code) values (1, 'CHANGE-ME-우리집-가계부-코드')
on conflict (id) do update set code = excluded.code;
insert into public.app_state (id, edge_url) values (1, 'https://<PROJECT_ID>.supabase.co/functions/v1/push')
on conflict (id) do update set edge_url = excluded.edge_url;

-- ── 공통 ──────────────────────────────────────────────────────────────
create or replace function public._chk(p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_code is null or not exists (select 1 from app_secret where code = p_code) then
    raise exception 'invalid family code';
  end if;
end $$;

create or replace function public._won(n numeric) returns text language sql immutable as $$
  select case when n < 0 then '-' else '' end || trim(to_char(abs(n), 'FM999,999,999,999')) || '원' $$;

create or replace function public._kst_month(t timestamptz default now()) returns date language sql stable as $$
  select date_trunc('month', t at time zone 'Asia/Seoul')::date $$;

create or replace function public._cat(p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select x from app_config c, jsonb_array_elements(coalesce(c.data->'cats','[]'::jsonb)) x
                    where c.id = 1 and x->>'id' = p_id limit 1), jsonb_build_object('id', p_id, 'name', p_id, 'emoji', '')) $$;

create or replace function public._month_out(p_month date) returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0)::bigint from tx
   where kind = 'out' and at >= (p_month::timestamp at time zone 'Asia/Seoul')
     and at < ((p_month + interval '1 month')::timestamp at time zone 'Asia/Seoul') $$;

create or replace function public._push(p_title text, p_body text, p_tag text, p_exclude text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_url text;
begin
  select edge_url into v_url from app_state where id = 1;
  insert into push_queue (title, body, tag, exclude_who) values (p_title, p_body, p_tag, nullif(p_exclude, ''));
  if v_url is not null and position('<' in v_url) = 0 then   -- 주소를 아직 안 바꿨으면 큐에만 넣음
    perform net.http_post(url := v_url, body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb);
  end if;
end $$;

revoke execute on function public._chk(text), public._cat(text), public._month_out(date),
  public._push(text, text, text, text) from public, anon, authenticated;

-- ── 내역 RPC ──────────────────────────────────────────────────────────
create or replace function public.add_tx(p_code text, p_kind text, p_amount bigint, p_cat text,
  p_at timestamptz default null, p_memo text default null, p_by text default null)
returns public.tx language plpgsql security definer set search_path = public as $$
declare r tx;
begin
  perform _chk(p_code);
  insert into tx (kind, amount, cat, at, memo, created_by)
  values (coalesce(p_kind, 'out'), p_amount, p_cat, coalesce(p_at, now()), nullif(p_memo, ''), nullif(p_by, ''))
  returning * into r;
  return r;
end $$;

create or replace function public.update_tx(p_code text, p_id uuid, p_kind text, p_amount bigint, p_cat text,
  p_at timestamptz, p_memo text default null)
returns public.tx language plpgsql security definer set search_path = public as $$
declare r tx;
begin
  perform _chk(p_code);
  update tx set kind = p_kind, amount = p_amount, cat = p_cat, at = p_at, memo = nullif(p_memo, '')
   where id = p_id returning * into r;
  return r;
end $$;

create or replace function public.delete_tx(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); delete from tx where id = p_id; end $$;

create or replace function public.list_tx(p_code text, p_from timestamptz, p_to timestamptz)
returns setof public.tx language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  return query select * from tx where at >= p_from and at < p_to order by at desc, created_at desc;
end $$;

create or replace function public.import_tx(p_code text, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _chk(p_code);
  perform set_config('budgetlog.quiet', '1', true);   -- 가져오기는 알림 없음
  insert into tx (kind, amount, cat, at, memo, created_by)
  select coalesce(r->>'kind', 'out'), (r->>'amount')::bigint, r->>'cat', (r->>'at')::timestamptz,
         nullif(r->>'memo', ''), nullif(r->>'created_by', '')
    from jsonb_array_elements(p_rows) r;
  get diagnostics n = row_count;
  return n;
end $$;

-- ── 설정 RPC ──────────────────────────────────────────────────────────
create or replace function public.get_config(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); return (select data from app_config where id = 1); end $$;

create or replace function public.set_config(p_code text, p_data jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  insert into app_config (id, data) values (1, p_data) on conflict (id) do update set data = excluded.data;
end $$;

-- ── 고정지출 ──────────────────────────────────────────────────────────
-- 이번 달 기록일 (31일 설정 → 30일까지인 달은 30일)
create or replace function public._fixed_date(p_day int, p_month date) returns date language sql immutable as $$
  select p_month + (least(p_day, extract(day from (p_month + interval '1 month - 1 day'))::int) - 1) $$;

-- 기록할 날이 지났고 이번 달에 아직 안 했으면 기록 (매일 00:05 KST + 저장 직후 실행)
create or replace function public._run_fixed() returns int
language plpgsql security definer set search_path = public as $$
declare f fixed; v_month date := _kst_month(); v_today date := (now() at time zone 'Asia/Seoul')::date;
        v_d date; n int := 0; c jsonb;
begin
  for f in select * from fixed where active and (last_month is null or last_month < v_month) order by day loop
    v_d := _fixed_date(f.day, v_month);
    continue when v_d > v_today;
    insert into tx (kind, amount, cat, at, memo, created_by, fixed_id)
    values (f.kind, f.amount, f.cat, (v_d + time '09:00') at time zone 'Asia/Seoul', f.memo, '자동', f.id);
    update fixed set last_month = v_month where id = f.id;
    c := _cat(f.cat);
    perform _push('🔁 고정' || case when f.kind = 'in' then '수입' else '지출' end || ' 자동 기록',
      coalesce(c->>'emoji', '') || ' ' || coalesce(f.memo, c->>'name') || ' ' || _won(f.amount), 'fixed');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke execute on function public._run_fixed() from public, anon, authenticated;

create or replace function public.list_fixed(p_code text) returns setof public.fixed
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); return query select * from fixed order by day, created_at; end $$;

-- p_id 가 null 이면 새로 추가. 새 항목의 날짜가 이번 달에 이미 지났으면 다음 달부터 기록.
create or replace function public.save_fixed(p_code text, p_id uuid, p_kind text, p_amount bigint, p_cat text,
  p_day int, p_memo text default null, p_active bool default true, p_by text default null)
returns public.fixed language plpgsql security definer set search_path = public as $$
declare r fixed; v_month date := _kst_month();
begin
  perform _chk(p_code);
  if p_id is null then
    insert into fixed (kind, amount, cat, day, memo, active, created_by, last_month)
    values (coalesce(p_kind, 'out'), p_amount, p_cat, p_day, nullif(p_memo, ''), coalesce(p_active, true), nullif(p_by, ''),
            case when _fixed_date(p_day, v_month) < (now() at time zone 'Asia/Seoul')::date then v_month end)
    returning * into r;
  else
    update fixed set kind = p_kind, amount = p_amount, cat = p_cat, day = p_day, memo = nullif(p_memo, ''),
                     active = coalesce(p_active, true)
     where id = p_id returning * into r;
  end if;
  perform _run_fixed();
  select * into r from fixed where id = r.id;
  return r;
end $$;

create or replace function public.delete_fixed(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); delete from fixed where id = p_id; end $$;

-- ── 알림: 상대방 기록 + 예산 80%/100% ────────────────────────────────
create or replace function public._tx_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; c jsonb; v_month date; v_out bigint; v_budget bigint; v_lvl int; v_prev int; v_body text;
begin
  if coalesce(current_setting('budgetlog.quiet', true), '') = '1' then return new; end if;
  select data into cfg from app_config where id = 1;
  v_month := _kst_month(new.at);
  if v_month <> _kst_month() then return new; end if;              -- 지난달 기록 정리는 알림 없음
  v_out := _month_out(v_month);
  v_budget := nullif((cfg->'budget'->>'total')::bigint, 0);

  -- 상대방 기록 알림 (자동 기록은 _run_fixed 가 따로 알림)
  if new.fixed_id is null and coalesce((cfg->>'liveNotify')::bool, true) then
    c := _cat(new.cat);
    v_body := coalesce(new.memo || ' · ', '') || '이번 달 지출 ' || _won(v_out)
              || coalesce(' · 예산 ' || case when v_budget >= v_out then _won(v_budget - v_out) || ' 남음'
                                           else _won(v_out - v_budget) || ' 초과' end, '');
    perform _push(
      case when new.kind = 'in' then '💰 ' else '💸 ' end || coalesce(new.created_by, '누군가') || ' · '
        || trim(coalesce(c->>'emoji', '') || ' ' || coalesce(c->>'name', new.cat)) || ' ' || _won(new.amount),
      v_body, 'tx', new.created_by);
  end if;

  -- 예산 단계 알림 (두 폰 모두)
  if new.kind = 'out' and v_budget is not null and coalesce((cfg->'budget'->>'alert')::bool, true) then
    v_lvl := case when v_out >= v_budget then 100 when v_out >= v_budget * 0.8 then 80 else 0 end;
    select case when budget_alert_month = v_month then budget_alert_level else 0 end into v_prev from app_state where id = 1;
    if v_lvl > coalesce(v_prev, 0) then
      update app_state set budget_alert_month = v_month, budget_alert_level = v_lvl where id = 1;
      perform _push(case when v_lvl = 100 then '🚨 이번 달 예산을 다 썼어요' else '⚠️ 이번 달 예산 80% 사용' end,
        _won(v_out) || ' / ' || _won(v_budget), 'budget');
    end if;
  end if;
  return new;
end $$;
revoke execute on function public._tx_notify() from public, anon, authenticated;
drop trigger if exists trg_tx_notify on public.tx;
create trigger trg_tx_notify after insert on public.tx for each row execute function public._tx_notify();

-- ── 웹 푸시 등록 ──────────────────────────────────────────────────────
create or replace function public.save_push_sub(p_code text, p_sub jsonb, p_who text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  insert into push_subs (endpoint, sub, who) values (p_sub->>'endpoint', p_sub, p_who)
  on conflict (endpoint) do update set sub = excluded.sub, who = excluded.who;
end $$;

create or replace function public.delete_push_sub(p_code text, p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); delete from push_subs where endpoint = p_endpoint; end $$;

create or replace function public.get_vapid_public(p_code text) returns text
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); return (select vapid_public from app_secret where id = 1); end $$;

create or replace function public.test_push(p_code text, p_by text default null) returns void
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); perform _push('🔔 테스트 알림', coalesce(p_by || ' ', '') || '알림이 잘 와요!', 'test'); end $$;

grant execute on function
  public.add_tx(text, text, bigint, text, timestamptz, text, text),
  public.update_tx(text, uuid, text, bigint, text, timestamptz, text),
  public.delete_tx(text, uuid),
  public.list_tx(text, timestamptz, timestamptz),
  public.import_tx(text, jsonb),
  public.get_config(text), public.set_config(text, jsonb),
  public.list_fixed(text),
  public.save_fixed(text, uuid, text, bigint, text, int, text, bool, text),
  public.delete_fixed(text, uuid),
  public.save_push_sub(text, jsonb, text), public.delete_push_sub(text, text),
  public.get_vapid_public(text), public.test_push(text, text)
to anon, authenticated;

-- 매일 00:05 (KST) 고정지출 기록
select cron.unschedule(jobid) from cron.job where jobname = 'budget-log-fixed';
select cron.schedule('budget-log-fixed', '5 15 * * *', 'select public._run_fixed()');

notify pgrst, 'reload schema';
