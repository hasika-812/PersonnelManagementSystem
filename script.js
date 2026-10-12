/* ============================================================
   Personnel Management System — Main Script  (v2)
   Backend: Supabase (PostgreSQL + Auth + RLS)

   HOW TO CONFIGURE:
   1. Create a project at https://supabase.com
   2. Run supabase_schema.sql in the SQL Editor
   3. Replace the two constants below:
      SUPABASE_URL  → Settings → API → Project URL
      SUPABASE_KEY  → Settings → API → anon/public key   ← NOT the service key
   4. Follow SETUP.md for the complete walkthrough.
   ============================================================ */

const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_KEY = "YOUR_SUPABASE_ANON_KEY";

/* ---- Guard: show clear error if not yet configured ---- */
if (
    SUPABASE_URL === "YOUR_SUPABASE_URL" ||
    SUPABASE_KEY === "YOUR_SUPABASE_ANON_KEY"
) {
    document.body.innerHTML =
        `<div style="font-family:Arial;max-width:600px;margin:60px auto;padding:30px;
                     background:#fff;border-radius:12px;box-shadow:0 4px 20px #0002;">
            <h2 style="color:#c0392b;">⚠ Supabase Not Configured</h2>
            <p>Open <strong>script.js</strong> and replace the two placeholder values at the top:</p>
            <ul>
                <li><code>SUPABASE_URL</code> — your Supabase Project URL</li>
                <li><code>SUPABASE_KEY</code> — your Supabase anon/public key</li>
            </ul>
            <p>Both values are in your Supabase dashboard under <strong>Settings → API</strong>.</p>
            <p>See <strong>SETUP.md</strong> for full instructions.</p>
        </div>`;
    throw new Error("Supabase not configured. See SETUP.md.");
}

/* ============================================================
   SUPABASE CLIENT
   ============================================================ */
const { createClient } = supabase;
const db = createClient(SUPABASE_URL, SUPABASE_KEY);

/* ============================================================
   UI HELPERS
   ============================================================ */

function setLoading(visible) {
    const overlay = document.getElementById("loadingOverlay");
    if (!overlay) return;
    overlay.style.display = visible ? "flex" : "none";
}

let toastTimer = null;

function showToast(message, type = "info", duration = 3500) {
    let toast = document.getElementById("toast");
    if (!toast) {
        toast = document.createElement("div");
        toast.id = "toast";
        document.body.appendChild(toast);
    }
    toast.textContent = message;
    toast.className = "show " + type;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { toast.className = ""; }, duration);
}

function setFieldError(elementId, message) {
    const el = document.getElementById(elementId);
    if (el) el.textContent = message;
}

function clearFieldError(elementId) {
    const el = document.getElementById(elementId);
    if (el) el.textContent = "";
}

function setBtnLoading(btnId, isLoading, defaultText) {
    const btn = document.getElementById(btnId);
    if (!btn) return;
    btn.disabled = isLoading;
    btn.textContent = isLoading ? "Please wait…" : defaultText;
}

function makeBadge(status) {
    const span = document.createElement("span");
    span.className = "badge badge-" + (status || "").toLowerCase();
    span.textContent = status;
    return span;
}

/** Return today's date as YYYY-MM-DD */
function todayISO() {
    const d = new Date();
    return [
        d.getFullYear(),
        String(d.getMonth() + 1).padStart(2, "0"),
        String(d.getDate()).padStart(2, "0")
    ].join("-");
}

/* ============================================================
   SESSION & ROUTING
   ============================================================ */

let currentSession = null;   // Supabase Auth session
let currentProfile = null;   // Row from `profiles` table
let currentRole    = null;   // "admin" | "employee"

async function initApp() {
    setLoading(true);
    try {
        const { data: { session } } = await db.auth.getSession();

        if (!session) {
            window.location.replace("login.html");
            return;
        }

        currentSession = session;

        const { data: profile, error: profileErr } =
            await db.from("profiles")
                    .select("*")
                    .eq("id", session.user.id)
                    .single();

        if (profileErr || !profile) {
            console.error("Profile load error:", profileErr);
            /* Profile missing — sign out cleanly rather than looping */
            await logout();
            return;
        }

        currentProfile = profile;
        currentRole    = profile.role;

        injectLogoutButton();

        if (currentRole === "admin") {
            setupAdminView();
        } else {
            setupEmployeeView();
        }
    } catch (err) {
        console.error("Init error:", err);
        showToast("Failed to load application. Please refresh.", "error");
    } finally {
        setLoading(false);
    }
}

