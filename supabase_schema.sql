-- ============================================================
--  Personnel Management System — Supabase / PostgreSQL Schema
--  Version 5 — Installation-ready
--
--  Safe to run on:
--    • A completely fresh Supabase project (no tables yet).
--    • An existing project that has run any previous version
--      of this schema (v1–v4).
--
--  Paste the entire file into the Supabase SQL Editor and
--  click Run.  Read the output before continuing to SETUP.md.
--
--  This file has been reviewed for logical correctness.
--  It has NOT been executed against a live Supabase project.
--  Treat your first run as the integration test.
-- ============================================================


-- ============================================================
-- SECTION 0 — SAFE RE-RUN GUARDS
--
--   Triggers must be dropped before their backing functions are
--   replaced.  On a fresh project the target tables may not
--   exist yet — "DROP TRIGGER IF EXISTS ... ON table" still
--   errors when the *table* is missing even with IF EXISTS.
--
--   Each drop is wrapped in a DO block that catches the
--   undefined_table exception so the script continues cleanly
--   on both fresh and existing projects.
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
--   RLS policies on `profiles` cannot safely subquery `profiles`
--   in their own USING / WITH CHECK expressions — PostgreSQL
--   recurses infinitely and throws a stack-depth error.
--
--   This SECURITY DEFINER function runs as the database owner,
--   bypasses RLS, and reads the caller's role without recursion.
--   Every admin-check policy uses get_my_role() instead of
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
--   Exactly one row per Auth user.
--   profiles.id is a FK to auth.users(id) — every row must have
--   a matching auth.users row.  No placeholder UUIDs allowed.
--
--   role        = 'admin' | 'employee'
--   employee_id = text Employee ID (e.g. "EMP001"); NULL for admin
--
--   The invite_token lives in employees (Section 3), not here,
--   because employees has no FK back to auth.users so a token
--   can exist before the employee's Auth account is created.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.profiles (
    id           UUID        PRIMARY KEY
                             REFERENCES auth.users(id) ON DELETE CASCADE,
    role         TEXT        NOT NULL
                             CHECK (role IN ('admin', 'employee')),
    employee_id  TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- If profiles existed from a previous schema version that lacked
-- employee_id, add the column without touching existing rows.
ALTER TABLE public.profiles
    ADD COLUMN IF NOT EXISTS employee_id TEXT;

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
-- Only admins may insert profile rows directly (e.g. the admin
-- promotion step in Section 9 Step C).
-- handle_new_user() and claim_employee_account() are both
-- SECURITY DEFINER and are exempt from RLS.

DROP POLICY IF EXISTS "profiles_insert_admin"    ON public.profiles;
DROP POLICY IF EXISTS "profiles_insert_self_emp" ON public.profiles;

CREATE POLICY "profiles_insert_admin"
    ON public.profiles FOR INSERT
    WITH CHECK (public.get_my_role() = 'admin');

-- ── UPDATE ───────────────────────────────────────────────────
-- Only admins may update profile rows.
-- Employees cannot change their own role or employee_id.

DROP POLICY IF EXISTS "profiles_update_admin" ON public.profiles;
CREATE POLICY "profiles_update_admin"
    ON public.profiles FOR UPDATE
    USING  (public.get_my_role() = 'admin')
    WITH CHECK (public.get_my_role() = 'admin');

-- ── DELETE ───────────────────────────────────────────────────
-- Rows cascade-delete when the Auth user is deleted.
-- Admins may also delete rows explicitly.

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
--   • employees.auth_user_id is nullable — an employee row can
--     exist before the employee has an Auth account.
--   • profiles.id is a FK to auth.users(id) — it cannot hold a
--     row before the Auth account exists (v3 violated this).
--   • Storing the token on the employee record keeps the token
--     and the identity it authenticates together naturally.
--
--   Lifecycle of invite_token:
--   • Admin creates employee → token generated, stored here.
--   • Employee claims account → token verified and set to NULL.
--   • NULL = account active; non-NULL = pending activation.
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

-- If the employees table already exists from a previous version
-- that did not have invite_token, add the column safely.
-- Existing rows get NULL (pending-activation state matches the
-- semantics: no invite_token = account was never in the invite
-- flow, which is consistent with accounts set up by other means).
ALTER TABLE public.employees
    ADD COLUMN IF NOT EXISTS invite_token TEXT;

-- ── Timestamp helper ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

-- Trigger was dropped at the top of this file; re-create it now.
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
-- No access to other employees' salary, department, or any field.
DROP POLICY IF EXISTS "employees_select_own" ON public.employees;
CREATE POLICY "employees_select_own"
    ON public.employees FOR SELECT
    USING (auth_user_id = auth.uid());

-- No INSERT / UPDATE / DELETE for employees via the REST API.
-- All account claiming goes through claim_employee_account()
-- (SECURITY DEFINER, bypasses RLS, enforces token check).


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

-- Employees: read only their own attendance records.
-- Cannot INSERT, UPDATE, or DELETE attendance — admin-only.
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

