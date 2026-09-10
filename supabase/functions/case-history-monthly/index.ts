import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

async function rpc(name: string, args: Record<string, unknown>) {
  const result = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: SUPABASE_SERVICE_ROLE_KEY,
      authorization: `Bearer ${SUPABASE_SERVICE_ROLE_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(args),
  });
  if (!result.ok) {
    throw new Error(`${name} ${result.status}: ${(await result.text()).slice(0, 500)}`);
  }
  const text = await result.text();
  return text ? JSON.parse(text) : null;
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return response({ ok: false, error: "POST only" }, 405);
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return response({ ok: false, error: "Supabase service configuration missing" }, 500);
  }

  try {
    const authorized = await rpc("dashboard_case_history_authorize", {
      p_secret: request.headers.get("x-case-history-secret") || "",
    });
    if (authorized !== true) return response({ ok: false, error: "unauthorized" }, 401);
  } catch {
    return response({ ok: false, error: "authorization unavailable" }, 503);
  }

  let body: Record<string, unknown>;
  try {
    body = await request.json();
  } catch {
    return response({ ok: false, error: "invalid json" }, 400);
  }

  const mode = typeof body.mode === "string" ? body.mode : "";
  try {
    if (mode === "versions") {
      return response({ ok: true, versions: await rpc("dashboard_line_monthly_versions", {
        p_site_no: body.site_no, p_period_start: body.period_start,
      }) });
    }
    if (mode === "publish") {
      return response(await rpc("dashboard_line_monthly_publish", {
        p_version_id: body.version_id, p_site_no: body.site_no, p_actor: body.actor,
      }));
    }
    if (mode === "prepare") {
      return response(await rpc("dashboard_line_monthly_prepare", {
        p_site_no: body.site_no,
        p_period_start: body.period_start,
        p_period_end: body.period_end,
        p_force: body.force === true,
      }));
    }
    if (mode === "commit") {
      return response(await rpc("dashboard_line_monthly_commit", {
        p_run_id: body.run_id,
        p_site_no: body.site_no,
        p_period_start: body.period_start,
        p_period_end: body.period_end,
        p_ai_model: body.ai_model,
        p_message_count: body.message_count,
        p_events: body.events,
        p_event_updates: body.event_updates,
        p_rollup: body.rollup,
      }));
    }
    if (mode === "fail") {
      await rpc("dashboard_line_monthly_fail", {
        p_run_id: body.run_id,
        p_error: body.error,
      });
      return response({ ok: true });
    }
    if (mode === "skip") {
      return response(await rpc("dashboard_line_monthly_skip", {
        p_run_id: body.run_id,
        p_error: body.error,
      }));
    }
    if (mode === "runs") {
      return response({ ok: true, runs: await rpc("dashboard_line_monthly_runs", {
        p_limit: body.limit,
      }) });
    }
    if (mode === "monitor") {
      const siteNos = Array.isArray(body.site_nos)
        ? body.site_nos.filter((value): value is string => typeof value === "string")
        : [];
      return response({ ok: true, projects: await rpc("dashboard_line_monthly_monitor", {
        p_site_nos: siteNos,
        p_period_start: body.period_start,
        p_period_end: body.period_end,
      }) });
    }
    return response({ ok: false, error: "unknown mode" }, 400);
  } catch (error) {
    return response({
      ok: false,
      error: String(error instanceof Error ? error.message : error).slice(0, 1000),
    }, 500);
  }
});