function injectLogoutButton() {
    if (document.getElementById("logoutButton")) return;
    const btn = document.createElement("button");
    btn.id        = "logoutButton";
    btn.textContent = "Logout";
    btn.onclick   = logout;
    document.querySelector("header")?.appendChild(btn);
}

async function logout() {
    await db.auth.signOut();
    window.location.replace("login.html");
}

/* ============================================================
   ADMIN VIEW
   ============================================================ */

function setupAdminView() {
    document.getElementById("adminNav").style.display          = "";
    document.getElementById("dashboard").style.display         = "";
    document.getElementById("addEmployee").style.display       = "";
    document.getElementById("employeeRecords").style.display   = "";
    document.getElementById("attendance").style.display        = "";
    document.getElementById("leaveManagement").style.display   = "";
    document.getElementById("employeeDashboard").style.display = "none";

    wireAddEmployeeForm();
    wireEditEmployeeForm();
    wireAttendanceForm();

    loadDashboardStats();
    loadEmployees();
    loadAttendanceRecords();
    loadAdminLeaveRequests();

    const attDate = document.getElementById("attendanceDate");
    if (attDate) attDate.valueAsDate = new Date();
}

/* ============================================================
   ADMIN — DASHBOARD STATS
   ============================================================ */

async function loadDashboardStats() {
    try {
        const [empResult, leaveResult, attResult] = await Promise.all([
            db.from("employees").select("id", { count: "exact", head: true }),
            db.from("leave_requests")
              .select("id", { count: "exact", head: true })
              .eq("status", "Pending"),
            db.from("attendance")
              .select("id", { count: "exact", head: true })
              .eq("date", todayISO())
              .eq("status", "Present")
        ]);

        const el = (id, val) => {
            const node = document.getElementById(id);
            if (node) node.textContent = val ?? "—";
        };
        el("statTotalEmployees", empResult.count);
        el("statPendingLeaves",  leaveResult.count);
        el("statTodayPresent",   attResult.count);
    } catch (err) {
        console.error("Stats error:", err);
    }
}

/* ============================================================
   ADMIN — EMPLOYEE MANAGEMENT
   ============================================================ */

let allEmployees = [];

async function loadEmployees() {
    try {
        const { data, error } = await db
            .from("employees")
            .select("*")
            .order("employee_id", { ascending: true });

        if (error) throw error;
        allEmployees = data || [];
        renderEmployeeTable(allEmployees);
        populateAttendanceDropdown(allEmployees);
    } catch (err) {
        console.error("Load employees error:", err);
        showToast("Failed to load employees.", "error");
    }
}

