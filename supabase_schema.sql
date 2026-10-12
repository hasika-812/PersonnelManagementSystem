-- ============================================================
--  Personnel Management System — Supabase / PostgreSQL Schema
--  Version 4
--
--  HOW TO USE:
--  Paste this entire file into Supabase Dashboard → SQL Editor
--  and click Run.  It is safe to run on a completely fresh
--  Supabase project with no existing tables.
--
--  This file has been reviewed for logical correctness.
--  It has NOT been executed against a live Supabase project.
--  Treat your first run as the integration test and check the
--  SQL Editor output for errors before continuing to SETUP.md.
-- ============================================================


-- ============================================================
-- SECTION 0 — SAFE RE-RUN GUARDS
--
--   We must drop triggers before re-creating their functions,
--   but on a FRESH project the tables do not exist yet, so
--   plain DROP TRIGGER statements would abort the whole script.
--
--   Solution: wrap each drop in an anonymous DO block that
--   catches the "relation does not exist" error and continues.
--   This is safe on both a fresh project and an existing one.
-- ============================================================

DO $$ BEGIN
    DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$ BEGIN
    DROP TRIGGER IF EXISTS employees_updated_at ON public.employees;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;

DO $$ BEGIN
    DROP TRIGGER IF EXISTS leave_requests_updated_at ON public.leave_requests;
EXCEPTION WHEN undefined_table THEN NULL;
END $$;


-- ============================================================
-- SECTION 1 — ROLE-CHECK HELPER FUNCTION
--
--   RLS policies on the `profiles` table cannot safely subquery
--   `profiles` in their own USING / WITH CHECK expressions —
--   PostgreSQL recurses infinitely and throws a stack-depth
--   error.
--
--   This SECURITY DEFINER function runs as the database owner,
--   bypasses RLS, and reads the caller's role without recursion.
--   Every admin-check policy calls get_my_role() instead of
--   querying profiles directly.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT role
    FROM   public.profiles
    WHERE  id = auth.uid()
    LIMIT  1;
$$;

REVOKE EXECUTE ON FUNCTION public.get_my_role() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_my_role() TO authenticated;


-- ============================================================
-- SECTION 2 — PROFILES TABLE
--
--   Exactly one row per Auth user (auth.users row).
--   The FK enforces this: profiles.id must exist in auth.users.
--
--   role        = 'admin' | 'employee'
--   employee_id = text Employee ID (e.g. "EMP001"); NULL for admin
--
--   NOTE — no invite_token column here.
--   In v3 the invite token was stored in profiles using a random
--   placeholder UUID as the row's primary key.  That violated
--   the FK constraint (profiles.id → auth.users.id) and caused
--   an immediate foreign-key error when admin created an employee.
--
--   The invite token is now stored in employees.invite_token
--   (added in Section 3).  The profiles table contains only
--   rows whose id exists in auth.users.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.profiles (
    id           UUID        PRIMARY KEY
                             REFERENCES auth.users(id) ON DELETE CASCADE,
    role         TEXT        NOT NULL
                             CHECK (role IN ('admin', 'employee')),
    employee_id  TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- ── SELECT ───────────────────────────────────────────────────

DROP POLICY IF EXISTS "profiles_select_own"   ON public.profiles;
CREATE POLICY "profiles_select_own"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id);

DROP POLICY IF EXISTS "profiles_select_admin" ON public.profiles;
CREATE POLICY "profiles_select_admin"
    ON public.profiles FOR SELECT
    USING (public.get_my_role() = 'admin');

-- ── INSERT ───────────────────────────────────────────────────
-- Only admins can insert profile rows directly (e.g. promoting
-- the first admin via the SQL command in Section 9).
-- The handle_new_user() trigger (SECURITY DEFINER) is exempt
-- from RLS and inserts new-user rows without needing this policy.
-- claim_employee_account() (SECURITY DEFINER) is also exempt.

DROP POLICY IF EXISTS "profiles_insert_admin"    ON public.profiles;
DROP POLICY IF EXISTS "profiles_insert_self_emp" ON public.profiles;

CREATE POLICY "profiles_insert_admin"
    ON public.profiles FOR INSERT
    WITH CHECK (public.get_my_role() = 'admin');

