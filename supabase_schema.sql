-- ============================================================
--  Personnel Management System — Supabase / PostgreSQL Schema
--  Version 2 — Security-reviewed
--
--  HOW TO USE:
--  1. Paste this entire file into Supabase Dashboard → SQL Editor
--  2. Click Run.  It is safe to run on a fresh project.
--  3. Follow the steps at the bottom to create the admin account.
--  4. Read SETUP.md for the complete setup walkthrough.
-- ============================================================


-- ============================================================
-- SECTION 0 — DROP OLD TRIGGERS (safe re-run guard)
--   Drop triggers before their functions so there are no
--   dependency errors if you run this file more than once.
-- ============================================================

DROP TRIGGER IF EXISTS on_auth_user_created    ON auth.users;
DROP TRIGGER IF EXISTS employees_updated_at    ON public.employees;
DROP TRIGGER IF EXISTS leave_requests_updated_at ON public.leave_requests;


-- ============================================================
-- SECTION 1 — SAFE ROLE-CHECK HELPER FUNCTION
--
--   WHY THIS EXISTS:
--   RLS policies on the `profiles` table cannot safely query
--   `profiles` again inside their own USING / WITH CHECK
--   expressions — PostgreSQL evaluates those subqueries
--   recursively and throws a stack-depth error.
--
--   This SECURITY DEFINER function runs as the database owner
--   (bypassing RLS) so it can read profiles without recursion.
--   It is the only safe way to check roles from within an
--   RLS policy on the profiles table itself.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS TEXT
LANGUAGE sql
STABLE          -- result does not change within a single SQL statement
SECURITY DEFINER
SET search_path = public   -- prevent search_path injection
AS $$
    SELECT role
    FROM   public.profiles
    WHERE  id = auth.uid()
    LIMIT  1;
$$;

-- Revoke public execute so only authenticated DB users can call it.
REVOKE EXECUTE ON FUNCTION public.get_my_role() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.get_my_role() TO authenticated;


-- ============================================================
-- SECTION 2 — PROFILES TABLE
--   One row per Auth user.
--   role        = 'admin' | 'employee'
--   employee_id = the text Employee ID (e.g. "EMP001");
--                 NULL for admin accounts.
--   invite_token = random token used by employees to claim
--                  their account on first login (see SECTION 7).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.profiles (
    id            UUID        PRIMARY KEY
                              REFERENCES auth.users(id) ON DELETE CASCADE,
    role          TEXT        NOT NULL
                              CHECK (role IN ('admin', 'employee')),
    employee_id   TEXT,
    invite_token  TEXT        UNIQUE,   -- used for employee self-registration
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- ── SELECT ──────────────────────────────────────────────────
-- Any authenticated user can read their own row.
DROP POLICY IF EXISTS "profiles_select_own"   ON public.profiles;
CREATE POLICY "profiles_select_own"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id);

-- Admins can read all rows.
-- Uses get_my_role() to avoid recursive self-reference.
DROP POLICY IF EXISTS "profiles_select_admin" ON public.profiles;
CREATE POLICY "profiles_select_admin"
    ON public.profiles FOR SELECT
    USING (public.get_my_role() = 'admin');

-- ── INSERT ──────────────────────────────────────────────────
-- Allow insert only when:
--   (a) the current user is an admin, OR
--   (b) the row being inserted belongs to the current user
--       AND its role is forced to 'employee'
--       (covers the self-registration / invite-claim path).
-- The trigger handle_new_user() also inserts via SECURITY DEFINER
-- and is exempt from RLS, so we do not need a service_role clause.
DROP POLICY IF EXISTS "profiles_insert_admin"     ON public.profiles;
DROP POLICY IF EXISTS "profiles_insert_self_emp"  ON public.profiles;

CREATE POLICY "profiles_insert_admin"
    ON public.profiles FOR INSERT
    WITH CHECK (public.get_my_role() = 'admin');