function renderEmployeeTable(data) {
    const tbody    = document.getElementById("employeeList");
    const emptyMsg = document.getElementById("emptyMessage");
    if (!tbody) return;

    tbody.replaceChildren();

    const searchVal = (
        document.getElementById("searchEmployee")?.value || ""
    ).trim().toLowerCase();

    const filtered = searchVal
        ? data.filter(e =>
            [e.employee_id, e.name, e.email, e.department, e.designation]
                .some(v => String(v || "").toLowerCase().includes(searchVal))
          )
        : data;

    if (emptyMsg) {
        emptyMsg.textContent = filtered.length === 0
            ? (data.length === 0 ? "No employees added yet." : "No matching employees.")
            : "";
    }

    filtered.forEach(emp => {
        const tr = document.createElement("tr");

        [
            emp.employee_id,
            emp.name,
            emp.email,
            emp.department,
            emp.designation,
            "₹" + Number(emp.salary).toLocaleString("en-IN")
        ].forEach(val => {
            const td = document.createElement("td");
            td.textContent = val ?? "";
            tr.appendChild(td);
        });

        /* Invite token indicator */
        const tokenTd = document.createElement("td");
        if (!emp.auth_user_id) {
            /* Account not yet claimed — show the token for the admin to share */
            tokenTd.innerHTML =
                `<span style="font-size:12px;color:#856404;background:#fff3cd;
                              padding:3px 8px;border-radius:10px;">
                    Pending claim
                </span>`;
        } else {
            tokenTd.innerHTML =
                `<span style="font-size:12px;color:#1a6633;background:#d1f0da;
                              padding:3px 8px;border-radius:10px;">
                    Active
                </span>`;
        }
        tr.appendChild(tokenTd);

        const actionTd = document.createElement("td");

        const editBtn = document.createElement("button");
        editBtn.textContent  = "Edit";
        editBtn.className    = "edit-btn";
        editBtn.onclick      = () => openEditModal(emp);

        const delBtn = document.createElement("button");
        delBtn.textContent   = "Delete";
        delBtn.className     = "delete-btn";
        delBtn.style.marginLeft = "6px";
        delBtn.onclick       = () => confirmDeleteEmployee(emp);

        /* Show invite details button only for unclaimed accounts */
        if (!emp.auth_user_id) {
            const inviteBtn = document.createElement("button");
            inviteBtn.textContent = "Show Invite";
            inviteBtn.style.cssText =
                "margin-left:6px;background:#856404;color:white;";
            inviteBtn.onclick = () => showInviteDetails(emp);
            actionTd.appendChild(inviteBtn);
        }

        actionTd.appendChild(editBtn);
        actionTd.appendChild(delBtn);
        tr.appendChild(actionTd);
        tbody.appendChild(tr);
    });
}

/**
 * Show the admin the invite token so they can pass it to the employee.
 * Queries employees.invite_token — the token now lives there, not in profiles.
 */
async function showInviteDetails(emp) {
    const { data: row, error } = await db
        .from("employees")
        .select("invite_token")
        .eq("employee_id", emp.employee_id)
        .single();

    if (error || !row?.invite_token) {
        showToast("Invite token not available (account may already be active).", "error");
        return;
    }

    alert(
        `Invite details for ${emp.name} (${emp.employee_id})\n\n` +
        `Tell the employee to open register.html and enter:\n\n` +
        `  Employee ID   : ${emp.employee_id}\n` +
        `  Email         : ${emp.email}\n` +
        `  Invite Token  : ${row.invite_token}\n\n` +
        `They will set their own password on that page.`
    );
}

const searchInput = document.getElementById("searchEmployee");
if (searchInput) {
    searchInput.addEventListener("input", () => renderEmployeeTable(allEmployees));
}

/* ---- Add Employee ---- */

