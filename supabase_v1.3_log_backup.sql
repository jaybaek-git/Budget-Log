-- =====================================================================
--  가계부 v1.3 — 변경 기록 · 변경 알림 지연(묶어서 보내기) · 백업
--  · tx_log: 누가 언제 무엇을 추가/수정/삭제했는지 (앱 제목 아래 표시)
--  · live_pending: 변경 알림을 바로 보내지 않고 n분(설정 liveDelay, 기본 2) 기다렸다가
--    그 사이 같은 사람의 변경을 한 번에 묶어 상대방 폰으로 보냄 (새 변경이 오면 다시 n분)
--  · backups: 매일 03:00 자동 + 수동 백업, 복원 (복원 직전 상태도 자동 백업)
-- =====================================================================
create table if not exists public.tx_log (id bigserial primary key, at timestamptz not null default now(),
  who text, action text not null, summary text, tx_id uuid);
create index if not exists tx_log_at_idx on public.tx_log (at desc);
create table if not exists public.live_pending (id bigserial primary key, who text, line text not null,
  created_at timestamptz not null default now(), due_at timestamptz not null);
create table if not exists public.backups (id bigserial primary key, at timestamptz not null default now(),
  kind text, n int, data jsonb not null);
alter table public.tx_log enable row level security;
alter table public.live_pending enable row level security;
alter table public.backups enable row level security;
revoke all on public.tx_log, public.live_pending, public.backups from anon, authenticated;

-- 기록 한 줄 요약: 🍽️ 식비·배달 12,000원 (쿠팡이츠)
create or replace function public._tx_text(r public.tx) returns text
language plpgsql stable security definer set search_path = public as $$
declare c jsonb := _cat(r.cat);
begin
  return trim(coalesce(c->>'emoji', '') || ' ' || coalesce(c->>'name', r.cat) || coalesce('·' || r.sub, ''))
         || ' ' || case when r.kind = 'in' then '+' else '' end || _won(r.amount) || coalesce(' (' || r.memo || ')', '');
end $$;

-- 변경 알림 보내기 (기한 지난 것, 사람별로 묶어서)
create or replace function public._flush_live() returns int
language plpgsql security definer set search_path = public as $$
declare g record; n int := 0;
begin
  for g in
    select who, array_agg(line order by id) lines, array_agg(id) ids from live_pending
     group by who having max(due_at) <= now()
  loop
    perform _push(
      case when cardinality(g.lines) = 1 then '✏️ ' || coalesce(g.who, '누군가') || ' · 가계부 변경'
           else '✏️ ' || coalesce(g.who, '누군가') || ' · 가계부 ' || cardinality(g.lines) || '건 변경' end,
      array_to_string(g.lines[1:4], E'\n') || case when cardinality(g.lines) > 4 then E'\n외 ' || (cardinality(g.lines) - 4) || '건' else '' end,
      'live', g.who);
    delete from live_pending where id = any(g.ids);
    n := n + 1;
  end loop;
  return n;
end $$;

-- 변경 기록 + 알림 예약
create or replace function public._log(p_who text, p_action text, p_summary text, p_tx uuid default null, p_notify bool default true) returns void
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; v_delay int;
begin
  insert into tx_log (who, action, summary, tx_id) values (nullif(p_who, ''), p_action, p_summary, p_tx);
  delete from tx_log where at < now() - interval '120 days';
  if not p_notify or coalesce(current_setting('budgetlog.quiet', true), '') = '1' then return; end if;
  select data into cfg from app_config where id = 1;
  if coalesce((cfg->>'liveNotify')::bool, true) = false then return; end if;
  v_delay := greatest(0, least(60, coalesce((cfg->>'liveDelay')::int, 2)));
  insert into live_pending (who, line, due_at)
  values (nullif(p_who, ''), case p_action when 'add' then '추가 ' when 'edit' then '수정 ' when 'del' then '삭제 ' else '' end || p_summary,
          now() + make_interval(mins => v_delay));
  -- 같은 사람이 이어서 바꾸면 기다리는 시간을 다시 시작 (한 번에 묶어 보냄)
  update live_pending set due_at = now() + make_interval(mins => v_delay) where who is not distinct from nullif(p_who, '');
  if v_delay = 0 then perform _flush_live(); end if;
end $$;
revoke execute on function public._tx_text(public.tx), public._flush_live(), public._log(text, text, text, uuid, bool) from public, anon, authenticated;

-- 트리거는 예산 알림만 (기록 알림은 _log 가 담당)
create or replace function public._tx_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; v_month date; v_out bigint; v_budget bigint; v_lvl int; v_prev int;
begin
  if coalesce(current_setting('budgetlog.quiet', true), '') = '1' then return new; end if;
  select data into cfg from app_config where id = 1;
  v_month := _kst_month(new.at);
  if v_month <> _kst_month() then return new; end if;
  v_out := _month_out(v_month);
  v_budget := nullif((cfg->'budget'->>'total')::bigint, 0);
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

-- ── 내역 RPC: 누가 바꿨는지(p_by) 기록 ───────────────────────────────
create or replace function public.add_tx(p_code text, p_kind text, p_amount bigint, p_cat text,
  p_at timestamptz default null, p_memo text default null, p_by text default null, p_sub text default null)
