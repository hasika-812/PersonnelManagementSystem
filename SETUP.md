# Personnel Management System — Setup Guide (v2)

## Overview

This is a full-stack Personnel Management System built with:
- **Supabase** — PostgreSQL database, Auth, and Row Level Security
- Vanilla HTML / CSS / JavaScript frontend (no framework, no build step)
- Role-based access: Admin and Employee

All security is enforced at the database level using Row Level Security (RLS)
policies, not just in the frontend JavaScript.

---

## Files in This Project

| File | Purpose |
|---|---|
| `login.html` | Sign-in page for all users |
| `register.html` | Employee first-login / account activation page |
| `index.html` | Main app (admin dashboard + employee dashboard) |
| `style.css` | All styles |
| `script.js` | All frontend logic and Supabase API calls |
| `supabase_schema.sql` | Full database schema — run once in Supabase |
| `SETUP.md` | This file |

> **Important:** You must add your Supabase URL and anon key to THREE files:
> `login.html`, `register.html`, and `script.js`.
> All three need the same values.

---

## Step 1 — Create a Supabase Project

1. Go to [https://supabase.com](https://supabase.com) and sign in or create a free account.
2. Click **New project**.
3. Fill in a project name (e.g. `PersonnelManagementSystem`), set a database password
   (save it — you won't need it often but keep it safe), and pick a region.
4. Wait 1–2 minutes for the project to be ready.

---

## Step 2 — Disable Email Confirmation

Do this **before** creating any users, including the admin.

1. In your Supabase project, go to **Authentication → Settings**.
2. Find **"Enable email confirmations"** and turn it **OFF**.
3. Click **Save**.

If you skip this step, every new user (including admin) will need to click a
confirmation email before they can log in. For a college demo, turning this
off makes the process much smoother.

---

## Step 3 — Run the Database Schema

1. In your Supabase project, click **SQL Editor** in the left sidebar.
2. Click **New query**.
3. Open `supabase_schema.sql` from this project folder.
4. Select all the text and paste it into the SQL Editor.
5. Click **Run** (or press Ctrl+Enter / Cmd+Enter).
6. You should see **"Success. No rows returned."** for each statement.

This creates:
- `profiles` — user role storage (admin / employee) with RLS
- `employees` — employee details
- `attendance` — daily attendance records
- `leave_requests` — leave applications with Pending/Approved/Rejected status
- `get_my_role()` — a safe role-check helper function (avoids RLS recursion)
- `handle_new_user()` — trigger that creates a default profile for each new Auth user
- `claim_employee_account()` — RPC function used during employee first login

---

## Step 4 — Get Your API Keys

1. In your Supabase project, go to **Settings → API**.
2. Copy:
   - **Project URL** — looks like `https://abcdefghij.supabase.co`
   - **anon / public key** — a long string starting with `eyJ...`

> ⚠️ Use ONLY the `anon` / `public` key in your frontend files.
> Never put the `service_role` key in any browser file — it bypasses all security.

---

## Step 5 — Add Keys to Your Code

Open **each** of these three files and replace the two placeholder values:

```
login.html     (inside the <script> block near the bottom)
register.html  (inside the <script> block near the bottom)
script.js      (at the very top of the file)
```

In all three files, replace:

```javascript
const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_KEY = "YOUR_SUPABASE_ANON_KEY";
```

with your actual values:

```javascript
const SUPABASE_URL = "https://abcdefghij.supabase.co";
const SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...";
```

---

## Step 6 — Create the Admin Account

### 6A — Create the Auth user

1. In Supabase, go to **Authentication → Users**.
2. Click **Add user**.
3. Enter:
   - Email: `admin@pms.local` (or any email you prefer)
   - Password: choose a strong password and write it down
4. Click **Create user**.

At this point, the `handle_new_user()` trigger fires automatically and creates
a profile row with `role = 'employee'` (the safe default for every new user).

### 6B — Promote the profile row to admin

Go to **SQL Editor**, create a new query, and run:

```sql
INSERT INTO public.profiles (id, role)
VALUES ('<paste-the-admin-UUID-here>', 'admin')
ON CONFLICT (id) DO UPDATE SET role = 'admin';
```

Replace `<paste-the-admin-UUID-here>` with the UUID shown in the Users list
(the long `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` string in the ID column).

> ⚠️ You MUST use `ON CONFLICT (id) DO UPDATE SET role = 'admin'`.
> Using `DO NOTHING` would silently keep the role as 'employee' because the
> trigger already inserted that row. Your admin could never log in with the
> correct role if you use `DO NOTHING`.

### 6C — Verify

Run this in the SQL Editor:

```sql
SELECT id, role FROM public.profiles WHERE role = 'admin';
```

You should see exactly one row. If the result is empty, the `DO UPDATE` step
did not run correctly — check that you used the right UUID.

---

## Step 7 — Open the App and Test Admin Login

Open `login.html` in your browser.

**Recommended: use Live Server in VS Code**
- Install the "Live Server" extension.
- Right-click `login.html` → Open with Live Server.
- The app opens at `http://127.0.0.1:5500/login.html`.

Alternatively, double-click `login.html` in File Explorer.
Note: Some browsers block network requests on `file://` URLs.
If login fails immediately, switch to Live Server.

Log in with the admin email and password you set in Step 6.
You should see the admin dashboard with stat cards and navigation.

---

## Step 8 — Create Employee Accounts (via the App)

The admin creates employee records. Employees activate their own accounts
using a one-time invite token. This is secure because:

- The admin never creates Auth users directly from their browser
  (doing so via `signUp()` would silently sign the admin out).
- Employees set their own passwords — the admin never knows them.
- The invite token is single-use and stored in the database.

### Admin steps:

1. Log in as admin and go to **Add Employee**.
2. Fill in the Employee ID, name, email, department, designation, and salary.
3. Click **Add Employee**.
4. A popup will appear with the invite details:
   ```
   Employee ID   : EMP001
   Email         : john@company.com
   Invite Token  : A3F9C2B1
   ```
5. Write these down or copy them — you will give them to the employee.

### Employee steps:

1. Open `register.html` in a browser (or go to the link you share with them).
2. Enter:
   - Employee ID (exactly as given by admin, e.g. `EMP001`)
   - Email address (exactly as given by admin)
   - Invite Token (the code from the popup)
   - A new password (at least 8 characters)
   - Confirm password
3. Click **Activate Account**.
4. If successful, they are redirected to login.

The employee can now log in at `login.html` using their email and the
password they just set.

---

## Step 9 — Full Workflow Test

After setup, verify these scenarios manually:

| # | Test | Expected Result |
|---|---|---|
| 1 | Admin logs in | Reaches admin dashboard |
| 2 | Admin adds employee EMP001 | Invite token shown in popup |
| 3 | Employee activates via register.html | "Account Activated" shown |
| 4 | Employee logs in | Reaches employee dashboard with correct profile |
| 5 | Employee submits leave request | Appears in admin Leave Management |
| 6 | Admin approves leave | Employee sees "Approved" status after refresh |
| 7 | Admin marks attendance | Employee sees it in their attendance table |
| 8 | Employee logs out, logs back in | All data still visible (persists in DB) |
| 9 | Employee tries to access index.html without logging in | Redirected to login.html |
| 10 | Employee views only their own data | Cannot see other employees' records |

---

## Architecture (for Viva / Project Review)

```
┌──────────────────────────────────────────┐
│           Browser (Client Side)          │
│                                          │
│  login.html      register.html           │
│       │               │                  │
│       └───────┬────────┘                 │
│               ▼                          │
│          index.html + script.js          │
│          Supabase JS SDK (@v2)           │
└──────────────────────────────────────────┘
                 │ HTTPS
                 ▼
┌──────────────────────────────────────────┐
│             Supabase (Cloud)             │
│                                          │
│  ┌─────────────┐  ┌──────────────────┐  │
│  │  Auth       │  │  PostgreSQL DB   │  │
│  │  (JWT)      │  │                  │  │
│  └─────────────┘  │  profiles        │  │
│                   │  employees       │  │
│                   │  attendance      │  │
│                   │  leave_requests  │  │
│                   └──────────────────┘  │
│                                          │
│  Row Level Security on every table       │
│  get_my_role() avoids RLS recursion      │
└──────────────────────────────────────────┘
```

### Key concepts explained simply:

**Why Supabase?**
It gives us a real PostgreSQL database and authentication without needing to
run our own server. The frontend talks to Supabase directly over HTTPS.

**What is Row Level Security (RLS)?**
RLS rules are enforced inside the database itself. Even if someone bypasses
the frontend and sends a direct API request, the database will refuse to
return rows they are not allowed to see.

**Why `get_my_role()` instead of querying `profiles` directly in policies?**
RLS policies on the `profiles` table cannot safely query `profiles` again
inside themselves — PostgreSQL would recurse infinitely. The `get_my_role()`
function uses `SECURITY DEFINER` to bypass RLS and read the role safely
without recursion.

**Why the invite-token flow instead of admin calling `signUp()`?**
Calling `auth.signUp()` from the admin's browser session creates a new
session for the new employee, which silently replaces the admin's session.
After that, all subsequent database calls run as the employee (who has no
admin permissions) and fail. The invite-token approach avoids this entirely:
the employee activates their own account on their own device.

**What is `ON CONFLICT (id) DO UPDATE` vs `DO NOTHING`?**
The `handle_new_user()` trigger inserts every new Auth user with
`role = 'employee'`. When you later run the admin promotion SQL,
`DO NOTHING` would see the existing row and skip the update — leaving the
admin with an `employee` role and unable to access the admin dashboard.
`DO UPDATE SET role = 'admin'` correctly overrides the trigger's default.

---

## Required Configuration (3 files, same 2 values)

| Variable | Where to find it |
|---|---|
| `SUPABASE_URL` | Supabase → Settings → API → Project URL |
| `SUPABASE_KEY` | Supabase → Settings → API → anon / public key |

Files that need these values: `login.html`, `register.html`, `script.js`

The `anon` key is safe to include in frontend code.
Security is enforced by RLS policies, not by keeping this key secret.

---

## Troubleshooting

**"Supabase Not Configured" screen**
→ You have not replaced the placeholder URL/key in one or more files.
   Check all three: `login.html`, `register.html`, `script.js`.

**Admin logs in but is sent back to `login.html` in a loop**
→ The profile row was not promoted to admin. Run the SQL in Step 6B.
   Make sure you used `DO UPDATE SET role = 'admin'`, not `DO NOTHING`.

**"Could not load your profile" error on index.html**
→ The profiles row is missing or has the wrong `id`.
   Run `SELECT * FROM public.profiles;` in SQL Editor to inspect.

**Employee activation says "Employee ID not found"**
→ The Employee ID the employee entered does not exactly match what
   admin entered. Check for extra spaces or case differences.
   Employee ID lookup is case-sensitive — enter it exactly as shown.

**Employee activation says "Account has already been claimed"**
→ The account was already activated. The employee should use `login.html`.

**Employee activation says "Invalid invite token"**
→ The token was mistyped. Admin can click "Show Invite" in Employee
   Records to view the token again (if not yet claimed).

**Invite token not shown / lost**
→ Admin goes to Employee Records and clicks "Show Invite" next to any
   unclaimed account (shown with "Pending claim" badge).

**Employee logs in but sees no profile data**
→ The `claim_employee_account()` RPC did not link the `auth_user_id`
   correctly. Check that `register.html` ran successfully without errors.

**App works on Live Server but not on double-clicked `file://`**
→ Some browsers block `fetch()` on file:// URLs.
   Use Live Server, or deploy to Netlify (drag and drop the folder at
   https://app.netlify.com/drop).

---

## Known Limitations

1. **No password reset UI** — employees cannot change their password from
   within the app. They would need to use Supabase's built-in password
   reset email flow, which requires email confirmation to be enabled.

2. **One admin only** — the system is designed for a single admin account.
   Multiple admins can be added by running the SQL promotion command again,
   but there is no in-app UI for this.

3. **Invite token delivered manually** — in a real system this token would
   be emailed automatically. Here the admin copies and pastes it.
   This is intentional to keep the project simple.

4. **Leave balance based on attendance status** — leave balance is
   calculated from attendance records marked as "Leave" by admin,
   not directly from approved leave requests. Both systems are
   consistent as long as admin updates attendance when leave is approved.