function wireAddEmployeeForm() {
    const form = document.getElementById("employeeForm");
    if (!form) return;

    form.addEventListener("submit", async function (e) {
        e.preventDefault();
        clearFieldError("addEmployeeMessage");

        const empId       = document.getElementById("empId").value.trim();
        const name        = document.getElementById("empName").value.trim();
        const email       = document.getElementById("empEmail").value.trim().toLowerCase();
        const department  = document.getElementById("empDepartment").value;
        const designation = document.getElementById("empDesignation").value.trim();
        const salary      = Number(document.getElementById("empSalary").value);

        /* Client-side validation */
        if (!empId || !name || !email || !department || !designation) {
            setFieldError("addEmployeeMessage", "All fields are required.");
            return;
        }
        if (!email.includes("@") || !email.includes(".")) {
            setFieldError("addEmployeeMessage", "Enter a valid email address.");
            return;
        }
        if (!Number.isFinite(salary) || salary < 0) {
            setFieldError("addEmployeeMessage", "Enter a valid salary.");
            return;
        }

        setBtnLoading("addEmpBtn", true, "Add Employee");

        try {
            /*
             * HOW EMPLOYEE ACCOUNTS WORK (Invite-Token Flow):
             *
             * Calling auth.signUp() from the admin's browser session
             * would silently sign the admin OUT and sign the new
             * employee IN — breaking the admin's active session.
             * This is a fundamental limitation of the Supabase JS
             * client in a browser context.
             *
             * Instead we use an invite-token approach:
             *   1. Admin creates the employee record (no Auth user yet).
             *   2. A random token is generated and stored in profiles.
             *   3. Admin shares the Employee ID + token with the employee.
             *   4. Employee opens register.html, enters their details,
             *      and calls signUp() themselves.
             *   5. A database function links the new Auth user to the
             *      existing employee record and consumes the token.
             *
             * This is the standard invite flow used in production apps.
             */

            /*
             * Generate a random 12-hex-character invite token.
             * Stored in employees.invite_token (NOT in profiles).
             *
             * Why not profiles?
             * profiles.id is a FK → auth.users(id).  A placeholder
             * UUID with no matching auth.users row would immediately
             * fail with a foreign-key violation.  employees has no
             * such constraint on its own PK, so the token lives here
             * safely until the employee claims their account.
             */
            const inviteToken = Array.from(
                crypto.getRandomValues(new Uint8Array(6))
            ).map(b => b.toString(16).padStart(2, "0")).join("").toUpperCase();

            /* Insert the employee record with the token.
               auth_user_id is NULL until the employee activates. */
            const { error: empErr } = await db.from("employees").insert({
                auth_user_id: null,
                employee_id:  empId,
                name,
                email,
                department,
                designation,
                salary,
                invite_token: inviteToken
            });

            if (empErr) {
                if (empErr.code === "23505") {
                    const detail = empErr.details || empErr.message || "";
                    if (detail.toLowerCase().includes("employee_id")) {
                        setFieldError("addEmployeeMessage",
                            "Employee ID already exists. Choose a different ID.");
                    } else if (detail.toLowerCase().includes("email")) {
                        setFieldError("addEmployeeMessage",
                            "An employee with this email already exists.");
                    } else {
                        setFieldError("addEmployeeMessage",
                            "Duplicate entry. Check Employee ID and email.");
                    }
                } else {
                    setFieldError("addEmployeeMessage",
                        "Database error: " + empErr.message);
                }
                return;
            }

            form.reset();
            clearFieldError("addEmployeeMessage");

            /* Show the admin the invite token immediately */
            alert(
                `Employee "${name}" added successfully!\n\n` +
                `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n` +
                `Share these details with the employee:\n\n` +
                `  Employee ID   : ${empId}\n` +
                `  Email         : ${email}\n` +
                `  Invite Token  : ${inviteToken}\n\n` +
                `The employee opens register.html and uses these\n` +
                `details to set their password and activate their account.\n` +
                `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`
            );

            await loadEmployees();
            await loadDashboardStats();

        } catch (err) {
            console.error("Add employee error:", err);
            setFieldError("addEmployeeMessage",
                "Unexpected error: " + err.message);
        } finally {
            setBtnLoading("addEmpBtn", false, "Add Employee");
        }
    });
}

/* ---- Edit Employee Modal ---- */

function openEditModal(emp) {
    document.getElementById("editEmpDbId").value        = emp.id;
    document.getElementById("editEmpId").value          = emp.employee_id;
    document.getElementById("editEmpName").value        = emp.name;
    document.getElementById("editEmpEmail").value       = emp.email;
    document.getElementById("editEmpDepartment").value  = emp.department;
    document.getElementById("editEmpDesignation").value = emp.designation;
    document.getElementById("editEmpSalary").value      = emp.salary;
    clearFieldError("editMessage");

    document.getElementById("editModal").style.display = "flex";
}

function closeEditModal() {
    document.getElementById("editModal").style.display = "none";
}