CREATE POLICY "profiles_insert_self_emp"
    ON public.profiles FOR INSERT
    WITH CHECK (
        id   = auth.uid()
        AND  role = 'employee'   -- employees cannot self-promote to admin
    );

-- ── UPDATE ──────────────────────────────────────────────────
-- Only admins may update profile rows.
-- This prevents employees from changing their own role.
DROP POLICY IF EXISTS "profiles_update_admin" ON public.profiles;
CREATE POLICY "profiles_update_admin"
    ON public.profiles FOR UPDATE
    USING  (public.get_my_role() = 'admin')
    WITH CHECK (public.get_my_role() = 'admin');

-- ── DELETE ──────────────────────────────────────────────────
-- Profile rows are deleted automatically when the Auth user is
-- deleted (ON DELETE CASCADE defined above).  No explicit RLS
-- delete policy is needed for normal operation.
-- Admins may explicitly delete a profile row if required.
DROP POLICY IF EXISTS "profiles_delete_admin" ON public.profiles;
CREATE POLICY "profiles_delete_admin"
    ON public.profiles FOR DELETE
    USING (public.get_my_role() = 'admin');


-- ============================================================
-- SECTION 3 — EMPLOYEES TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS public.employees (
    id            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id  UUID         UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    employee_id   TEXT         NOT NULL UNIQUE,
    name          TEXT         NOT NULL,
    email         TEXT         NOT NULL UNIQUE,
    department    TEXT         NOT NULL,
    designation   TEXT         NOT NULL,
    salary        NUMERIC(12,2) NOT NULL CHECK (salary >= 0),
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ── Timestamp helper ─────────────────────────────────────────
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

-- ── Indexes ──────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_employees_employee_id
    ON public.employees(employee_id);
CREATE INDEX IF NOT EXISTS idx_employees_auth_user_id
    ON public.employees(auth_user_id);

-- ── RLS ──────────────────────────────────────────────────────
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;

-- Admins: full access
DROP POLICY IF EXISTS "employees_all_admin" ON public.employees;
CREATE POLICY "employees_all_admin"
    ON public.employees FOR ALL
    USING     (public.get_my_role() = 'admin')
    WITH CHECK (public.get_my_role() = 'admin');

-- Employees: read their own row only
DROP POLICY IF EXISTS "employees_select_own" ON public.employees;
CREATE POLICY "employees_select_own"
    ON public.employees FOR SELECT
    USING (auth_user_id = auth.uid());

-- Employees: update their OWN row but ONLY the auth_user_id column.
-- This is used during the invite-claim flow when an employee links
-- their new Auth account to the pre-existing employee record.
-- They cannot change salary, department, designation, or employee_id.
DROP POLICY IF EXISTS "employees_update_claim" ON public.employees;
CREATE POLICY "employees_update_claim"
    ON public.employees FOR UPDATE
    USING (
        -- The row must currently be unclaimed (auth_user_id IS NULL)
        -- and the claim must be made by the current authenticated user.
        auth_user_id IS NULL
        AND public.get_my_role() = 'employee'
    )
    WITH CHECK (
        -- After the update, the row must point to the current user.
        auth_user_id = auth.uid()
        AND public.get_my_role() = 'employee'
    );


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

-- Admins: full access
DROP POLICY IF EXISTS "attendance_all_admin" ON public.attendance;
CREATE POLICY "attendance_all_admin"
    ON public.attendance FOR ALL
    USING     (public.get_my_role() = 'admin')
    WITH CHECK (public.get_my_role() = 'admin');

-- Employees: read their own records only
DROP POLICY IF EXISTS "attendance_select_own" ON public.attendance;
CREATE POLICY "attendance_select_own"
    ON public.attendance FOR SELECT
    USING (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
    );

-- Employees cannot INSERT, UPDATE, or DELETE attendance.
-- Only admins can mark attendance (enforced by the admin-only INSERT above).


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

-- Admins: full access (approve / reject / delete)
DROP POLICY IF EXISTS "leave_all_admin" ON public.leave_requests;
CREATE POLICY "leave_all_admin"
    ON public.leave_requests FOR ALL
    USING     (public.get_my_role() = 'admin')
    WITH CHECK (public.get_my_role() = 'admin');

-- Employees: read their own requests only
DROP POLICY IF EXISTS "leave_select_own" ON public.leave_requests;
CREATE POLICY "leave_select_own"
    ON public.leave_requests FOR SELECT
    USING (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
    );

-- Employees: submit new requests only.
-- Enforced constraints:
--   1. employee_id_fk must map to the requesting user's own employee row.
--   2. status must be 'Pending' on insert — employees cannot self-approve.
DROP POLICY IF EXISTS "leave_insert_own" ON public.leave_requests;
CREATE POLICY "leave_insert_own"
    ON public.leave_requests FOR INSERT
    WITH CHECK (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
        AND status = 'Pending'
    );

-- Employees: NO UPDATE or DELETE policy.
-- Employees cannot change their request once submitted,
-- and cannot change the status to Approved/Rejected themselves.
-- This is intentional and enforced at the database level.


-- ============================================================
-- SECTION 6 — GRANTS
--   The anon key is used on the frontend for unauthenticated
--   requests (e.g. the initial session check on login.html).
--   The authenticated role covers all logged-in users; RLS
--   policies above control what each user can actually see.
-- ============================================================

GRANT USAGE  ON SCHEMA public TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.employees      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.attendance     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.leave_requests TO authenticated;

-- Read-only for anon (needed for the Supabase JS client to initialise)
GRANT SELECT ON public.profiles TO anon;


-- ============================================================
-- SECTION 7 — NEW USER TRIGGER
--
--   This trigger fires after EVERY new row in auth.users,
--   including the admin account you create manually.
--
--   It inserts a profile row with role = 'employee' as the
--   safe default.  The admin account creation step below
--   uses ON CONFLICT ... DO UPDATE to OVERRIDE this default
--   and set role = 'admin'.
--
--   The trigger is SECURITY DEFINER so it runs as the postgres
--   role and is not blocked by the RLS policies on profiles.
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    /*
     * Always insert with role = 'employee' as a safe default.
     * For the admin account, the manual INSERT below uses
     * ON CONFLICT (id) DO UPDATE SET role = 'admin'
     * to promote the row after this trigger has run.
     *
     * ON CONFLICT DO NOTHING is intentionally NOT used here
     * so that a re-run of the function on the same UUID still
     * produces a row (idempotent insert).
     */
    INSERT INTO public.profiles (id, role)
    VALUES (NEW.id, 'employee')
    ON CONFLICT (id) DO NOTHING;

    RETURN NEW;
END;
$$;

-- Recreate the trigger (DROP was at the top of this file)
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ============================================================
-- SECTION 8 — EMPLOYEE INVITE-CLAIM HELPER FUNCTION
--
--   Because the admin cannot safely call auth.signUp() from
--   the browser without losing their own session, employees
--   claim their accounts themselves using an invite token.
--
--   Flow:
--   1. Admin creates an employee record (no Auth user yet).
--      The system generates a random invite_token and stores
--      it in the profiles table linked to the employee record.
--   2. Admin gives the employee their Employee ID and invite token.
--   3. Employee opens the "First Login" page, enters their
--      Employee ID, invite token, and sets a new password.
--   4. The frontend calls auth.signUp() as the employee.
--   5. After signup the frontend calls this RPC to link the
--      new auth.users row to the existing employee record and
--      mark the token as consumed.
--
--   This function runs SECURITY DEFINER so it can write to
--   both employees and profiles without the new employee
--   having admin privileges.
-- ============================================================

CREATE OR REPLACE FUNCTION public.claim_employee_account(
    p_employee_id  TEXT,
    p_invite_token TEXT,
    p_auth_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_employee_row  public.employees%ROWTYPE;
    v_profile_row   public.profiles%ROWTYPE;
BEGIN
    -- 1. Find the employee row by employee_id
    SELECT * INTO v_employee_row
    FROM public.employees
    WHERE employee_id = p_employee_id
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'Employee ID not found.');
    END IF;

    -- 2. Verify the employee is not already claimed
    IF v_employee_row.auth_user_id IS NOT NULL THEN
        RETURN jsonb_build_object('error', 'This account has already been claimed.');
    END IF;

    -- 3. Find the profiles row by employee_id and verify the invite token
    SELECT * INTO v_profile_row
    FROM public.profiles
    WHERE employee_id = p_employee_id
    LIMIT 1;

    IF NOT FOUND OR v_profile_row.invite_token IS NULL THEN
        RETURN jsonb_build_object('error', 'No pending invitation found for this Employee ID.');
    END IF;

    IF v_profile_row.invite_token != p_invite_token THEN
        RETURN jsonb_build_object('error', 'Invalid invite token.');
    END IF;

    -- 4. Link the Auth user to the employee record
    UPDATE public.employees
    SET auth_user_id = p_auth_user_id
    WHERE id = v_employee_row.id;

    -- 5. Link the profile row to the Auth user and consume the token
    UPDATE public.profiles
    SET id           = p_auth_user_id,
        invite_token = NULL           -- token is single-use
    WHERE employee_id = p_employee_id;

    RETURN jsonb_build_object('success', true);

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLERRM);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.claim_employee_account(TEXT, TEXT, UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.claim_employee_account(TEXT, TEXT, UUID) TO authenticated, anon;


-- ============================================================
-- SECTION 9 — CREATE THE FIRST ADMIN ACCOUNT
--
--   Run these steps AFTER the schema above has been applied.
--   Steps A and B are done in the Supabase Dashboard UI.
--   Step C is a SQL command you run in the SQL Editor.
-- ============================================================

/*
──────────────────────────────────────────────────────────────
STEP A — Disable email confirmation (do this once, in the UI)
──────────────────────────────────────────────────────────────
  Supabase Dashboard → Authentication → Settings
  → Turn OFF "Enable email confirmations"
  → Save

  Without this, newly created users (including admin) must
  click a confirmation email before they can log in.
  For a college demo, turn this off.

──────────────────────────────────────────────────────────────
STEP B — Create the admin Auth user (in the UI)
──────────────────────────────────────────────────────────────
  Supabase Dashboard → Authentication → Users → Add user
    Email:    admin@pms.local      (or any email you choose)
    Password: (a strong password — write it down)
  Click "Create user".

  The handle_new_user() trigger will fire automatically and
  insert a profiles row with role = 'employee'.

──────────────────────────────────────────────────────────────
STEP C — Promote the admin profile (run in SQL Editor)
──────────────────────────────────────────────────────────────

  IMPORTANT: Use ON CONFLICT ... DO UPDATE, not DO NOTHING.
  The trigger already inserted role = 'employee'.
  DO NOTHING would silently keep it as 'employee'.
  DO UPDATE SET role = 'admin' correctly overrides it.

  Replace <paste-uuid-here> with the UUID from the Users list.

    INSERT INTO public.profiles (id, role)
    VALUES ('<paste-uuid-here>', 'admin')
    ON CONFLICT (id) DO UPDATE SET role = 'admin';

  Verify it worked:

    SELECT id, role FROM public.profiles WHERE role = 'admin';

  You should see exactly one row.

──────────────────────────────────────────────────────────────
STEP D — Test admin login
──────────────────────────────────────────────────────────────
  Open login.html in your browser and sign in with the admin
  email and password.  You should reach the admin dashboard.

──────────────────────────────────────────────────────────────
STEP E — Create employee accounts (via the app)
──────────────────────────────────────────────────────────────
  While logged in as admin, use the "Add Employee" form.
  The system will generate an invite token for each employee.
  Give the employee their Employee ID and invite token.
  The employee uses the "First Login" page to set their password.

  See SETUP.md for the full step-by-step.
*/

-- ============================================================
-- END OF SCHEMA
-- ============================================================
