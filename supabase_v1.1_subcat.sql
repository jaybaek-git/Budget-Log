-- =====================================================================
--  가계부 v1.1 — 세부 항목(sub) 추가
--  v1.0 SQL을 실행한 프로젝트에 이어서 실행하세요.
--  (카테고리 목록 자체는 앱이 app_config 에 저장합니다)
-- =====================================================================
alter table public.tx add column if not exists sub text;

drop function if exists public.add_tx(text, text, bigint, text, timestamptz, text, text);
drop function if exists public.update_tx(text, uuid, text, bigint, text, timestamptz, text);

create or replace function public.add_tx(p_code text, p_kind text, p_amount bigint, p_cat text,
  p_at timestamptz default null, p_memo text default null, p_by text default null, p_sub text default null)
returns public.tx language plpgsql security definer set search_path = public as $$
declare r tx;
begin
  perform _chk(p_code);
  insert into tx (kind, amount, cat, sub, at, memo, created_by)
  values (coalesce(p_kind, 'out'), p_amount, p_cat, nullif(p_sub, ''), coalesce(p_at, now()), nullif(p_memo, ''), nullif(p_by, ''))
  returning * into r;
  return r;
end $$;

create or replace function public.update_tx(p_code text, p_id uuid, p_kind text, p_amount bigint, p_cat text,
  p_at timestamptz, p_memo text default null, p_sub text default null)
returns public.tx language plpgsql security definer set search_path = public as $$
declare r tx;
begin
  perform _chk(p_code);
  update tx set kind = p_kind, amount = p_amount, cat = p_cat, sub = nullif(p_sub, ''), at = p_at, memo = nullif(p_memo, '')
   where id = p_id returning * into r;
  return r;
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
  return n;
end $$;

-- 알림 제목에 세부 항목 표시 (예: 🍽️ 식비·배달)
create or replace function public._tx_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; c jsonb; v_month date; v_out bigint; v_budget bigint; v_lvl int; v_prev int; v_body text;
begin
  if coalesce(current_setting('budgetlog.quiet', true), '') = '1' then return new; end if;
  select data into cfg from app_config where id = 1;
  v_month := _kst_month(new.at);
  if v_month <> _kst_month() then return new; end if;
  v_out := _month_out(v_month);
  v_budget := nullif((cfg->'budget'->>'total')::bigint, 0);

  if new.fixed_id is null and coalesce((cfg->>'liveNotify')::bool, true) then
    c := _cat(new.cat);
    v_body := coalesce(new.memo || ' · ', '') || '이번 달 지출 ' || _won(v_out)
              || coalesce(' · 예산 ' || case when v_budget >= v_out then _won(v_budget - v_out) || ' 남음'
                                           else _won(v_out - v_budget) || ' 초과' end, '');
    perform _push(
      case when new.kind = 'in' then '💰 ' else '💸 ' end || coalesce(new.created_by, '누군가') || ' · '
        || trim(coalesce(c->>'emoji', '') || ' ' || coalesce(c->>'name', new.cat) || coalesce('·' || new.sub, ''))
        || ' ' || _won(new.amount),
      v_body, 'tx', new.created_by);
  end if;

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

grant execute on function
  public.add_tx(text, text, bigint, text, timestamptz, text, text, text),
  public.update_tx(text, uuid, text, bigint, text, timestamptz, text, text)
to anon, authenticated;

notify pgrst, 'reload schema';