function wireEditEmployeeForm() {
    const form = document.getElementById("editEmployeeForm");
    if (!form) return;

    form.addEventListener("submit", async function (e) {
        e.preventDefault();
        clearFieldError("editMessage");

        const dbId        = document.getElementById("editEmpDbId").value;
        const empId       = document.getElementById("editEmpId").value.trim();
        const name        = document.getElementById("editEmpName").value.trim();
        const email       = document.getElementById("editEmpEmail").value.trim().toLowerCase();
        const department  = document.getElementById("editEmpDepartment").value;
        const designation = document.getElementById("editEmpDesignation").value.trim();
        const salary      = Number(document.getElementById("editEmpSalary").value);

        if (!empId || !name || !email || !department || !designation) {
            setFieldError("editMessage", "All fields are required.");
            return;
        }
        if (!Number.isFinite(salary) || salary < 0) {
            setFieldError("editMessage", "Enter a valid salary.");
            return;
        }

        setBtnLoading("saveEditBtn", true, "Save Changes");

        try {
            const { error } = await db
                .from("employees")
                .update({ employee_id: empId, name, email, department, designation, salary })
                .eq("id", dbId);

            if (error) {
                if (error.code === "23505") {
                    setFieldError("editMessage",
                        "Employee ID or email conflicts with another record.");
                } else {
                    setFieldError("editMessage", "Update failed: " + error.message);
                }
                return;
            }

            closeEditModal();
            showToast("Employee updated successfully.", "success");
            await loadEmployees();
            await loadDashboardStats();

        } catch (err) {
            setFieldError("editMessage", "Unexpected error: " + err.message);
        } finally {
            setBtnLoading("saveEditBtn", false, "Save Changes");
        }
    });
}

async function confirmDeleteEmployee(emp) {
    if (!confirm(
        `Delete employee "${emp.name}" (${emp.employee_id})?\n\n` +
        "This will also remove their attendance records and leave requests."
    )) return;

    setLoading(true);
    try {
        /* ON DELETE CASCADE on attendance and leave_requests handles
           the related rows automatically. */
        const { error } = await db
            .from("employees")
            .delete()
            .eq("id", emp.id);

        if (error) throw error;

        showToast("Employee deleted.", "info");
        await loadEmployees();
        await loadAttendanceRecords();
        await loadAdminLeaveRequests();
        await loadDashboardStats();
    } catch (err) {
        console.error("Delete error:", err);
        showToast("Delete failed: " + err.message, "error");
    } finally {
        setLoading(false);
    }
}

/* ============================================================
   ADMIN — ATTENDANCE
   ============================================================ */

function populateAttendanceDropdown(employees) {
    const select = document.getElementById("attendanceEmployee");
    if (!select) return;

    select.replaceChildren();
    const defaultOpt = document.createElement("option");
    defaultOpt.value       = "";
    defaultOpt.textContent = "Select Employee";
    select.appendChild(defaultOpt);

    employees.forEach(emp => {
        const opt = document.createElement("option");
        opt.value       = emp.id;
        opt.textContent = emp.employee_id + " – " + emp.name;
        select.appendChild(opt);
    });
}

let allAttendanceRecords = [];

async function loadAttendanceRecords(filterEmpId = null, filterDate = null) {
    try {
        let query = db
            .from("attendance")
            .select(`
                id,
                date,
                status,
                employees ( employee_id, name )
            `)
            .order("date", { ascending: false });

        if (filterEmpId) {
            const emp = allEmployees.find(
                e => e.employee_id.toLowerCase() === filterEmpId.toLowerCase()
            );
            if (emp) {
                query = query.eq("employee_id_fk", emp.id);
            } else {
                renderAttendanceTable([]);
                return;
            }
        }

        if (filterDate) {
            query = query.eq("date", filterDate);
        }

        const { data, error } = await query;
        if (error) throw error;

        allAttendanceRecords = data || [];
        renderAttendanceTable(allAttendanceRecords);
    } catch (err) {
        console.error("Load attendance error:", err);
        showToast("Failed to load attendance records.", "error");
    }
}

function renderAttendanceTable(records) {
    const tbody = document.getElementById("attendanceList");
    const msg   = document.getElementById("attendanceMessage");
    if (!tbody) return;

    tbody.replaceChildren();

    if (msg) msg.textContent = records.length === 0
        ? "No attendance records yet." : "";

    records.forEach(rec => {
        const tr  = document.createElement("tr");
        const emp = rec.employees || {};

        [emp.employee_id ?? "—", emp.name ?? "—", rec.date].forEach(val => {
            const td = document.createElement("td");
            td.textContent = val;
            tr.appendChild(td);
        });

        const statusTd = document.createElement("td");
        statusTd.appendChild(makeBadge(rec.status));
        tr.appendChild(statusTd);

        const actionTd = document.createElement("td");
        const delBtn   = document.createElement("button");
        delBtn.textContent = "Delete";
        delBtn.className   = "delete-btn";
        delBtn.onclick     = () => deleteAttendanceRecord(rec.id);
        actionTd.appendChild(delBtn);
        tr.appendChild(actionTd);

        tbody.appendChild(tr);
    });
}

