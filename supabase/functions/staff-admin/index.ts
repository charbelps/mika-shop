// Edge Function: staff-admin (Phase 1c, A3)
// The admin Staff screen calls it to manage staff logins. Creating a login or setting a
// password needs Supabase's secret key, which must never be in the browser, so it lives here.
//
// Every call must come from a logged-in, ACTIVE ADMIN (checked from the caller's own token).
// Actions (POST JSON { action, ... }):
//   list                                   -> staff with email + last sign-in
//   create { email, name, role, password } -> new login + staff row (rolled back if either fails)
//   update { user_id, name?, role?, active? }
//   reset_password { user_id, password }
// Safety: nobody can deactivate / demote themselves, the last active ADMIN stays (the database
// trigger staff_guard enforces the same rules), passwords are at least 8 characters.
// Deactivated people are also blocked from signing in (ban), reactivating lifts it.
//
// Provided automatically by Supabase: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
// Deployed WITH JWT verification (the default): calls without a valid login never reach this code.

import { createClient } from 'npm:@supabase/supabase-js@2.117.2';

const URL_ = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ROLES = ['ADMIN', 'OWNER', 'DRIVER'];
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const fail = (code: string, status = 400) => reply(status, { error: code });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return fail('POST_ONLY', 405);

  const admin = createClient(URL_, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

  // ---- who is calling? must be an active ADMIN ----
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  const { data: who, error: whoErr } = await admin.auth.getUser(token);
  if (whoErr || !who?.user) return fail('NOT_LOGGED_IN', 401);
  const me = who.user.id;
  const { data: meRow } = await admin.from('staff').select('role,active').eq('user_id', me).maybeSingle();
  if (!meRow || !meRow.active || meRow.role !== 'ADMIN') return fail('ONLY_ADMIN', 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return fail('BAD_JSON'); }
  const action = String(body.action ?? '');
  if (!['list', 'create', 'update', 'reset_password'].includes(action)) return fail('UNKNOWN_ACTION');

  // remaining active admins other than `id`
  const otherAdmins = async (id: string) => {
    const { count } = await admin.from('staff').select('user_id', { count: 'exact', head: true })
      .eq('role', 'ADMIN').eq('active', true).neq('user_id', id);
    return count ?? 0;
  };

  try {
    if (action === 'list') {
      const { data: staff, error } = await admin.from('staff').select('user_id,name,role,active,created_at').order('created_at');
      if (error) throw error;
      const { data: users, error: uErr } = await admin.auth.admin.listUsers({ perPage: 1000 });
      if (uErr) throw uErr;
      const byId = new Map(users.users.map((u) => [u.id, u]));
      return reply(200, {
        me,
        staff: staff.map((s) => ({
          ...s,
          email: byId.get(s.user_id)?.email ?? '',
          last_sign_in_at: byId.get(s.user_id)?.last_sign_in_at ?? null,
        })),
      });
    }

    if (action === 'create') {
      const email = String(body.email ?? '').trim().toLowerCase();
      const name = String(body.name ?? '').trim();
      const role = String(body.role ?? '');
      const password = String(body.password ?? '');
      if (!EMAIL_RE.test(email) || email.length > 200) return fail('BAD_EMAIL');
      if (!name || name.length > 60) return fail('BAD_NAME');
      if (!ROLES.includes(role)) return fail('BAD_ROLE');
      if (password.length < 8 || password.length > 72) return fail('BAD_PASSWORD');
      const { data: created, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
      if (error) return fail(/already|exists|registered/i.test(error.message) ? 'EMAIL_EXISTS' : 'CREATE_FAILED');
      const { error: sErr } = await admin.from('staff').insert({ user_id: created.user.id, name, role });
      if (sErr) {
        await admin.auth.admin.deleteUser(created.user.id); // undo: no login without a staff row
        return fail('CREATE_FAILED');
      }
      return reply(200, { ok: true, user_id: created.user.id });
    }

    const userId = String(body.user_id ?? '');
    const { data: target } = await admin.from('staff').select('user_id,name,role,active').eq('user_id', userId).maybeSingle();
    if (!target) return fail('NOT_FOUND', 404);

    if (action === 'update') {
      const patch: Record<string, unknown> = {};
      if (body.name !== undefined) {
        const name = String(body.name).trim();
        if (!name || name.length > 60) return fail('BAD_NAME');
        patch.name = name;
      }
      if (body.role !== undefined) {
        if (!ROLES.includes(String(body.role))) return fail('BAD_ROLE');
        patch.role = String(body.role);
      }
      if (body.active !== undefined) patch.active = body.active === true;
      const losingAdmin = target.role === 'ADMIN' && target.active
        && ((patch.role !== undefined && patch.role !== 'ADMIN') || patch.active === false);
      if (losingAdmin && userId === me) return fail('CANNOT_CHANGE_SELF');
      if (losingAdmin && (await otherAdmins(userId)) === 0) return fail('LAST_ADMIN');
      if (!Object.keys(patch).length) return reply(200, { ok: true });
      const { error } = await admin.from('staff').update(patch).eq('user_id', userId);
      if (error) return fail(/LAST_ADMIN|CANNOT_CHANGE_SELF/.exec(error.message)?.[0] ?? 'UPDATE_FAILED');
      if (patch.active !== undefined && patch.active !== target.active) {
        // deactivated people can't sign in any more; reactivating lifts the block
        await admin.auth.admin.updateUserById(userId, { ban_duration: patch.active ? 'none' : '876000h' });
      }
      return reply(200, { ok: true });
    }

    if (action === 'reset_password') {
      const password = String(body.password ?? '');
      if (password.length < 8 || password.length > 72) return fail('BAD_PASSWORD');
      const { error } = await admin.auth.admin.updateUserById(userId, { password });
      if (error) return fail('UPDATE_FAILED');
      return reply(200, { ok: true });
    }

    return fail('UNKNOWN_ACTION');
  } catch (e) {
    console.error(e);
    return fail('SERVER_ERROR', 500);
  }
});
