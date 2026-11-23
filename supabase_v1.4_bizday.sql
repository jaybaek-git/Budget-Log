-- =====================================================================
--  가계부 v1.4 — 고정지출: 주말·공휴일이면 다음 영업일에 기록 (항목별 선택)
--  공휴일: 우주항공청 월력요항 기준 2026~2027 (대체공휴일·제헌절·노동절·지방선거 포함)
--  해마다 6월 말 다음 해 월력요항이 나오면 holidays 에 추가
-- =====================================================================
create table if not exists public.holidays (d date primary key, name text);
alter table public.holidays enable row level security;
revoke all on public.holidays from anon, authenticated;
insert into public.holidays (d, name) values
 ('2026-01-01','신정'),('2026-02-16','설날 연휴'),('2026-02-17','설날'),('2026-02-18','설날 연휴'),('2026-03-01','삼일절'),('2026-03-02','대체공휴일(삼일절)'),
 ('2026-05-01','노동절'),('2026-05-05','어린이날'),('2026-05-24','부처님오신날'),('2026-05-25','대체공휴일(부처님오신날)'),('2026-06-03','지방선거'),('2026-06-06','현충일'),
 ('2026-07-17','제헌절'),('2026-08-15','광복절'),('2026-08-17','대체공휴일(광복절)'),('2026-09-24','추석 연휴'),('2026-09-25','추석'),('2026-09-26','추석 연휴'),
 ('2026-10-03','개천절'),('2026-10-05','대체공휴일(개천절)'),('2026-10-09','한글날'),('2026-12-25','성탄절'),
 ('2027-01-01','신정'),('2027-02-06','설날 연휴'),('2027-02-07','설날'),('2027-02-08','설날 연휴'),('2027-02-09','대체공휴일(설날)'),('2027-03-01','삼일절'),
 ('2027-05-01','노동절'),('2027-05-03','대체공휴일(노동절)'),('2027-05-05','어린이날'),('2027-05-13','부처님오신날'),('2027-06-06','현충일'),
 ('2027-07-17','제헌절'),('2027-07-19','대체공휴일(제헌절)'),('2027-08-15','광복절'),('2027-08-16','대체공휴일(광복절)'),
 ('2027-09-14','추석 연휴'),('2027-09-15','추석'),('2027-09-16','추석 연휴'),('2027-10-03','개천절'),('2027-10-04','대체공휴일(개천절)'),
 ('2027-10-09','한글날'),('2027-10-11','대체공휴일(한글날)'),('2027-12-25','성탄절'),('2027-12-27','대체공휴일(성탄절)')
on conflict (d) do update set name = excluded.name;

alter table public.fixed add column if not exists business_day bool not null default false;

-- 다음 영업일 (주말·공휴일이면 하루씩 뒤로)
create or replace function public._next_bizday(p date) returns date language plpgsql stable set search_path = public as $$
declare v date := p;
begin
  while extract(isodow from v) in (6, 7) or exists (select 1 from holidays h where h.d = v) loop v := v + 1; end loop;
  return v;
end $$;
-- 그 달 고정 항목의 실제 기록일
create or replace function public._fixed_day(f public.fixed, m date) returns date language sql stable set search_path = public as $$
  select case when f.business_day then _next_bizday(_fixed_date(f.day, m)) else _fixed_date(f.day, m) end $$;

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
    values (f.kind, f.amount, f.cat, f.sub, (_fixed_day(f, m) + time '09:00') at time zone 'Asia/Seoul',
            coalesce(f.memo, c->>'name'), '자동', f.id, m);
    n := n + 1; if f.kind = 'out' then tot := tot + f.amount; end if;
  end loop;
  if n > 0 and not p_quiet then
    perform _push('🔁 ' || extract(month from m) || '월 고정지출 ' || n || '건 등록', '합계 ' || _won(tot) || ' (날짜가 안 된 건 예정으로 표시돼요)', 'fixed');
  end if;
  return n;
end $$;
revoke execute on function public._run_fixed(date, bool) from public, anon, authenticated;

drop function if exists public.save_fixed(text, uuid, text, bigint, text, text, int, text, date, date, bool, text);
create or replace function public.save_fixed(p_code text, p_id uuid, p_kind text, p_amount bigint, p_cat text, p_sub text,
  p_day int, p_memo text, p_start date, p_end date, p_active bool default true, p_by text default null, p_biz bool default null)
returns public.fixed language plpgsql security definer set search_path = public as $$
declare r fixed; m date := _kst_month(); c jsonb;
begin
  perform _chk(p_code);
  if p_id is null then
    insert into fixed (kind, amount, cat, sub, day, memo, active, created_by, start_month, end_month, business_day)
    values (coalesce(p_kind, 'out'), p_amount, p_cat, nullif(p_sub, ''), p_day, nullif(p_memo, ''), coalesce(p_active, true),
            nullif(p_by, ''), date_trunc('month', coalesce(p_start, m))::date, date_trunc('month', p_end)::date, coalesce(p_biz, false))
    returning * into r;
  else
    update fixed set kind = p_kind, amount = p_amount, cat = p_cat, sub = nullif(p_sub, ''), day = p_day, memo = nullif(p_memo, ''),
                     active = coalesce(p_active, true), start_month = date_trunc('month', coalesce(p_start, start_month, m))::date,
                     end_month = date_trunc('month', p_end)::date, business_day = coalesce(p_biz, business_day)
     where id = p_id returning * into r;
    c := _cat(r.cat);
    update tx set kind = r.kind, amount = r.amount, cat = r.cat, sub = r.sub, memo = coalesce(r.memo, c->>'name'),
                  at = (_fixed_day(r, m) + time '09:00') at time zone 'Asia/Seoul'
     where fixed_id = r.id and fixed_month = m;
    if not _fixed_on(r, m) then delete from tx where fixed_id = r.id and fixed_month = m; end if;
  end if;
  perform _run_fixed(m, true);
  c := _cat(r.cat);
  perform _log(p_by, 'fixed', '🔁 고정 ' || case when p_id is null then '추가 ' else '변경 ' end || coalesce(r.memo, c->>'name') || ' '
    || _won(r.amount) || ' · 매달 ' || case when r.day >= 31 then '말일' else r.day || '일' end
    || case when r.business_day then '(영업일)' else '' end
    || coalesce(' · ~' || to_char(r.end_month, 'YY.MM'), ''), null);
  return r;
end $$;

drop function if exists public.list_fixed(text);
create or replace function public.list_fixed(p_code text)
returns table (id uuid, kind text, amount bigint, cat text, sub text, day int, memo text, active bool,
               start_month date, end_month date, skipped bool, business_day bool)
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  return query select f.id, f.kind, f.amount, f.cat, f.sub, f.day, f.memo, f.active, f.start_month, f.end_month,
    exists (select 1 from fixed_skip s where s.fixed_id = f.id and s.month = _kst_month()), f.business_day
    from fixed f order by f.day, f.created_at;
end $$;

-- 공휴일 목록 (앱 달력 표시용)
create or replace function public.list_holidays(p_code text)
returns setof public.holidays language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); return query select * from holidays order by d; end $$;

grant execute on function
  public.save_fixed(text, uuid, text, bigint, text, text, int, text, date, date, bool, text, bool),
  public.list_fixed(text), public.list_holidays(text)
to anon, authenticated;
notify pgrst, 'reload schema';