async function deleteAttendanceRecord(id) {
    if (!confirm("Delete this attendance record?")) return;
    try {
        const { error } = await db.from("attendance").delete().eq("id", id);
        if (error) throw error;
        showToast("Attendance record deleted.", "info");
        await loadAttendanceRecords();
        await loadDashboardStats();
    } catch (err) {
        showToast("Delete failed: " + err.message, "error");
    }
}

function applyAttendanceFilter() {
    const empId = document.getElementById("filterAttEmployee")?.value.trim();
    const date  = document.getElementById("filterAttDate")?.value;
    loadAttendanceRecords(empId || null, date || null);
}

function clearAttendanceFilter() {
    const ef = document.getElementById("filterAttEmployee");
    const df = document.getElementById("filterAttDate");
    if (ef) ef.value = "";
    if (df) df.value = "";
    loadAttendanceRecords();
}

function wireAttendanceForm() {
    const form = document.getElementById("attendanceForm");
    if (!form) return;

    form.addEventListener("submit", async function (e) {
        e.preventDefault();
        clearFieldError("attendanceFormMessage");

        const empDbId = document.getElementById("attendanceEmployee").value;
        const date    = document.getElementById("attendanceDate").value;
        const status  = document.getElementById("attendanceStatus").value;

        if (!empDbId || !date) {
            setFieldError("attendanceFormMessage",
                "Please select an employee and date.");
            return;
        }

        setBtnLoading("saveAttendanceBtn", true, "Save Attendance");

        try {
            /* Check for duplicate before insert */
            const { data: existing } = await db
                .from("attendance")
                .select("id")
                .eq("employee_id_fk", empDbId)
                .eq("date", date)
                .maybeSingle();

            if (existing) {
                setFieldError("attendanceFormMessage",
                    "Attendance already recorded for this employee on that date.");
                return;
            }

            const { error } = await db.from("attendance").insert({
                employee_id_fk: empDbId,
                date,
                status
            });

            if (error) throw error;

            form.reset();
            document.getElementById("attendanceDate").valueAsDate = new Date();
            showToast("Attendance saved.", "success");
            await loadAttendanceRecords();
            await loadDashboardStats();

        } catch (err) {
            setFieldError("attendanceFormMessage", "Error: " + err.message);
        } finally {
            setBtnLoading("saveAttendanceBtn", false, "Save Attendance");
        }
    });
}

/* ============================================================
   ADMIN — LEAVE MANAGEMENT
   ============================================================ */

async function loadAdminLeaveRequests() {
    try {
        const { data, error } = await db
            .from("leave_requests")
            .select(`
                id,
                start_date,
                end_date,
                reason,
                status,
                created_at,
                employees ( employee_id, name )
            `)
            .order("created_at", { ascending: false });

        if (error) throw error;
        renderAdminLeaveTable(data || []);
    } catch (err) {
        console.error("Load leave error:", err);
        showToast("Failed to load leave requests.", "error");
    }
}

