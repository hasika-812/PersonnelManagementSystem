# Personnel Management System — Setup Guide

## What Was Built

A full-stack Personnel Management System with:
- **Supabase** (PostgreSQL + Auth) as the backend
- Vanilla HTML/CSS/JavaScript frontend
- Role-based access: Admin and Employee
- Persistent database storage (survives logout, refresh, device change)
- Real authentication (email + password via Supabase Auth)
- Row Level Security — employees can only see their own data

---

## Project Files

| File | Purpose |
|---|---|
| `login.html` | Login page (Supabase Auth) |
| `index.html` | Main app (admin + employee views) |
| `style.css` | All styling |
| `script.js` | All frontend logic + Supabase API calls |
| `supabase_schema.sql` | Database schema — run once in Supabase SQL Editor |
| `SETUP.md` | This file |

---

## Step 1 — Create a Supabase Project

1. Go to [https://supabase.com](https://supabase.com) and sign up for a free account.
2. Click **New Project**.
3. Choose a name (e.g. `PersonnelManagementSystem`), set a database password (save it somewhere), pick the closest region.
4. Wait about 1–2 minutes for the project to initialize.

---

## Step 2 — Run the Database Schema

1. In your Supabase project, click **SQL Editor** in the left sidebar.
2. Click **New query**.
3. Open `supabase_schema.sql` from this folder and paste the entire contents into the SQL Editor.
4. Click **Run** (or press Ctrl+Enter).
5. You should see "Success. No rows returned." — that means it worked.

This creates four tables:
- `profiles` — one row per user, stores their role (admin/employee)
- `employees` — employee details (name, department, salary, etc.)
- `attendance` — daily attendance records
- `leave_requests` — employee leave applications with Pending/Approved/Rejected status

---

## Step 3 — Get Your API Keys

1. In your Supabase project, go to **Settings → API** (in the left sidebar).
2. Copy two values:
   - **Project URL** — looks like `https://xyzxyzxyz.supabase.co`
   - **anon/public key** — a long string starting with `eyJ...`

> ⚠️ Never share the `service_role` key. Only use the `anon` key in your frontend code.

---

## Step 4 — Add Keys to Your Code

Open **both** of these files and replace the two placeholder values:

### `login.html` (near the bottom, inside `<script>`)

```javascript
const SUPABASE_URL = "https://your-project-id.supabase.co";
const SUPABASE_KEY = "eyJhbGci...your-anon-key...";
```

### `script.js` (at the very top)

```javascript
const SUPABASE_URL = "https://your-project-id.supabase.co";
const SUPABASE_KEY = "eyJhbGci...your-anon-key...";
```

Make sure you replace both files. They both need the same values.

---

## Step 5 — Create the Admin Account

1. In Supabase, go to **Authentication → Users** (left sidebar).
2. Click **Add user**.
3. Enter:
   - **Email**: `admin@pms.local` (or any email you want)
   - **Password**: choose a strong password (you'll use this to log in)
4. Click **Create user**.
5. The user is created. Now copy the **UUID** shown in the users list (the long `xxxxxxxx-xxxx-...` string in the ID column).
6. Go back to **SQL Editor**, create a new query, and run:

```sql
INSERT INTO public.profiles (id, role)
VALUES ('PASTE-YOUR-UUID-HERE', 'admin')
ON CONFLICT (id) DO UPDATE SET role = 'admin';
```

Replace `PASTE-YOUR-UUID-HERE` with the actual UUID. Now this account has admin access.

---

## Step 6 — Open the App

Since this is a static HTML project, open it one of these ways:

**Option A — Live Server (VS Code)**
- Install the "Live Server" extension in VS Code.
- Right-click `login.html` → Open with Live Server.
- The app opens at `http://127.0.0.1:5500/login.html`.

**Option B — Direct browser open**
- Double-click `login.html` in File Explorer.
- Note: Some browsers block `fetch()` on `file://` URLs. If login fails, use Live Server instead.

**Option C — Deploy to Netlify / GitHub Pages (optional)**
- Drag the entire project folder to [https://app.netlify.com/drop](https://app.netlify.com/drop) for a free live URL.

---

## Step 7 — Test the App

### Admin flow:
1. Open `login.html`.
2. Log in with the admin email + password you set.
3. You should see the admin dashboard.
4. Go to **Add Employee** and create an employee:
   - Set an Employee ID (e.g. `EMP001`)
   - Set their email (e.g. `john@company.com`)
   - Set an initial password (at least 8 characters)
5. Go to **Employee Records** to confirm the employee appears.
6. Go to **Attendance** and mark attendance for that employee.
7. Go to **Leave Management** to see/approve leave requests.

### Employee flow:
1. Open `login.html` in a different browser or incognito window.
2. Log in with the employee's email and the password you set.
3. You should see the employee dashboard with their profile.
4. Their attendance summary should reflect the records entered by admin.
5. Submit a leave request.
6. Switch back to admin — the leave request should appear.
7. Approve/reject it.
8. Refresh the employee view — the status should update.

---

## Architecture Explanation (for Viva)

```
┌─────────────────────────────────────────────┐
│              Browser (Client)               │
│                                             │
│  login.html ──────→ index.html              │
│                         │                   │
│                    script.js                │
│                         │                   │
│          Supabase JS SDK (@supabase/supabase-js)
└─────────────────────────────────────────────┘
                          │
                    HTTPS / REST
                          │
┌─────────────────────────────────────────────┐
│              Supabase (Cloud)               │
│                                             │
│  ┌──────────────┐   ┌─────────────────────┐ │
│  │  Auth Service│   │   PostgreSQL DB     │ │
│  │  (JWT tokens)│   │                     │ │
│  └──────────────┘   │  profiles           │ │
│                     │  employees          │ │
│                     │  attendance         │ │
│                     │  leave_requests     │ │
│                     └─────────────────────┘ │
│                                             │
│  Row Level Security (RLS) enforced on all   │
│  tables — employees cannot access other     │
│  employees' data even if they try directly  │
└─────────────────────────────────────────────┘
```

### Key concepts for your viva:

**Why Supabase?**
It provides a full PostgreSQL database and authentication as a managed cloud service. We don't need to run our own server — the frontend talks directly to Supabase over HTTPS using their JavaScript SDK.

**What is Row Level Security (RLS)?**
It's a PostgreSQL feature that adds security rules at the database level. Even if someone bypasses the frontend and sends a direct API request, the database itself will block them from seeing records they don't own. For example, an employee trying to query another employee's leave requests will get an empty result.

**Why not localStorage?**
localStorage is stored in the browser on one device. If admin adds an employee on their computer and that employee tries to log in from their own computer, they would find no data. It also has zero security — anyone with DevTools access can read and modify everything.

**Authentication flow:**
1. User enters email + password in `login.html`.
2. Supabase verifies credentials and returns a JWT token.
3. The token is stored automatically by the Supabase SDK.
4. Every subsequent API call includes the token in the Authorization header.
5. Supabase checks the token and applies RLS policies accordingly.

---

## Environment Variables

| Variable | Where to find it | Used in |
|---|---|---|
| `SUPABASE_URL` | Supabase → Settings → API → Project URL | `login.html`, `script.js` |
| `SUPABASE_KEY` | Supabase → Settings → API → anon/public | `login.html`, `script.js` |

> These are safe to include in frontend code. The `anon` key is publicly accessible by design. Security is enforced by RLS policies, not by keeping the key secret.

---

## Known Limitations

1. **Email confirmation**: By default Supabase requires users to confirm their email before logging in. For a college demo, disable this under **Authentication → Settings → Email Confirmations → Disable**.
2. **Admin creates employee Auth accounts**: When admin adds an employee, `signUp()` is called which creates the Auth user. This works but the employee will briefly get a "New sign-up" confirmation email if email confirmation is enabled (see point 1).
3. **Password reset**: No UI for employees to change their password — not in scope for this version.
4. **One admin only**: The system is designed for one admin. Multiple admins would work (just mark multiple profiles as `role = 'admin'`) but there's no UI to manage admin accounts.
5. **File-based serving**: `fetch()` calls may fail on some browsers when opened as `file://`. Use Live Server or deploy to Netlify.

---

## Troubleshooting

**"Supabase Not Configured" screen on index.html or login.html**
→ You haven't replaced `YOUR_SUPABASE_URL` and `YOUR_SUPABASE_ANON_KEY` in both files.

**Login says "Incorrect email or password"**
→ Double-check you created the admin user in Supabase → Authentication → Users and set the correct email/password.

**Admin logs in but sees "Could not load your profile"**
→ You forgot to run the SQL INSERT for the profiles table (Step 5 above).

**Employee can't log in**
→ Make sure you disabled email confirmation in Supabase (Authentication → Settings). If email confirmation is enabled, the employee must click the confirmation link in their email first.

**"Failed to load employees" toast appears**
→ Check that you ran the full `supabase_schema.sql` correctly. Open Supabase → Table Editor and verify that the `employees`, `attendance`, `leave_requests`, and `profiles` tables exist.

**Attendance duplicate error**
→ This is intentional. Each employee can only have one attendance record per date.
