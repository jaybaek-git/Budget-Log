-- =====================================================================
--  가계부 v1.2 — 고정지출 개편
--  · 이번 달 고정지출은 날짜가 아직 안 와도 미리 기록 (앱에서 '예정' 표시)
--  · 시작달/종료달(언제까지), 세부 항목
--  · 이번 달 기록을 지우면 그 달만 건너뜀 (fixed_skip)
--  · save_fixed = "이번 달부터 계속" 변경 (이번 달 기록도 함께 수정)
--    "이번 달만" 변경은 앱이 update_tx 로 그 달 기록만 고침
-- =====================================================================
alter table public.fixed add column if not exists sub text;
alter table public.fixed add column if not exists start_month date;
alter table public.fixed add column if not exists end_month date;
update public.fixed set start_month = coalesce(start_month, date_trunc('month', created_at at time zone 'Asia/Seoul')::date);

alter table public.tx add column if not exists fixed_month date;
update public.tx set fixed_month = date_trunc('month', at at time zone 'Asia/Seoul')::date where fixed_id is not null and fixed_month is null;
create unique index if not exists tx_fixed_once on public.tx (fixed_id, fixed_month) where fixed_id is not null;

create table if not exists public.fixed_skip (fixed_id uuid not null, month date not null, primary key (fixed_id, month));
alter table public.fixed_skip enable row level security;
revoke all on public.fixed_skip from anon, authenticated;

create or replace function public._fixed_on(f public.fixed, m date) returns bool language sql immutable as $$
  select f.active and coalesce(f.start_month, m) <= m and (f.end_month is null or f.end_month >= m) $$;

drop function if exists public._run_fixed();
-- 해당 달(기본: 이번 달)의 고정 항목을 날짜와 상관없이 모두 기록. 이미 있거나 건너뛴 달은 제외.
create or replace function public._run_fixed(p_month date default null, p_quiet bool default false) returns int
language plpgsql security definer set search_path = public as $$
declare f fixed; m date := coalesce(p_month, _kst_month()); n int := 0; tot bigint := 0; c jsonb;
begin
  for f in select * from fixed order by day loop
    continue when not _fixed_on(f, m);
    continue when exists (select 1 from tx where fixed_id = f.id and fixed_month = m)
               or exists (select 1 from fixed_skip where fixed_id = f.id and month = m);
    c := _cat(f.cat);
    insert into tx (kind, amount, cat, sub, at, memo, created_by, fixed_id, fixed_month)
    values (f.kind, f.amount, f.cat, f.sub, (_fixed_date(f.day, m) + time '09:00') at time zone 'Asia/Seoul',
            coalesce(f.memo, c->>'name'), '자동', f.id, m);
    n := n + 1; if f.kind = 'out' then tot := tot + f.amount; end if;
  end loop;
  if n > 0 and not p_quiet then
    perform _push('🔁 ' || extract(month from m) || '월 고정지출 ' || n || '건 등록', '합계 ' || _won(tot) || ' (날짜가 안 된 건 예정으로 표시돼요)', 'fixed');
  end if;
  return n;
end $$;
revoke execute on function public._run_fixed(date, bool) from public, anon, authenticated;

drop function if exists public.save_fixed(text, uuid, text, bigint, text, int, text, bool, text);
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
    -- 이번 달 기록도 함께 수정 (이번 달부터 적용)
    c := _cat(r.cat);
    update tx set kind = r.kind, amount = r.amount, cat = r.cat, sub = r.sub, memo = coalesce(r.memo, c->>'name'),
                  at = (_fixed_date(r.day, m) + time '09:00') at time zone 'Asia/Seoul'
     where fixed_id = r.id and fixed_month = m;
    -- 이번 달이 기간 밖이 되면 이번 달 기록 삭제
    if not _fixed_on(r, m) then delete from tx where fixed_id = r.id and fixed_month = m; end if;
  end if;
  perform _run_fixed(m, true);
  return r;
end $$;

-- 고정 항목 삭제: 오늘 이후 '예정' 기록도 함께 삭제, 지난 기록은 남김
create or replace function public.delete_fixed(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  delete from tx where fixed_id = p_id and at > now();
  update tx set fixed_id = null where fixed_id = p_id;
  delete from fixed_skip where fixed_id = p_id;
  delete from fixed where id = p_id;
end $$;

-- 고정 기록을 지우면 그 달은 건너뛴 것으로 표시 (다시 생기지 않게)
create or replace function public.delete_tx(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare r tx;
begin
  perform _chk(p_code);
  delete from tx where id = p_id returning * into r;
  if r.fixed_id is not null and r.fixed_month is not null then
    insert into fixed_skip (fixed_id, month) values (r.fixed_id, r.fixed_month) on conflict do nothing;
  end if;
end $$;

-- 건너뛴 달 되살리기
create or replace function public.unskip_fixed(p_code text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  delete from fixed_skip where fixed_id = p_id and month = _kst_month();
  perform _run_fixed(_kst_month(), true);
end $$;

drop function if exists public.list_fixed(text);
create or replace function public.list_fixed(p_code text)
returns table (id uuid, kind text, amount bigint, cat text, sub text, day int, memo text, active bool,
               start_month date, end_month date, skipped bool)
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  return query select f.id, f.kind, f.amount, f.cat, f.sub, f.day, f.memo, f.active, f.start_month, f.end_month,
    exists (select 1 from fixed_skip s where s.fixed_id = f.id and s.month = _kst_month())
    from fixed f order by f.day, f.created_at;
end $$;

grant execute on function
  public.save_fixed(text, uuid, text, bigint, text, text, int, text, date, date, bool, text),
  public.unskip_fixed(text, uuid),
  public.list_fixed(text)
to anon, authenticated;

-- 매일 00:05 (KST): 새 달이 되면 그 달 고정지출을 한꺼번에 기록
select cron.unschedule(jobid) from cron.job where jobname = 'budget-log-fixed';
select cron.schedule('budget-log-fixed', '5 15 * * *', 'select public._run_fixed()');

notify pgrst, 'reload schema';