function renderAdminLeaveTable(requests) {
    const tbody = document.getElementById("leaveList");
    const msg   = document.getElementById("leaveMessage");
    if (!tbody) return;

    tbody.replaceChildren();

    if (msg) msg.textContent = requests.length === 0
        ? "No leave requests yet." : "";

    requests.forEach(req => {
        const tr  = document.createElement("tr");
        const emp = req.employees || {};

        [
            emp.employee_id ?? "—",
            emp.name        ?? "—",
            req.start_date,
            req.end_date,
            req.reason
        ].forEach(val => {
            const td = document.createElement("td");
            td.textContent = val;
            tr.appendChild(td);
        });

        const statusTd = document.createElement("td");
        statusTd.appendChild(makeBadge(req.status));
        tr.appendChild(statusTd);

        const actionTd = document.createElement("td");

        if (req.status === "Pending") {
            const approveBtn = document.createElement("button");
            approveBtn.textContent    = "Approve";
            approveBtn.className      = "approve-btn";
            approveBtn.onclick        = () => updateLeaveStatus(req.id, "Approved");

            const rejectBtn = document.createElement("button");
            rejectBtn.textContent     = "Reject";
            rejectBtn.className       = "reject-btn";
            rejectBtn.style.marginLeft = "6px";
            rejectBtn.onclick         = () => updateLeaveStatus(req.id, "Rejected");

            actionTd.appendChild(approveBtn);
            actionTd.appendChild(rejectBtn);
        } else {
            actionTd.textContent = "—";
        }

        tr.appendChild(actionTd);
        tbody.appendChild(tr);
    });
}

async function updateLeaveStatus(requestId, newStatus) {
    try {
        const { error } = await db
            .from("leave_requests")
            .update({ status: newStatus })
            .eq("id", requestId)
            .eq("status", "Pending");   /* DB-side safety: only update Pending rows */

        if (error) throw error;

        showToast("Leave request " + newStatus.toLowerCase() + ".", "success");
        await loadAdminLeaveRequests();
        await loadDashboardStats();
    } catch (err) {
        console.error("Update leave status error:", err);
        showToast("Failed to update leave status.", "error");
    }
}

/* ============================================================
   EMPLOYEE VIEW
   ============================================================ */

async function setupEmployeeView() {
    document.getElementById("adminNav").style.display          = "none";
    document.getElementById("dashboard").style.display         = "none";
    document.getElementById("addEmployee").style.display       = "none";
    document.getElementById("employeeRecords").style.display   = "none";
    document.getElementById("attendance").style.display        = "none";
    document.getElementById("leaveManagement").style.display   = "none";
    document.getElementById("employeeDashboard").style.display = "block";
    document.getElementById("employeeLeaveSection").style.display = "block";

    wireLeaveForm();

    await loadEmployeeProfile();
    await loadMyAttendance();
    await loadMyLeaveRequests();
}

async function loadEmployeeProfile() {
    try {
        const { data: emp, error } = await db
            .from("employees")
            .select("*")
            .eq("auth_user_id", currentSession.user.id)
            .single();

        if (error || !emp) {
            showToast(
                "Could not load your profile. Contact an administrator.",
                "error",
                8000
            );
            return;
        }

        currentProfile._employee = emp;

        const profileDiv = document.getElementById("myProfile");
        if (!profileDiv) return;
        profileDiv.replaceChildren();

        [
            ["Employee ID",    emp.employee_id],
            ["Full Name",      emp.name],
            ["Email",          emp.email],
            ["Department",     emp.department],
            ["Designation",    emp.designation],
            ["Monthly Salary", "₹" + Number(emp.salary).toLocaleString("en-IN")]
        ].forEach(([label, value]) => {
            const p      = document.createElement("p");
            const strong = document.createElement("strong");
            strong.textContent = label + ": ";
            p.append(strong, document.createTextNode(value ?? ""));
            profileDiv.appendChild(p);
        });
    } catch (err) {
        console.error("Load profile error:", err);
    }
}

