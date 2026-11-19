// 가계부 — Supabase Edge Function "push"
// 대기 중인 알림(push_queue)을 등록된 모든 폰(push_subs)으로 보냅니다.
// 이 코드에는 비밀 값이 없습니다. VAPID 키는 DB(app_secret)에서 읽어요.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

Deno.serve(async () => {
  const { data: keys, error: kerr } = await sb.from("app_secret").select("vapid_public,vapid_private").eq("id", 1).single();
  if (kerr || !keys?.vapid_public || !keys?.vapid_private) return new Response("VAPID keys missing", { status: 500 });
  webpush.setVapidDetails("mailto:budget-log@example.com", keys.vapid_public, keys.vapid_private);

  const { data: queue } = await sb.from("push_queue").select("*").is("sent_at", null).order("id");
  if (!queue?.length) return new Response("nothing to send");
  const { data: subs } = await sb.from("push_subs").select("*");

  let sent = 0;
  for (const m of queue) {
    // 동시에 두 번 호출돼도 한 번만 보내도록 먼저 '보냄' 표시
    const { data: claimed } = await sb.from("push_queue").update({ sent_at: new Date().toISOString() })
      .eq("id", m.id).is("sent_at", null).select("id");
    if (!claimed?.length) continue;
    for (const s of (subs ?? []).filter((x) => !m.exclude_who || x.who !== m.exclude_who)) {
      try {
        await webpush.sendNotification(s.sub, JSON.stringify({ title: m.title, body: m.body, tag: m.tag }));
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) await sb.from("push_subs").delete().eq("endpoint", s.endpoint);
        console.error("push failed", code, String(e));
      }
    }
  }
  return new Response(`sent ${sent}`);
});