-- ── UPDATE ───────────────────────────────────────────────────
-- Only admins may update profile rows.
-- Employees cannot change their role or any other profile field.

DROP POLICY IF EXISTS "profiles_update_admin" ON public.profiles;
CREATE POLICY "profiles_update_admin"
    ON public.profiles FOR UPDATE
    USING  (public.get_my_role() = 'admin')
    WITH CHECK (public.get_my_role() = 'admin');

-- ── DELETE ───────────────────────────────────────────────────
-- Rows are deleted automatically via ON DELETE CASCADE when the
-- Auth user is deleted.  Admins may also delete rows explicitly.

DROP POLICY IF EXISTS "profiles_delete_admin" ON public.profiles;
CREATE POLICY "profiles_delete_admin"
    ON public.profiles FOR DELETE
    USING (public.get_my_role() = 'admin');


-- ============================================================
-- SECTION 3 — EMPLOYEES TABLE
--
--   invite_token is stored here, not in profiles.
--
--   Rationale:
--   - employees has no FK that requires a matching auth.users row,
--     so a token can exist before the employee's Auth account.
--   - The token and the employee record it authenticates belong
--     together naturally.
--   - Storing the token in profiles required a placeholder row
--     whose id violated the profiles → auth.users FK.
--
--   Lifecycle of invite_token:
--   - Set to a random hex string by admin when creating the employee.
--   - Verified and set to NULL by claim_employee_account() when the
--     employee activates their account.
--   - NULL means the account has been claimed or the employee was
--     added without the invite flow.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.employees (
    id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id  UUID          UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    employee_id   TEXT          NOT NULL UNIQUE,
    name          TEXT          NOT NULL,
    email         TEXT          NOT NULL UNIQUE,
    department    TEXT          NOT NULL,
    designation   TEXT          NOT NULL,
    salary        NUMERIC(12,2) NOT NULL CHECK (salary >= 0),
    invite_token  TEXT,
    is_active     BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

-- ── Timestamp trigger helper ──────────────────────────────────

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER employees_updated_at
    BEFORE UPDATE ON public.employees
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ── Indexes ───────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_employees_employee_id
    ON public.employees(employee_id);
CREATE INDEX IF NOT EXISTS idx_employees_auth_user_id
    ON public.employees(auth_user_id);

-- ── RLS ───────────────────────────────────────────────────────

ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;

-- Admins: full access to all rows and all columns.
DROP POLICY IF EXISTS "employees_all_admin" ON public.employees;
CREATE POLICY "employees_all_admin"
    ON public.employees FOR ALL
    USING     (public.get_my_role() = 'admin')
    WITH CHECK (public.get_my_role() = 'admin');

-- Employees: read only their own row.
-- An employee cannot see any other employee's salary, department,
-- or any other field.
DROP POLICY IF EXISTS "employees_select_own" ON public.employees;
CREATE POLICY "employees_select_own"
    ON public.employees FOR SELECT
    USING (auth_user_id = auth.uid());

-- No INSERT / UPDATE / DELETE policy for employees.
-- Employees cannot create, modify, or delete employee records.
-- All claiming goes through claim_employee_account() which is
-- SECURITY DEFINER and bypasses RLS.


-- ============================================================
-- SECTION 4 — ATTENDANCE TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS public.attendance (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id_fk UUID        NOT NULL
                               REFERENCES public.employees(id) ON DELETE CASCADE,
    date           DATE        NOT NULL,
    status         TEXT        NOT NULL
                               CHECK (status IN ('Present', 'Absent', 'Leave')),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (employee_id_fk, date)
);

CREATE INDEX IF NOT EXISTS idx_attendance_employee
    ON public.attendance(employee_id_fk);
CREATE INDEX IF NOT EXISTS idx_attendance_date
    ON public.attendance(date);

ALTER TABLE public.attendance ENABLE ROW LEVEL SECURITY;

-- Admins: full access.
DROP POLICY IF EXISTS "attendance_all_admin" ON public.attendance;
CREATE POLICY "attendance_all_admin"
    ON public.attendance FOR ALL
    USING     (public.get_my_role() = 'admin')
    WITH CHECK (public.get_my_role() = 'admin');

-- Employees: read only their own records.
-- No INSERT / UPDATE / DELETE for employees.
DROP POLICY IF EXISTS "attendance_select_own" ON public.attendance;
CREATE POLICY "attendance_select_own"
    ON public.attendance FOR SELECT
    USING (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
    );


-- ============================================================
-- SECTION 5 — LEAVE REQUESTS TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS public.leave_requests (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id_fk UUID        NOT NULL
                               REFERENCES public.employees(id) ON DELETE CASCADE,
    start_date     DATE        NOT NULL,
    end_date       DATE        NOT NULL,
    reason         TEXT        NOT NULL,
    status         TEXT        NOT NULL DEFAULT 'Pending'
                               CHECK (status IN ('Pending', 'Approved', 'Rejected')),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT leave_date_order CHECK (end_date >= start_date)
);

CREATE TRIGGER leave_requests_updated_at
    BEFORE UPDATE ON public.leave_requests
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE INDEX IF NOT EXISTS idx_leave_requests_employee
    ON public.leave_requests(employee_id_fk);
CREATE INDEX IF NOT EXISTS idx_leave_requests_status
    ON public.leave_requests(status);

ALTER TABLE public.leave_requests ENABLE ROW LEVEL SECURITY;

-- Admins: full access (view, approve, reject, delete).
DROP POLICY IF EXISTS "leave_all_admin" ON public.leave_requests;
CREATE POLICY "leave_all_admin"
    ON public.leave_requests FOR ALL
    USING     (public.get_my_role() = 'admin')
    WITH CHECK (public.get_my_role() = 'admin');

-- Employees: read only their own requests.
DROP POLICY IF EXISTS "leave_select_own" ON public.leave_requests;
CREATE POLICY "leave_select_own"
    ON public.leave_requests FOR SELECT
    USING (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
    );

-- Employees: submit new requests only.
--   1. employee_id_fk must map to the caller's own employee row —
--      an employee cannot submit on behalf of someone else.
--   2. status must be 'Pending' on insert — employees cannot
--      self-approve or insert an already-Approved request.
DROP POLICY IF EXISTS "leave_insert_own" ON public.leave_requests;
CREATE POLICY "leave_insert_own"
    ON public.leave_requests FOR INSERT
    WITH CHECK (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
        AND status = 'Pending'
    );

-- No UPDATE or DELETE for employees.
-- Employees cannot change status, withdraw, or delete requests.
-- Absence of a policy means the operation is denied by RLS.


-- ============================================================
-- SECTION 6 — GRANTS
-- ============================================================

GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.employees      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.attendance     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.leave_requests TO authenticated;

-- The anon role is used by the Supabase JS client before login.
-- It does not need table-level access; auth.getSession() goes
-- through the Auth API, not the public schema.
-- No table grants to anon.


-- ============================================================
-- SECTION 7 — NEW USER TRIGGER
--
--   Fires after every INSERT on auth.users, which happens when:
--     (a) An employee registers via register.html (signUp).
--     (b) The admin account is created in the Supabase UI.
--
--   The trigger inserts a profiles row with role = 'employee'
--   as the safe default for every new user.
--
--   For the admin account, the manual SQL in Section 9 Step C
--   promotes that row using ON CONFLICT (id) DO UPDATE.
--
--   For employee accounts created via register.html, the row
--   inserted here is the correct final row — claim_employee_
--   account() then sets employee_id on it and clears the token
--   from the employees table.
--
--   ON CONFLICT DO NOTHING:
--   Safe because auth.users.id is unique.  If the trigger fires
--   twice for the same UUID (e.g. due to a retry), the second
--   attempt is silently ignored.
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.profiles (id, role)
    VALUES (NEW.id, 'employee')
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ============================================================
-- SECTION 8 — EMPLOYEE ACCOUNT CLAIM FUNCTION
--
--   Called from register.html after the employee has signed up
--   with auth.signUp().  Links the new Auth account to the
--   pre-existing employee record created by the admin.
--
--   PARAMETERS:
--     p_employee_id  — the text Employee ID, e.g. "EMP001"
--     p_invite_token — the token admin showed in the UI
--
--   SECURITY PROPERTIES:
--
--   1. Uses auth.uid() from the JWT — not a caller-supplied UUID.
--      A forged UUID in the request cannot impersonate anyone.
--
--   2. Restricted to authenticated callers only (GRANT below).
--      Anonymous callers cannot execute this function.
--
--   3. Verifies the caller's JWT email against employees.email.
--      Even if an attacker obtains another employee's token,
--      they cannot claim that account because their JWT email
--      (from their own signUp) will not match.
--
--   4. Uses SELECT ... FOR UPDATE to lock the employees row
--      before any writes, preventing a race condition where two
--      concurrent requests with the same token both succeed.
--
--   5. Verifies auth_user_id IS NULL before proceeding.
--      A second claim attempt on the same employee is rejected.
--
--   6. Verifies the invite_token is non-NULL and correct.
--      The token is stored in employees, not profiles.
--
--   7. All writes are in the same transaction.  Any failure
--      rolls back all changes — no partial state is left.
--
--   8. The profiles row inserted here always has role = 'employee'.
--      The caller cannot self-promote to admin.
--
--   9. Only auth_user_id in employees and employee_id in profiles
--      are written.  Salary, department, designation and other
--      protected fields are never touched.
-- ============================================================

CREATE OR REPLACE FUNCTION public.claim_employee_account(
    p_employee_id  TEXT,
    p_invite_token TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_caller_id    UUID;
    v_caller_email TEXT;
    v_employee_row public.employees%ROWTYPE;
BEGIN
    -- ── 0. Identify the caller via the JWT ───────────────────
    v_caller_id := auth.uid();

    IF v_caller_id IS NULL THEN
        RETURN jsonb_build_object(
            'error', 'You must be signed in to activate an account.'
        );
    END IF;

    -- ── 1. Read the caller's verified email from auth.users ──
    --   SECURITY DEFINER allows access to the auth schema here.
    SELECT lower(email)
    INTO   v_caller_email
    FROM   auth.users
    WHERE  id = v_caller_id;

    IF v_caller_email IS NULL THEN
        RETURN jsonb_build_object(
            'error', 'Could not verify your email. Please sign in again.'
        );
    END IF;

    -- ── 2. Lock the employee row ──────────────────────────────
    --   FOR UPDATE serialises concurrent claim attempts.
    --   The second request waits until the first commits, then
    --   sees auth_user_id IS NOT NULL and is rejected in step 3.
    SELECT *
    INTO   v_employee_row
    FROM   public.employees
    WHERE  employee_id = p_employee_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'Employee ID not found.');
    END IF;

    -- ── 3. Reject if already claimed ─────────────────────────
    IF v_employee_row.auth_user_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'error', 'This account has already been activated. '
                  || 'Please sign in on the login page.'
        );
    END IF;

    -- ── 4. Verify the caller's email matches ─────────────────
    --   This is the anti-impersonation check.
    --   The employee signed up with their work email; admin stored
    --   that same email in employees.email.  They must match.
    IF lower(v_employee_row.email) != v_caller_email THEN
        RETURN jsonb_build_object(
            'error', 'The email address you registered with does not '
                  || 'match the email on file for this Employee ID.'
        );
    END IF;

    -- ── 5. Verify the invite token is present ────────────────
    IF v_employee_row.invite_token IS NULL THEN
        RETURN jsonb_build_object(
            'error', 'No pending invitation found for this Employee ID.'
        );
    END IF;

    -- ── 6. Verify the invite token is correct ────────────────
    --   Compared here after the email check so token enumeration
    --   is blocked by the email mismatch error on step 4.
    IF v_employee_row.invite_token != p_invite_token THEN
        RETURN jsonb_build_object('error', 'Invalid invite token.');
    END IF;

    -- ── 7. Link the Auth user to the employee record ─────────
    --   Consume the token by setting it to NULL — single use.
    UPDATE public.employees
    SET    auth_user_id  = v_caller_id,
           invite_token  = NULL
    WHERE  id            = v_employee_row.id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Failed to link employee record (id = %).',
            v_employee_row.id;
    END IF;

    -- ── 8. Update the profiles row with the employee_id ──────
    --   handle_new_user() already inserted a profiles row with
    --   id = v_caller_id and role = 'employee' when signUp() ran.
    --   We only need to set employee_id on that existing row.
    UPDATE public.profiles
    SET    employee_id = p_employee_id
    WHERE  id          = v_caller_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profiles row missing for user id = %.',
            v_caller_id;
    END IF;

    RETURN jsonb_build_object('success', true);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLERRM);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_employee_account(TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.claim_employee_account(TEXT, TEXT) TO authenticated;


-- ============================================================
-- SECTION 9 — CREATE THE FIRST ADMIN ACCOUNT
--
--   Run ALL steps AFTER the schema above has been applied.
-- ============================================================

/*
──────────────────────────────────────────────────────────────
STEP A — Disable email confirmation  (do this first, in UI)
──────────────────────────────────────────────────────────────
  Supabase Dashboard → Authentication → Settings
  → Turn OFF "Enable email confirmations"
  → Save

  Skipping this means every new account (including the admin)
  must click a confirmation email before logging in.
  For a college demo, turn this off.

──────────────────────────────────────────────────────────────
STEP B — Create the admin Auth user  (in UI)
──────────────────────────────────────────────────────────────
  Authentication → Users → Add user
  Email    : admin@pms.local  (or any email you prefer)
  Password : (strong password — write it down)
  → Create user

  handle_new_user() fires automatically and inserts:
      profiles row: id = <admin UUID>, role = 'employee'

──────────────────────────────────────────────────────────────
STEP C — Promote the admin profile  (in SQL Editor)
──────────────────────────────────────────────────────────────
  Copy the UUID shown in Authentication → Users, then run
  this exact SQL (replace the UUID):

      INSERT INTO public.profiles (id, role)
      VALUES ('<paste-uuid-here>', 'admin')
      ON CONFLICT (id) DO UPDATE SET role = 'admin';

  CRITICAL: use DO UPDATE SET role = 'admin', NOT DO NOTHING.
  The trigger already inserted role = 'employee'.
  DO NOTHING silently keeps that value — the admin would see
  the employee dashboard instead of the admin dashboard.

  Verify:
      SELECT id, role FROM public.profiles WHERE role = 'admin';
  Expected: exactly one row.

──────────────────────────────────────────────────────────────
STEP D — Test admin login
──────────────────────────────────────────────────────────────
  Open login.html, sign in with the admin credentials.
  Expected: admin dashboard with stat cards and navigation.

──────────────────────────────────────────────────────────────
STEP E — Add an employee  (in the app, as admin)
──────────────────────────────────────────────────────────────
  Admin → Add Employee → fill in all fields → Add Employee.
  A popup shows the one-time invite token.  Write it down.
  The employee row is saved with invite_token set and
  auth_user_id = NULL (account not yet activated).

──────────────────────────────────────────────────────────────
STEP F — Employee activates their account  (register.html)
──────────────────────────────────────────────────────────────
  Employee opens register.html and enters:
    Employee ID    : exactly as admin entered it
    Email address  : exactly as admin entered it
    Invite Token   : the token from the admin popup
    New Password   : at least 8 characters
    Confirm Password

  What happens on the server:
    1. signUp() creates an auth.users row and starts a session.
    2. handle_new_user() inserts: profiles(id=<uuid>, role='employee').
    3. rpc("claim_employee_account") runs:
         - Reads auth.uid() from the JWT (not the browser).
         - Reads the caller's email from auth.users.
         - Verifies email matches employees.email for that Employee ID.
         - Verifies the invite token.
         - Sets employees.auth_user_id = auth.uid().
         - Sets employees.invite_token = NULL (consumed).
         - Sets profiles.employee_id = the Employee ID.
    4. signOut() clears the session.
  Employee is redirected to login.html.

──────────────────────────────────────────────────────────────
STEP G — Employee logs in  (login.html)
──────────────────────────────────────────────────────────────
  Employee enters their email and password.
  initApp() reads their profiles row → role = 'employee'.
  Employee dashboard loads with their profile and attendance.

──────────────────────────────────────────────────────────────
STEP H — Verify isolation  (manual check)
──────────────────────────────────────────────────────────────
  While logged in as an employee, open the browser DevTools
  console and run:
      supabase — not directly accessible from console, but
  you can verify via the Supabase Table Editor:
  Authentication → Log in as employee (impersonate) or use
  the Table Editor with the employee's JWT to confirm that
  querying employees returns only their own row, and
  leave_requests returns only their own requests.
*/

-- ============================================================
-- END OF SCHEMA
-- ============================================================
