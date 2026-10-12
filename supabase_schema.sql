-- ============================================================
--  Personnel Management System — Supabase / PostgreSQL Schema
--  Version 3 — Security-reviewed
--
--  HOW TO USE:
--  1. Paste this entire file into Supabase Dashboard → SQL Editor
--  2. Click Run.  Safe to run on a completely fresh project.
--  3. Follow the instructions at the bottom to create the admin.
--  4. Read SETUP.md for the full walkthrough.
--
--  This file has NOT been run against a live Supabase project.
--  It has been reviewed for logical correctness but not
--  integration-tested. Treat the first run as your validation.
-- ============================================================


-- ============================================================
-- SECTION 0 — SAFE RE-RUN GUARDS
--   Drop triggers before their functions.  Policies are
--   dropped inline (DROP POLICY IF EXISTS before each CREATE).
-- ============================================================

DROP TRIGGER IF EXISTS on_auth_user_created      ON auth.users;
DROP TRIGGER IF EXISTS employees_updated_at      ON public.employees;
DROP TRIGGER IF EXISTS leave_requests_updated_at ON public.leave_requests;


-- ============================================================
-- SECTION 1 — ROLE-CHECK HELPER FUNCTION
--
--   WHY THIS IS NECESSARY:
--   RLS policies on `profiles` cannot safely subquery `profiles`
--   in their own USING / WITH CHECK expressions — PostgreSQL
--   recurses infinitely and throws a stack-depth error.
--
--   This SECURITY DEFINER function runs as the database owner,
--   bypasses RLS, and reads the caller's role safely.
--   Every policy that needs to know "is this user an admin?"
--   calls get_my_role() instead of querying profiles directly.
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
--   One row per Auth user.
--
--   role         = 'admin' | 'employee'
--   employee_id  = text Employee ID (e.g. "EMP001"); NULL for admin
--   invite_token = single-use token for employee account claim;
--                  set to NULL once the account is claimed.
--
--   IMPORTANT — two kinds of rows exist in this table:
--
--   A. Placeholder rows  (created by admin before the employee
--      signs up).  These have a random placeholder UUID as `id`
--      because there is no auth.users row yet.  They have a
--      non-NULL invite_token.
--
--   B. Real rows  (created / promoted during or after signUp).
--      `id` = the actual auth.users UUID.  invite_token = NULL.
--
--   The claim_employee_account() function in Section 8 converts
--   a placeholder row into a real row atomically.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.profiles (
    id            UUID        PRIMARY KEY
                              REFERENCES auth.users(id) ON DELETE CASCADE,
    role          TEXT        NOT NULL
                              CHECK (role IN ('admin', 'employee')),
    employee_id   TEXT,
    invite_token  TEXT        UNIQUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
-- Admins can insert profile rows (e.g. the admin-promotion step).
-- The handle_new_user() trigger inserts via SECURITY DEFINER and
-- is not subject to RLS.
-- The claim_employee_account() RPC also uses SECURITY DEFINER
-- and is not subject to RLS.
-- Employees must NOT be able to insert their own profile rows
-- directly, because that would let them choose their own role.
DROP POLICY IF EXISTS "profiles_insert_admin"    ON public.profiles;
DROP POLICY IF EXISTS "profiles_insert_self_emp" ON public.profiles;

CREATE POLICY "profiles_insert_admin"
    ON public.profiles FOR INSERT
    WITH CHECK (public.get_my_role() = 'admin');

-- NOTE: profiles_insert_self_emp was removed intentionally.
-- Previously it allowed any authenticated employee to insert a
-- profile row for themselves with role = 'employee'.  That is
-- now handled exclusively by claim_employee_account() (SECURITY
-- DEFINER), which verifies the invite token before inserting.
-- Direct INSERT by employees is no longer permitted.

-- ── UPDATE ───────────────────────────────────────────────────
-- Only admins may update profile rows.
-- Employees cannot change their own role.
DROP POLICY IF EXISTS "profiles_update_admin" ON public.profiles;
CREATE POLICY "profiles_update_admin"
    ON public.profiles FOR UPDATE
    USING  (public.get_my_role() = 'admin')
    WITH CHECK (public.get_my_role() = 'admin');

-- ── DELETE ───────────────────────────────────────────────────
-- Profile rows are cascade-deleted when the Auth user is deleted.
-- Admins can also delete profile rows explicitly.
DROP POLICY IF EXISTS "profiles_delete_admin" ON public.profiles;
CREATE POLICY "profiles_delete_admin"
    ON public.profiles FOR DELETE
    USING (public.get_my_role() = 'admin');


-- ============================================================
-- SECTION 3 — EMPLOYEES TABLE
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
    is_active     BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

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

CREATE INDEX IF NOT EXISTS idx_employees_employee_id
    ON public.employees(employee_id);
CREATE INDEX IF NOT EXISTS idx_employees_auth_user_id
    ON public.employees(auth_user_id);

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

-- NOTE: employees_update_claim was removed intentionally.
--
-- The previous version had an RLS UPDATE policy that allowed any
-- authenticated employee to update any employees row where
-- auth_user_id IS NULL.  This meant any employee could claim any
-- unclaimed account directly via the REST API, bypassing the
-- invite-token check entirely.
--
-- All claiming is now handled exclusively through
-- claim_employee_account() (SECURITY DEFINER), which runs token
-- verification before touching any row.  No RLS UPDATE policy
-- for employees is needed or safe.


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

-- Employees: read their own records only.
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

-- Admins: full access
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

-- Employees: submit new requests.
-- employee_id_fk must map to the caller's own employee row.
-- status must be 'Pending' on insert — employees cannot self-approve.
DROP POLICY IF EXISTS "leave_insert_own" ON public.leave_requests;
CREATE POLICY "leave_insert_own"
    ON public.leave_requests FOR INSERT
    WITH CHECK (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
        AND status = 'Pending'
    );

-- No UPDATE or DELETE for employees — enforced by absence of policy.


-- ============================================================
-- SECTION 6 — GRANTS
-- ============================================================

GRANT USAGE ON SCHEMA public TO anon, authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.employees      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.attendance     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.leave_requests TO authenticated;

-- anon needs SELECT on profiles only for the Supabase JS client
-- session initialisation check on login.html.
GRANT SELECT ON public.profiles TO anon;


-- ============================================================
-- SECTION 7 — NEW USER TRIGGER
--
--   Fires after every new row in auth.users.
--
--   IMPORTANT CHANGE FROM V2:
--   The trigger now checks whether a placeholder profile row
--   already exists for the signing-up user's email address.
--   If one does, it means admin pre-created this employee and
--   claim_employee_account() will handle linking — so the
--   trigger does nothing for this user.
--   If no placeholder exists, the trigger inserts the default
--   'employee' profile row (covers the admin account case and
--   any other new-user scenario).
--
--   WHY THIS MATTERS:
--   In V2 the trigger unconditionally inserted a new profile
--   row with id = NEW.id (the real auth UUID).  But admin had
--   already inserted a placeholder row with a different UUID.
--   That left two profile rows for the same employee.  Then
--   claim_employee_account() tried to UPDATE the placeholder
--   row's primary key to the real UUID, which fails with a
--   unique-constraint violation because the real-UUID row
--   already existed.
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_placeholder_exists BOOLEAN;
BEGIN
    /*
     * Check whether a placeholder profile row already exists for
     * the email address that just signed up.  A placeholder row
     * is one whose employee_id matches an employees row with the
     * same email AND whose invite_token is not NULL.
     */
    SELECT EXISTS (
        SELECT 1
        FROM   public.profiles pr
        JOIN   public.employees em ON em.employee_id = pr.employee_id
        WHERE  lower(em.email) = lower(NEW.email)
          AND  pr.invite_token IS NOT NULL
    )
    INTO v_placeholder_exists;

    IF v_placeholder_exists THEN
        /*
         * A placeholder exists.  claim_employee_account() will
         * handle deleting it and inserting the real row.
         * Do nothing here to avoid creating a duplicate.
         */
        RETURN NEW;
    END IF;

    /*
     * No placeholder — this is either the admin account or an
     * unrelated new user.  Insert the default 'employee' profile.
     * For the admin, the manual SQL in Step C below will promote
     * this row to 'admin' using ON CONFLICT (id) DO UPDATE.
     */
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
--   WHAT IT DOES:
--   Converts a placeholder profile + unclaimed employee row
--   into a fully linked, active account.
--
--   SECURITY PROPERTIES (v3):
--
--   1. Does NOT accept a caller-supplied auth user ID.
--      Uses auth.uid() exclusively — the value Supabase injects
--      from the verified JWT.  A caller cannot impersonate
--      another user by supplying a different UUID.
--
--   2. Only callable by authenticated users (GRANT to
--      authenticated only — anon removed).
--
--   3. Verifies that auth.users.email (for the caller's JWT)
--      matches employees.email for the requested employee_id.
--      An employee cannot claim a record belonging to a
--      different email address even if they know the token.
--
--   4. Verifies the employee_id exists and is unclaimed
--      (auth_user_id IS NULL).
--
--   5. Verifies the invite_token is correct and non-NULL.
--
--   6. Uses SELECT ... FOR UPDATE on the employees row to
--      acquire a row-level lock before any writes.  This
--      prevents a race condition where two concurrent requests
--      with the same token both pass the checks and both
--      succeed.  Only the first to acquire the lock proceeds;
--      the second will see auth_user_id IS NOT NULL and fail.
--
--   7. Deletes the placeholder profile row and inserts a new
--      one with id = auth.uid().  Avoids a primary-key UPDATE
--      which can cause constraint violations.
--
--   8. All writes happen in the same transaction.  If any step
--      fails, the entire transaction rolls back — no partial
--      state is committed.
--
--   9. The caller cannot promote themselves to admin.  The new
--      profile row is always inserted with role = 'employee'.
--
--   10. Protected employee fields (salary, department,
--       designation, employee_id) are never written by this
--       function.  Only auth_user_id is updated.
-- ============================================================

CREATE OR REPLACE FUNCTION public.claim_employee_account(
    p_employee_id  TEXT,
    p_invite_token TEXT
    -- p_auth_user_id removed: we use auth.uid() directly.
    -- Accepting it from the caller was a security vulnerability
    -- because it could be forged in an API request.
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
    v_placeholder_id UUID;
BEGIN
    -- ── 0. Identify the caller from the JWT ──────────────────
    v_caller_id := auth.uid();

    IF v_caller_id IS NULL THEN
        RETURN jsonb_build_object(
            'error', 'You must be signed in to claim an account.'
        );
    END IF;

    -- ── 1. Get the caller's verified email from auth.users ───
    --   auth.users is in the auth schema; SECURITY DEFINER lets
    --   us read it here.
    SELECT lower(email)
    INTO   v_caller_email
    FROM   auth.users
    WHERE  id = v_caller_id;

    IF v_caller_email IS NULL THEN
        RETURN jsonb_build_object(
            'error', 'Could not verify your identity. Please sign in again.'
        );
    END IF;

    -- ── 2. Find and lock the employee row ────────────────────
    --   FOR UPDATE acquires a row-level lock.  If two concurrent
    --   calls arrive simultaneously, the second will wait here
    --   until the first transaction completes (commits or rolls
    --   back).  This makes the claim atomic.
    SELECT *
    INTO   v_employee_row
    FROM   public.employees
    WHERE  employee_id = p_employee_id
    FOR UPDATE;             -- row-level lock

    IF NOT FOUND THEN
        RETURN jsonb_build_object('error', 'Employee ID not found.');
    END IF;

    -- ── 3. Check the account is not already claimed ──────────
    IF v_employee_row.auth_user_id IS NOT NULL THEN
        RETURN jsonb_build_object(
            'error', 'This account has already been claimed. '
                  || 'Please sign in on the login page.'
        );
    END IF;

    -- ── 4. Verify the caller's email matches the employee record
    --   This is the critical anti-impersonation check.
    --   Even if someone knows another employee's token, they
    --   cannot use it because their JWT email will not match.
    IF lower(v_employee_row.email) != v_caller_email THEN
        RETURN jsonb_build_object(
            'error', 'The email address for your account does not match '
                  || 'the email associated with this Employee ID.'
        );
    END IF;

    -- ── 5. Find the placeholder profile row ──────────────────
    SELECT id
    INTO   v_placeholder_id
    FROM   public.profiles
    WHERE  employee_id   = p_employee_id
      AND  invite_token  IS NOT NULL;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'error', 'No pending invitation found for this Employee ID.'
        );
    END IF;

    -- ── 6. Verify the invite token ───────────────────────────
    --   Use a separate query so the token value is never returned
    --   to the caller in an error message.
    IF NOT EXISTS (
        SELECT 1
        FROM   public.profiles
        WHERE  id           = v_placeholder_id
          AND  invite_token = p_invite_token
    ) THEN
        RETURN jsonb_build_object('error', 'Invalid invite token.');
    END IF;

    -- ── 7. Delete the placeholder profile row ────────────────
    --   We delete rather than UPDATE the primary key because
    --   updating a PK to a value that already exists (inserted
    --   by handle_new_user for non-placeholder cases) would
    --   cause a unique-constraint violation.
    DELETE FROM public.profiles
    WHERE  id = v_placeholder_id;

    -- ── 8. Insert the real profile row ───────────────────────
    --   role is always 'employee' — the caller cannot promote
    --   themselves to admin through this function.
    --   invite_token is NULL — token is single-use and consumed.
    INSERT INTO public.profiles (id, role, employee_id, invite_token)
    VALUES (v_caller_id, 'employee', p_employee_id, NULL);

    -- ── 9. Link the employee record to the Auth user ─────────
    UPDATE public.employees
    SET    auth_user_id = v_caller_id
    WHERE  id           = v_employee_row.id;

    -- ── 10. Verify the link was written ──────────────────────
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Failed to link employee record.';
    END IF;

    RETURN jsonb_build_object('success', true);

EXCEPTION WHEN OTHERS THEN
    -- Any unhandled error rolls back all writes automatically.
    RETURN jsonb_build_object('error', SQLERRM);
END;
$$;

-- Only authenticated users may call this function.
-- anon users cannot claim accounts.
REVOKE EXECUTE ON FUNCTION public.claim_employee_account(TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.claim_employee_account(TEXT, TEXT) TO authenticated;


-- ============================================================
-- SECTION 9 — CREATE THE FIRST ADMIN ACCOUNT
--
--   ALL steps below are performed AFTER running the schema.
-- ============================================================

/*
──────────────────────────────────────────────────────────────
STEP A — Disable email confirmation  (UI, do this first)
──────────────────────────────────────────────────────────────
  Supabase Dashboard → Authentication → Settings
  → Turn OFF "Enable email confirmations"
  → Save

──────────────────────────────────────────────────────────────
STEP B — Create the admin Auth user  (UI)
──────────────────────────────────────────────────────────────
  Authentication → Users → Add user
  Email:    admin@pms.local  (or any email you prefer)
  Password: (strong password — write it down)
  Click "Create user".

  The handle_new_user() trigger fires and inserts:
      profiles row: id = <admin UUID>, role = 'employee'

──────────────────────────────────────────────────────────────
STEP C — Promote to admin  (SQL Editor)
──────────────────────────────────────────────────────────────
  Copy the UUID from Authentication → Users, then run:

      INSERT INTO public.profiles (id, role)
      VALUES ('<admin-uuid>', 'admin')
      ON CONFLICT (id) DO UPDATE SET role = 'admin';

  CRITICAL: Use DO UPDATE SET role = 'admin', not DO NOTHING.
  The trigger already inserted role = 'employee'.
  DO NOTHING would silently keep that value and the admin
  could never reach the admin dashboard.

  Verify:
      SELECT id, role FROM public.profiles WHERE role = 'admin';
  Expected: exactly one row.

──────────────────────────────────────────────────────────────
STEP D — Test admin login
──────────────────────────────────────────────────────────────
  Open login.html, sign in with the admin credentials.
  You should reach the admin dashboard.

──────────────────────────────────────────────────────────────
STEP E — Add employees (via the app)
──────────────────────────────────────────────────────────────
  Log in as admin → Add Employee form.
  Fill in all fields.  No password field — employees set their
  own password via register.html using the invite token.
  The admin sees the token in the confirmation popup.

──────────────────────────────────────────────────────────────
STEP F — Employee activates account (register.html)
──────────────────────────────────────────────────────────────
  Employee opens register.html and enters:
    - Their Employee ID
    - Their work email (exactly as admin entered it)
    - The invite token from the admin
    - A new password (and confirmation)

  On success the employee is redirected to login.html.
*/

-- ============================================================
-- END OF SCHEMA
-- ============================================================