async function loadMyAttendance() {
    try {
        const { data: emp } = await db
            .from("employees")
            .select("id")
            .eq("auth_user_id", currentSession.user.id)
            .single();

        if (!emp) return;

        const thisYear = new Date().getFullYear().toString();

        const { data: records, error } = await db
            .from("attendance")
            .select("date, status")
            .eq("employee_id_fk", emp.id)
            .order("date", { ascending: false });

        if (error) throw error;

        const tbody  = document.getElementById("myAttendanceList");
        const attMsg = document.getElementById("myAttendanceMessage");

        if (tbody) tbody.replaceChildren();

        const yearRecords = (records || []).filter(r => r.date.startsWith(thisYear));

        const presentDays = yearRecords.filter(
            r => r.status.toLowerCase() === "present"
        ).length;

        const leaveDays = yearRecords.filter(
            r => r.status.toLowerCase() === "leave"
        ).length;

        const el = (id) => document.getElementById(id);
        if (el("myPresentDays"))  el("myPresentDays").textContent  = presentDays;
        if (el("myLeaveDays"))    el("myLeaveDays").textContent    = leaveDays;
        if (el("myLeaveBalance")) el("myLeaveBalance").textContent = Math.max(0, 12 - leaveDays);

        if (attMsg) attMsg.textContent = (records?.length ?? 0) === 0
            ? "No attendance records yet." : "";

        (records || []).forEach(rec => {
            const tr       = document.createElement("tr");
            const dateTd   = document.createElement("td");
            const statusTd = document.createElement("td");
            dateTd.textContent = rec.date;
            statusTd.appendChild(makeBadge(rec.status));
            tr.appendChild(dateTd);
            tr.appendChild(statusTd);
            if (tbody) tbody.appendChild(tr);
        });
    } catch (err) {
        console.error("Load attendance error:", err);
        showToast("Failed to load your attendance.", "error");
    }
}

async function loadMyLeaveRequests() {
    try {
        const { data: emp } = await db
            .from("employees")
            .select("id")
            .eq("auth_user_id", currentSession.user.id)
            .single();

        if (!emp) return;

        const { data: requests, error } = await db
            .from("leave_requests")
            .select("start_date, end_date, reason, status")
            .eq("employee_id_fk", emp.id)
            .order("created_at", { ascending: false });

        if (error) throw error;

        const tbody = document.getElementById("myLeaveList");
        const msg   = document.getElementById("myLeaveMessage");

        if (tbody) tbody.replaceChildren();

        if (msg) msg.textContent = (requests?.length ?? 0) === 0
            ? "You have not submitted any leave requests yet." : "";

        (requests || []).forEach(req => {
            const tr = document.createElement("tr");

            [req.start_date, req.end_date, req.reason].forEach(val => {
                const td = document.createElement("td");
                td.textContent = val ?? "";
                tr.appendChild(td);
            });

            const statusTd = document.createElement("td");
            statusTd.appendChild(makeBadge(req.status));
            tr.appendChild(statusTd);

            if (tbody) tbody.appendChild(tr);
        });
    } catch (err) {
        console.error("Load leave requests error:", err);
        showToast("Failed to load your leave requests.", "error");
    }
}

function wireLeaveForm() {
    const form = document.getElementById("leaveForm");
    if (!form) return;

    form.addEventListener("submit", async function (e) {
        e.preventDefault();
        clearFieldError("leaveFormMessage");

        const startDate = document.getElementById("leaveStart").value;
        const endDate   = document.getElementById("leaveEnd").value;
        const reason    = document.getElementById("leaveReason").value.trim();

        if (!startDate || !endDate || !reason) {
            setFieldError("leaveFormMessage", "Please fill in all fields.");
            return;
        }
        if (endDate < startDate) {
            setFieldError("leaveFormMessage",
                "End date cannot be earlier than start date.");
            return;
        }

        setBtnLoading("submitLeaveBtn", true, "Submit Leave Request");

        try {
            const { data: emp } = await db
                .from("employees")
                .select("id")
                .eq("auth_user_id", currentSession.user.id)
                .single();

            if (!emp) {
                setFieldError("leaveFormMessage",
                    "Employee record not found. Contact admin.");
                return;
            }

            const { error } = await db.from("leave_requests").insert({
                employee_id_fk: emp.id,
                start_date:     startDate,
                end_date:       endDate,
                reason,
                status:         "Pending"
                /* The RLS INSERT policy enforces status = 'Pending',
                   so this cannot be bypassed from the frontend. */
            });

            if (error) throw error;

            form.reset();
            showToast("Leave request submitted successfully.", "success");
            await loadMyLeaveRequests();

        } catch (err) {
            setFieldError("leaveFormMessage",
                "Submission failed: " + err.message);
        } finally {
            setBtnLoading("submitLeaveBtn", false, "Submit Leave Request");
        }
    });
}

/* ============================================================
   BOOTSTRAP
   ============================================================ */
initApp();