returns public.tx language plpgsql security definer set search_path = public as $$
declare r tx;
begin
  perform _chk(p_code);
  insert into tx (kind, amount, cat, sub, at, memo, created_by)
  values (coalesce(p_kind, 'out'), p_amount, p_cat, nullif(p_sub, ''), coalesce(p_at, now()), nullif(p_memo, ''), nullif(p_by, ''))
  returning * into r;
  perform _log(p_by, 'add', to_char(r.at at time zone 'Asia/Seoul', 'MM/DD') || ' ' || _tx_text(r), r.id);
  return r;
end $$;

drop function if exists public.update_tx(text, uuid, text, bigint, text, timestamptz, text, text);
create or replace function public.update_tx(p_code text, p_id uuid, p_kind text, p_amount bigint, p_cat text,
  p_at timestamptz, p_memo text default null, p_sub text default null, p_by text default null)
returns public.tx language plpgsql security definer set search_path = public as $$
declare r tx; o tx;
begin
  perform _chk(p_code);
  select * into o from tx where id = p_id;
  update tx set kind = p_kind, amount = p_amount, cat = p_cat, sub = nullif(p_sub, ''), at = p_at, memo = nullif(p_memo, '')
   where id = p_id returning * into r;
  if r.id is not null then
    perform _log(p_by, 'edit', to_char(r.at at time zone 'Asia/Seoul', 'MM/DD') || ' ' || _tx_text(r)
      || case when o.amount <> r.amount then ' (원래 ' || _won(o.amount) || ')' else '' end, r.id);
  end if;
  return r;
end $$;

