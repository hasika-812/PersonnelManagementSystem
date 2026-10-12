-- ============================================================
--  Personnel Management System — Supabase / PostgreSQL Schema
--  Run this entire file in: Supabase Dashboard → SQL Editor
-- ============================================================

-- ============================================================
-- 1. PROFILES TABLE
--    One row per Auth user.  Stores role and the text employee_id
--    used when creating the account, for fast role lookup.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.profiles (
    id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    role        TEXT NOT NULL CHECK (role IN ('admin', 'employee')),
    employee_id TEXT,           -- matches employees.employee_id; NULL for admin
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- RLS
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Users can read their own profile row
CREATE POLICY "profiles_select_own"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id);

-- Admins can read all profiles
CREATE POLICY "profiles_select_admin"
    ON public.profiles FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    );

-- Only the service role or an admin can insert / update profiles
CREATE POLICY "profiles_insert_admin"
    ON public.profiles FOR INSERT
    WITH CHECK (
        auth.role() = 'service_role'
        OR EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    );

CREATE POLICY "profiles_update_admin"
    ON public.profiles FOR UPDATE
    USING (
        auth.role() = 'service_role'
        OR EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    );


-- ============================================================
-- 2. EMPLOYEES TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS public.employees (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    auth_user_id UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    employee_id  TEXT NOT NULL UNIQUE,   -- e.g. "EMP001"
    name         TEXT NOT NULL,
    email        TEXT NOT NULL UNIQUE,
    department   TEXT NOT NULL,
    designation  TEXT NOT NULL,
    salary       NUMERIC(12, 2) NOT NULL CHECK (salary >= 0),
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Auto-update updated_at
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

-- Indexes
CREATE INDEX IF NOT EXISTS idx_employees_employee_id
    ON public.employees(employee_id);
CREATE INDEX IF NOT EXISTS idx_employees_auth_user_id
    ON public.employees(auth_user_id);

-- RLS
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;

-- Admins can do everything
CREATE POLICY "employees_all_admin"
    ON public.employees FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    );

-- Employees can only read their own row
CREATE POLICY "employees_select_own"
    ON public.employees FOR SELECT
    USING (auth_user_id = auth.uid());


-- ============================================================
-- 3. ATTENDANCE TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS public.attendance (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id_fk  UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    date            DATE NOT NULL,
    status          TEXT NOT NULL CHECK (status IN ('Present', 'Absent', 'Leave')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Prevent duplicate record for same employee on same date
    UNIQUE (employee_id_fk, date)
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_attendance_employee
    ON public.attendance(employee_id_fk);
CREATE INDEX IF NOT EXISTS idx_attendance_date
    ON public.attendance(date);

-- RLS
ALTER TABLE public.attendance ENABLE ROW LEVEL SECURITY;

-- Admins can do everything
CREATE POLICY "attendance_all_admin"
    ON public.attendance FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    );

-- Employees can only read their own attendance
CREATE POLICY "attendance_select_own"
    ON public.attendance FOR SELECT
    USING (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
    );


-- ============================================================
-- 4. LEAVE REQUESTS TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS public.leave_requests (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id_fk  UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    start_date      DATE NOT NULL,
    end_date        DATE NOT NULL,
    reason          TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'Pending'
                        CHECK (status IN ('Pending', 'Approved', 'Rejected')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Basic sanity check: end_date must be on or after start_date
    CONSTRAINT leave_date_order CHECK (end_date >= start_date)
);

CREATE TRIGGER leave_requests_updated_at
    BEFORE UPDATE ON public.leave_requests
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Indexes
CREATE INDEX IF NOT EXISTS idx_leave_requests_employee
    ON public.leave_requests(employee_id_fk);
CREATE INDEX IF NOT EXISTS idx_leave_requests_status
    ON public.leave_requests(status);

-- RLS
ALTER TABLE public.leave_requests ENABLE ROW LEVEL SECURITY;

-- Admins can do everything
CREATE POLICY "leave_all_admin"
    ON public.leave_requests FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.profiles p
            WHERE p.id = auth.uid() AND p.role = 'admin'
        )
    );

-- Employees can read their own requests
CREATE POLICY "leave_select_own"
    ON public.leave_requests FOR SELECT
    USING (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
    );

-- Employees can INSERT their own requests
CREATE POLICY "leave_insert_own"
    ON public.leave_requests FOR INSERT
    WITH CHECK (
        employee_id_fk IN (
            SELECT id FROM public.employees WHERE auth_user_id = auth.uid()
        )
        -- employees cannot self-approve: status must be 'Pending' on insert
        AND status = 'Pending'
    );

-- Employees CANNOT update or delete their own requests
-- (no UPDATE or DELETE policy for employees → blocked by RLS)


-- ============================================================
-- 5. TRIGGER: Auto-create profile row when a new Auth user signs up
--    This handles the case where signUp() creates the auth.users row
--    but the profiles INSERT has not happened yet.
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    -- Only insert if no profile exists yet (admin creates profile explicitly)
    INSERT INTO public.profiles (id, role)
    VALUES (NEW.id, 'employee')
    ON CONFLICT (id) DO NOTHING;
    RETURN NEW;
END;
$$;

-- Drop if exists to allow re-running this script
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ============================================================
-- 6. GRANT PERMISSIONS
--    The anon and authenticated roles need access to the tables
--    (RLS policies control actual row-level access).
-- ============================================================

GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.employees      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.attendance     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.leave_requests TO authenticated;


-- ============================================================
-- 7. CREATE THE FIRST ADMIN ACCOUNT
--    Do this AFTER running the above schema.
--    Replace the email and password values before running.
-- ============================================================

-- STEP A: Run this in the SQL Editor to create the Auth user:
--
--   SELECT * FROM auth.users;   -- verify no duplicate first
--
-- STEP B: Go to Supabase Dashboard → Authentication → Users
--         Click "Add user" and fill in:
--             Email:    admin@pms.local      (or any email you choose)
--             Password: (a strong password)
--         Click "Create user".
--
-- STEP C: Copy the UUID of the newly created user, then run:
--
--   INSERT INTO public.profiles (id, role)
--   VALUES ('<paste-uuid-here>', 'admin')
--   ON CONFLICT (id) DO UPDATE SET role = 'admin';
--
-- That's it. The admin can now log in at login.html.

-- ============================================================
-- END OF SCHEMA
-- ============================================================