-- Trigger was dropped at the top of this file; re-create it now.
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
-- Cannot read another employee's leave requests.
DROP POLICY IF EXISTS "leave_select_own" ON public.leave_requests;
CREATE POLICY "leave_select_own"
    ON public.leave_requests FOR SELECT
    USING (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
    );

-- Employees: submit new requests only.
--   • employee_id_fk must map to the caller's own employee row.
--     An employee cannot submit a request for someone else.
--   • status must be 'Pending' on insert.
--     An employee cannot insert an already-Approved request,
--     which would be equivalent to self-approving.
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
-- The absence of an UPDATE or DELETE policy blocks these
-- operations at the database level.


-- ============================================================
-- SECTION 6 — GRANTS
-- ============================================================

GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.employees      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.attendance     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.leave_requests TO authenticated;

-- No table grants to anon.
-- auth.getSession() uses the Auth API, not the public schema,
-- so unauthenticated page loads do not need table access.


-- ============================================================
-- SECTION 7 — NEW USER TRIGGER
--
--   Fires after every INSERT on auth.users.
--   Inserts a default profiles row with role = 'employee'.
--
--   For the admin account: the manual SQL in Section 9 Step C
--   uses ON CONFLICT (id) DO UPDATE SET role = 'admin' to
--   promote this row after the trigger runs.
--
--   For employee accounts: the row inserted here is the final
--   profiles row.  claim_employee_account() later sets the
--   employee_id field on this same row.
--
--   ON CONFLICT (id) DO NOTHING is safe because auth.users.id
--   is unique and the trigger only runs once per INSERT.
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

-- Trigger was dropped at the top of this file; re-create it now.
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ============================================================
-- SECTION 8 — EMPLOYEE ACCOUNT CLAIM FUNCTION
--
--   Called from register.html after the employee completes
--   auth.signUp().  Links the new Auth account to the employee
--   record created by the admin and consumes the invite token.
--
--   Signature (matches register.html exactly):
--     claim_employee_account(p_employee_id TEXT, p_invite_token TEXT)
--
--   SECURITY PROPERTIES:
--
--   (1) auth.uid() only — the function derives the caller's
--       identity from the verified JWT, not from any parameter
--       the browser supplies.  A forged UUID cannot impersonate
--       another user.
--
--   (2) Authenticated callers only — GRANT is to 'authenticated'
--       role, not 'anon'.  An unauthenticated request is rejected
--       before the function body runs.
--
--   (3) Email verification — the caller's email is read from
--       auth.users (trusted server-side) and compared to
--       employees.email.  An attacker who obtains another
--       employee's token cannot claim that account because their
--       JWT email will not match.
--
--   (4) Row-level lock — SELECT ... FOR UPDATE on the employees
--       row serialises concurrent claim attempts.  The second
--       request waits; when it proceeds it sees
--       auth_user_id IS NOT NULL and is rejected in check (5).
--
--   (5) Duplicate-claim rejection — auth_user_id IS NOT NULL
--       means the account is already active.
--
--   (6) Token presence and value check — invite_token must be
--       non-NULL and must equal p_invite_token.  A NULL token
--       means the account was already claimed or was set up
--       without the invite flow.
--
--   (7) Case-insensitive employee_id lookup — the lookup uses
--       lower(employee_id) = lower(p_employee_id) so that an
--       admin entering "emp001" and an employee typing "EMP001"
--       on register.html are treated as the same ID.
--
--   (8) Single transaction — all writes (employees, profiles)
--       commit or roll back together.  No partial state.
--
--   (9) Role is always 'employee' — cannot self-promote to admin.
--
--   (10) Protected fields untouched — salary, department,
--        designation, employee_id in employees are never written.
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
    -- ── 0. Caller identity from the JWT ──────────────────────
    v_caller_id := auth.uid();

    IF v_caller_id IS NULL THEN
        RETURN jsonb_build_object(
            'error', 'You must be signed in to activate an account.'
        );
    END IF;

    -- ── 1. Caller email from auth.users (server-trusted) ─────
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
    --   Case-insensitive lookup so "EMP001" and "emp001" match.
    --   FOR UPDATE serialises concurrent claim attempts.
    SELECT *
    INTO   v_employee_row
    FROM   public.employees
    WHERE  lower(employee_id) = lower(p_employee_id)
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

    -- ── 4. Email must match (anti-impersonation) ─────────────
    IF lower(v_employee_row.email) != v_caller_email THEN
        RETURN jsonb_build_object(
            'error', 'The email address you signed up with does not '
                  || 'match the email on file for this Employee ID.'
        );
    END IF;

    -- ── 5. Token must be present ─────────────────────────────
    IF v_employee_row.invite_token IS NULL THEN
        RETURN jsonb_build_object(
            'error', 'No pending invitation found for this Employee ID.'
        );
    END IF;

    -- ── 6. Token must be correct ─────────────────────────────
    --   Checked after email verification so an attacker cannot
    --   enumerate valid tokens without a matching email address.
    IF v_employee_row.invite_token != p_invite_token THEN
        RETURN jsonb_build_object('error', 'Invalid invite token.');
    END IF;

    -- ── 7. Link Auth user; consume the token ─────────────────
    UPDATE public.employees
    SET    auth_user_id = v_caller_id,
           invite_token = NULL
    WHERE  id           = v_employee_row.id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Failed to link employee record (employees.id = %).',
            v_employee_row.id;
    END IF;

    -- ── 8. Stamp profiles row with the Employee ID ───────────
    --   handle_new_user() inserted this row when signUp() ran.
    --   We only need to fill in the employee_id field.
    UPDATE public.profiles
    SET    employee_id = v_employee_row.employee_id
    WHERE  id          = v_caller_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Profiles row missing for auth user id = %.', v_caller_id;
    END IF;

    RETURN jsonb_build_object('success', true);