drop function if exists public.delete_tx(text, uuid);
create or replace function public.delete_tx(p_code text, p_id uuid, p_by text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r tx;
begin
  perform _chk(p_code);
  delete from tx where id = p_id returning * into r;
  if r.id is not null then
    if r.fixed_id is not null and r.fixed_month is not null then
      insert into fixed_skip (fixed_id, month) values (r.fixed_id, r.fixed_month) on conflict do nothing;
    end if;
    perform _log(p_by, 'del', to_char(r.at at time zone 'Asia/Seoul', 'MM/DD') || ' ' || _tx_text(r), r.id);
  end if;
end $$;

create or replace function public.import_tx(p_code text, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _chk(p_code);
  perform set_config('budgetlog.quiet', '1', true);
  insert into tx (kind, amount, cat, sub, at, memo, created_by)
  select coalesce(r->>'kind', 'out'), (r->>'amount')::bigint, r->>'cat', nullif(r->>'sub', ''), (r->>'at')::timestamptz,
         nullif(r->>'memo', ''), nullif(r->>'created_by', '')
    from jsonb_array_elements(p_rows) r;
  get diagnostics n = row_count;
  perform _log(p_rows->0->>'created_by', 'import', n || '건 한꺼번에 가져옴', null, false);
  return n;
end $$;

-- 고정 설정 변경도 기록 (save_fixed 는 v1.2 와 같고 마지막에 기록만 추가)
create or replace function public.save_fixed(p_code text, p_id uuid, p_kind text, p_amount bigint, p_cat text, p_sub text,
  p_day int, p_memo text, p_start date, p_end date, p_active bool default true, p_by text default null)
returns public.fixed language plpgsql security definer set search_path = public as $$
declare r fixed; m date := _kst_month(); c jsonb;
begin
  perform _chk(p_code);
  if p_id is null then
    insert into fixed (kind, amount, cat, sub, day, memo, active, created_by, start_month, end_month)
    values (coalesce(p_kind, 'out'), p_amount, p_cat, nullif(p_sub, ''), p_day, nullif(p_memo, ''), coalesce(p_active, true),
            nullif(p_by, ''), date_trunc('month', coalesce(p_start, m))::date, date_trunc('month', p_end)::date)
    returning * into r;
  else
    update fixed set kind = p_kind, amount = p_amount, cat = p_cat, sub = nullif(p_sub, ''), day = p_day, memo = nullif(p_memo, ''),
                     active = coalesce(p_active, true), start_month = date_trunc('month', coalesce(p_start, start_month, m))::date,
                     end_month = date_trunc('month', p_end)::date
     where id = p_id returning * into r;
    c := _cat(r.cat);
    update tx set kind = r.kind, amount = r.amount, cat = r.cat, sub = r.sub, memo = coalesce(r.memo, c->>'name'),
                  at = (_fixed_date(r.day, m) + time '09:00') at time zone 'Asia/Seoul'
     where fixed_id = r.id and fixed_month = m;
    if not _fixed_on(r, m) then delete from tx where fixed_id = r.id and fixed_month = m; end if;
  end if;
  perform _run_fixed(m, true);
  c := _cat(r.cat);
  perform _log(p_by, 'fixed', '🔁 고정 ' || case when p_id is null then '추가 ' else '변경 ' end || coalesce(r.memo, c->>'name') || ' '
    || _won(r.amount) || ' · 매달 ' || case when r.day >= 31 then '말일' else r.day || '일' end
    || coalesce(' · ~' || to_char(r.end_month, 'YY.MM'), ''), null);
  return r;
end $$;

create or replace function public.delete_fixed(p_code text, p_id uuid, p_by text default null) returns void
language plpgsql security definer set search_path = public as $$
declare r fixed;
begin
  perform _chk(p_code);
  select * into r from fixed where id = p_id;
  delete from tx where fixed_id = p_id and at > now();
  update tx set fixed_id = null where fixed_id = p_id;
  delete from fixed_skip where fixed_id = p_id;
  delete from fixed where id = p_id;
  if r.id is not null then perform _log(p_by, 'fixed', '🔁 고정 삭제 ' || coalesce(r.memo, r.cat) || ' ' || _won(r.amount), null); end if;
end $$;
drop function if exists public.delete_fixed(text, uuid);

create or replace function public.recent_log(p_code text, p_limit int default 30)
returns setof public.tx_log language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  return query select * from tx_log order by at desc limit greatest(1, least(200, p_limit));
end $$;

-- ── 백업 ─────────────────────────────────────────────────────────────
create or replace function public._take_backup(p_kind text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; n int;
begin
  select count(*) into n from tx;
  insert into backups (kind, n, data) values (p_kind, n, jsonb_build_object(
    'tx', coalesce((select jsonb_agg(to_jsonb(t)) from tx t), '[]'),
    'fixed', coalesce((select jsonb_agg(to_jsonb(f)) from fixed f), '[]'),
    'fixed_skip', coalesce((select jsonb_agg(to_jsonb(s)) from fixed_skip s), '[]'),
    'config', (select data from app_config where id = 1)))
  returning id into v_id;
  -- 자동 백업은 최근 30개, 나머지(수동·복원 전)는 최근 20개만 보관
  delete from backups where kind = '자동' and id not in (select id from backups where kind = '자동' order by at desc limit 30);
  delete from backups where kind <> '자동' and id not in (select id from backups where kind <> '자동' order by at desc limit 20);
  return v_id;
end $$;
revoke execute on function public._take_backup(text) from public, anon, authenticated;

create or replace function public.backup_now(p_code text, p_by text default null) returns bigint
language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  perform _chk(p_code);
  v := _take_backup('수동');
  perform _log(p_by, 'backup', '💾 수동 백업', null, false);
  return v;
end $$;

create or replace function public.list_backups(p_code text)
returns table (id bigint, at timestamptz, kind text, n int)
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  return query select b.id, b.at, b.kind, b.n from backups b order by b.at desc;
end $$;

create or replace function public.restore_backup(p_code text, p_id bigint, p_by text default null) returns int
language plpgsql security definer set search_path = public as $$
declare d jsonb; n int;
begin
  perform _chk(p_code);
  select data into d from backups where id = p_id;
  if d is null then raise exception 'backup not found'; end if;
  perform _take_backup('복원 전');
  perform set_config('budgetlog.quiet', '1', true);
  delete from tx; delete from fixed_skip; delete from fixed;
  insert into fixed select * from jsonb_populate_recordset(null::fixed, d->'fixed');
  insert into tx select * from jsonb_populate_recordset(null::tx, d->'tx');
  insert into fixed_skip select * from jsonb_populate_recordset(null::fixed_skip, d->'fixed_skip');
  if d->'config' is not null and d->'config' <> 'null'::jsonb then update app_config set data = d->'config' where id = 1; end if;
  select count(*) into n from tx;
  perform _log(p_by, 'restore', '♻️ 백업 복원 (' || to_char((select at from backups where id = p_id) at time zone 'Asia/Seoul', 'MM/DD HH24:MI') || ', ' || n || '건)', null, false);
  return n;
end $$;

grant execute on function
  public.update_tx(text, uuid, text, bigint, text, timestamptz, text, text, text),
  public.delete_tx(text, uuid, text),
  public.delete_fixed(text, uuid, text),
  public.recent_log(text, int),
  public.backup_now(text, text), public.list_backups(text), public.restore_backup(text, bigint, text)
to anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname in ('budget-log-live', 'budget-log-backup');
select cron.schedule('budget-log-live', '* * * * *', 'select public._flush_live()');
select cron.schedule('budget-log-backup', '0 18 * * *', $$select public._take_backup('자동')$$);   -- 매일 03:00 KST

notify pgrst, 'reload schema';

-- 월별 합계 (통계 '월별 추이' 좌우 스크롤용)
create or replace function public.month_totals(p_code text)
returns table (m date, out_sum bigint, in_sum bigint, fixed_sum bigint, n int)
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  return query
    select date_trunc('month', t.at at time zone 'Asia/Seoul')::date,
           coalesce(sum(t.amount) filter (where t.kind = 'out'), 0)::bigint,
           coalesce(sum(t.amount) filter (where t.kind = 'in'), 0)::bigint,
           coalesce(sum(t.amount) filter (where t.kind = 'out' and t.fixed_id is not null), 0)::bigint,
           count(*)::int
      from tx t group by 1 order by 1;
end $$;
grant execute on function public.month_totals(text) to anon, authenticated;
notify pgrst, 'reload schema';
