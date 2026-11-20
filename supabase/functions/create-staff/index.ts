// create-staff: I use this so the Super Admin can add a staff login from the admin site.
// It runs on Supabase's server, so the secret service key never reaches the website.
import { createClient } from 'npm:@supabase/supabase-js@2'

// These headers let the admin website (a different web address) call this function.
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// I use this to send an answer back to the website as JSON.
function reply(body: unknown, status: number = 200) {
  return new Response(JSON.stringify(body), {
    status: status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  // The browser first asks "may I call you?" (an OPTIONS request). I say yes.
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: cors })
  }

  try {
    // My server-only connection, using the secret key (never in the website).
    const url = Deno.env.get('SUPABASE_URL')!
    const secretKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const admin = createClient(url, secretKey)

    // Step 1. Who is calling? They must be an active Super Admin.
    // 1a. Read their login token ("Bearer abc123..." -> "abc123...").
    let token = req.headers.get('Authorization')
    if (token === null) {
      token = ''
    }
    token = token.replace('Bearer ', '')

    // 1b. Is the token a real, signed-in user?
    const userResult = await admin.auth.getUser(token)
    const user = userResult.data.user
    if (!user) {
      return reply({ error: 'Please sign in again.' }, 401)
    }

    // 1c. Look up their staff row.
    const meResult = await admin
      .from('admin_accounts')
      .select('role, is_active')
      .eq('auth_user_id', user.id)
      .maybeSingle()
    const me = meResult.data

    // 1d. Not staff, turned off, or not a Super Admin? Refuse.
    if (!me) {
      return reply({ error: 'Only the Super Admin can add staff.' }, 403)
    }
    if (!me.is_active) {
      return reply({ error: 'Only the Super Admin can add staff.' }, 403)
    }
    if (me.role !== 'super_admin') {
      return reply({ error: 'Only the Super Admin can add staff.' }, 403)
    }

    // Step 2. Check the form.
    const form = await req.json()
    const name = form.name
    const email = form.email
    const password = form.password
    const role = form.role

    // 2a. Name, email and temporary password must all be filled in.
    if (!name || !email || !password) {
      return reply({ error: 'Name, email and temporary password are required.' }, 400)
    }

    // 2b. The role must be one of our three.
    const allowedRoles = ['super_admin', 'staff_admin', 'field_staff']
    if (!allowedRoles.includes(role)) {
      return reply({ error: 'Unknown role.' }, 400)
    }

    // Step 3. Create the login (already confirmed, so no email is needed).
    const createResult = await admin.auth.admin.createUser({
      email: email,
      password: password,
      email_confirm: true,
    })
    if (createResult.error) {
      return reply({ error: createResult.error.message }, 400)
    }
    const newUserId = createResult.data.user.id

    // Step 4. Give the login its staff row and role.
    const insertResult = await admin
      .from('admin_accounts')
      .insert({ auth_user_id: newUserId, name: name, role: role })

    // If that fails, I remove the login again, so nothing is half-made.
    if (insertResult.error) {
      await admin.auth.admin.deleteUser(newUserId)
      return reply({ error: insertResult.error.message }, 400)
    }

    return reply({ ok: true })
  } catch (_e) {
    // Anything unexpected (for example, a broken form).
    return reply({ error: 'Something went wrong. Please try again.' }, 500)
  }
})