EXCEPTION WHEN OTHERS THEN
    -- Any unhandled error rolls back all writes automatically.
    RETURN jsonb_build_object('error', SQLERRM);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_employee_account(TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.claim_employee_account(TEXT, TEXT) TO authenticated;


-- ============================================================
-- SECTION 9 — CREATE THE FIRST ADMIN ACCOUNT
--
--   Run all steps AFTER the schema above has been applied.
-- ============================================================

/*
────────────────────────────────────────────────────────────
STEP A — Disable email confirmation  (UI — do this first)
────────────────────────────────────────────────────────────
  Supabase Dashboard
  → Authentication → Settings
  → Turn OFF "Enable email confirmations"
  → Save

  Without this every new account must click a confirmation
  email before it can log in, including the admin account.

────────────────────────────────────────────────────────────
STEP B — Create the admin Auth user  (UI)
────────────────────────────────────────────────────────────
  Authentication → Users → Add user
    Email    : admin@pms.local   (or any email you choose)
    Password : a strong password — write it down
  → Create user

  handle_new_user() fires automatically and inserts:
    profiles row: id = <admin UUID>, role = 'employee'

────────────────────────────────────────────────────────────
STEP C — Promote to admin  (SQL Editor)
────────────────────────────────────────────────────────────
  Copy the UUID from Authentication → Users, then run:

    INSERT INTO public.profiles (id, role)
    VALUES ('<paste-admin-uuid-here>', 'admin')
    ON CONFLICT (id) DO UPDATE SET role = 'admin';

  CRITICAL: use DO UPDATE SET role = 'admin', NOT DO NOTHING.
  The trigger already inserted role = 'employee'.
  DO NOTHING silently keeps that — the admin would land on
  the employee dashboard instead of the admin dashboard.

  Verify:
    SELECT id, role FROM public.profiles WHERE role = 'admin';
  Expected: exactly one row.

────────────────────────────────────────────────────────────
STEP D — Test admin login
────────────────────────────────────────────────────────────
  Open login.html, sign in with the admin credentials.
  Expected: admin dashboard with stat cards and navigation.

────────────────────────────────────────────────────────────
STEP E — Add an employee  (in the app, as admin)
────────────────────────────────────────────────────────────
  Admin dashboard → Add Employee → fill in all fields
  → Add Employee

  A popup shows the one-time invite token.
  Write down the Employee ID, email, and token.
  The employee row is saved with invite_token set and
  auth_user_id = NULL (account not yet activated).

────────────────────────────────────────────────────────────
STEP F — Employee activates their account  (register.html)
────────────────────────────────────────────────────────────
  Employee opens register.html and enters:
    Employee ID     : as given by admin (case-insensitive)
    Email address   : exactly as given by admin
    Invite Token    : the token from the admin popup
    New Password    : minimum 8 characters
    Confirm Password

  Server-side sequence:
    1. signUp() creates an auth.users row and a session.
    2. handle_new_user() inserts:
           profiles(id = <new UUID>, role = 'employee')
    3. rpc("claim_employee_account") runs:
       • Derives caller from auth.uid() — no forged UUID.
       • Reads caller email from auth.users (server-side).
       • Finds employees row by employee_id (case-insensitive).
       • Checks auth_user_id IS NULL (not already claimed).
       • Verifies caller email matches employees.email.
       • Verifies invite_token is present and correct.
       • Sets employees.auth_user_id = auth.uid().
       • Sets employees.invite_token = NULL (consumed).
       • Sets profiles.employee_id = the Employee ID.
    4. signOut() clears the session.
  Employee is redirected to login.html.

────────────────────────────────────────────────────────────
STEP G — Employee logs in  (login.html)
────────────────────────────────────────────────────────────
  Employee enters their email and password.
  initApp() reads their profiles row → role = 'employee'.
  Employee dashboard loads showing their profile, attendance
  summary, and leave request history.

────────────────────────────────────────────────────────────
STEP H — Verify data isolation
────────────────────────────────────────────────────────────
  While logged in as employee, the RLS policies ensure:
  • employees query returns only their own row.
  • attendance query returns only their own records.
  • leave_requests query returns only their own requests.
  • Leave requests can only be submitted with status = 'Pending'
    and only for the authenticated employee's own employee_id_fk.
  • No INSERT / UPDATE / DELETE on attendance is possible.
  • No UPDATE / DELETE on leave_requests is possible.
*/

-- ============================================================
-- END OF SCHEMA
-- ============================================================
