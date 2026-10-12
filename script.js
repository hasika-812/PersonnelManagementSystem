/* ============================================================
   Personnel Management System — Main Script
   Uses: Supabase (PostgreSQL + Auth)
   ============================================================

   HOW TO CONFIGURE:
   1. Create a free project at https://supabase.com
   2. Run the SQL in supabase_schema.sql in the SQL Editor
   3. Replace the two constants below with your project values:
      - SUPABASE_URL  → Settings → API → Project URL
      - SUPABASE_KEY  → Settings → API → anon/public key
   ============================================================ */

const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_KEY = "YOUR_SUPABASE_ANON_KEY";

/* ---- Guard: warn if not configured ---- */
if (
    SUPABASE_URL === "YOUR_SUPABASE_URL" ||
    SUPABASE_KEY === "YOUR_SUPABASE_ANON_KEY"
) {
    document.body.innerHTML =
        `<div style="font-family:Arial;max-width:600px;margin:60px auto;padding:30px;background:#fff;border-radius:12px;box-shadow:0 4px 20px #0002;">
            <h2 style="color:#c0392b;">⚠ Supabase Not Configured</h2>
            <p>Open <strong>script.js</strong> and replace the two placeholder values at the top:</p>
            <ul>
                <li><code>SUPABASE_URL</code> — your Supabase project URL</li>
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

/** Show or hide the loading overlay */
function setLoading(visible) {
    const overlay = document.getElementById("loadingOverlay");
    if (!overlay) return;
    overlay.style.display = visible ? "flex" : "none";
}

let toastTimer = null;

/** Show a toast notification (type: 'success' | 'error' | 'info') */
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
    toastTimer = setTimeout(() => {
        toast.className = "";
    }, duration);
}

/** Set an inline error message on an element */
function setFieldError(elementId, message) {
    const el = document.getElementById(elementId);
    if (el) el.textContent = message;
}

/** Clear an inline error message */
function clearFieldError(elementId) {
    const el = document.getElementById(elementId);
    if (el) el.textContent = "";
}

/** Disable / re-enable a submit button */
function setBtnLoading(btnId, isLoading, defaultText) {
    const btn = document.getElementById(btnId);
    if (!btn) return;
    btn.disabled = isLoading;
    btn.textContent = isLoading ? "Please wait…" : defaultText;
}

/** Create a status badge element */
function makeBadge(status) {
    const span = document.createElement("span");
    span.className = "badge badge-" + status.toLowerCase();
    span.textContent = status;
    return span;
}

/* ============================================================
   SESSION & ROUTING
   ============================================================ */

let currentSession = null;   // Supabase Auth session
let currentProfile = null;   // Row from `profiles` table
let currentRole = null;      // "admin" | "employee"

/**
 * Called on every page load.
 * Reads the active Supabase session, fetches the user's profile,
 * then routes to the correct view.
 */
async function initApp() {
    setLoading(true);
    try {
        const { data: { session } } = await db.auth.getSession();

        if (!session) {
            window.location.replace("login.html");
            return;
        }

        currentSession = session;

        /* Load profile row */
        const { data: profile, error: profileErr } =
            await db.from("profiles")
                    .select("*")
                    .eq("id", session.user.id)
                    .single();

        if (profileErr || !profile) {
            console.error("Profile load error:", profileErr);
            await logout();
            return;
        }

        currentProfile = profile;
        currentRole = profile.role;  // "admin" or "employee"

        /* Add logout button to header */
        injectLogoutButton();

        /* Show the correct dashboard */
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

/** Inject a logout button in the header */
function injectLogoutButton() {
    if (document.getElementById("logoutButton")) return;
    const btn = document.createElement("button");
    btn.id = "logoutButton";
    btn.textContent = "Logout";
    btn.onclick = logout;
    document.querySelector("header")?.appendChild(btn);
}

/** Sign out and redirect to login */
async function logout() {
    await db.auth.signOut();
    window.location.replace("login.html");
}

/* ============================================================
   ADMIN VIEW
   ============================================================ */

function setupAdminView() {
    /* Show admin nav and sections */
    document.getElementById("adminNav").style.display = "";
    document.getElementById("dashboard").style.display = "";
    document.getElementById("addEmployee").style.display = "";
    document.getElementById("employeeRecords").style.display = "";
    document.getElementById("attendance").style.display = "";
    document.getElementById("leaveManagement").style.display = "";
    document.getElementById("employeeDashboard").style.display = "none";

    wireAddEmployeeForm();
    wireEditEmployeeForm();
    wireAttendanceForm();
    wireAdminLeaveActions();

    loadDashboardStats();
    loadEmployees();
    loadAttendanceRecords();
    loadAdminLeaveRequests();

    /* Pre-fill today's date */
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
            db.from("leave_requests").select("id", { count: "exact", head: true }).eq("status", "Pending"),
            db.from("attendance")
              .select("id", { count: "exact", head: true })
              .eq("date", todayISO())
              .eq("status", "Present")
        ]);

        document.getElementById("statTotalEmployees").textContent =
            empResult.count ?? "—";
        document.getElementById("statPendingLeaves").textContent =
            leaveResult.count ?? "—";
        document.getElementById("statTodayPresent").textContent =
            attResult.count ?? "—";
    } catch (err) {
        console.error("Stats error:", err);
    }
}

/* ============================================================
   ADMIN — EMPLOYEE MANAGEMENT
   ============================================================ */

let allEmployees = [];   // Local cache for the dropdown

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
    const tbody = document.getElementById("employeeList");
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

        /* Action buttons */
        const actionTd = document.createElement("td");
        const editBtn = document.createElement("button");
        editBtn.textContent = "Edit";
        editBtn.className = "edit-btn";
        editBtn.onclick = () => openEditModal(emp);

        const delBtn = document.createElement("button");
        delBtn.textContent = "Delete";
        delBtn.className = "delete-btn";
        delBtn.style.marginLeft = "6px";
        delBtn.onclick = () => confirmDeleteEmployee(emp);

        actionTd.appendChild(editBtn);
        actionTd.appendChild(delBtn);
        tr.appendChild(actionTd);
        tbody.appendChild(tr);
    });
}

/* Search filter */
const searchInput = document.getElementById("searchEmployee");
if (searchInput) {
    searchInput.addEventListener("input", () => renderEmployeeTable(allEmployees));
}

/** Wire the Add Employee form */
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
        const password    = document.getElementById("empPassword").value;

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
        if (password.length < 8) {
            setFieldError("addEmployeeMessage", "Password must be at least 8 characters.");
            return;
        }

        setBtnLoading("addEmpBtn", true, "Add Employee");

        try {
            /*
             * Step 1: Create an Auth user for the employee.
             * We use the admin API via the service-role key which is
             * set in the Edge Function. Here we call our helper RPC.
             * See SETUP.md for creating the Edge Function.
             *
             * For a simpler approach that works without a server,
             * we call signUp and then immediately sign back in as admin.
             */
            const { data: signUpData, error: signUpErr } =
                await db.auth.signUp({ email, password });

            if (signUpErr) {
                /* Common error: email already registered */
                if (signUpErr.message?.toLowerCase().includes("already")) {
                    setFieldError("addEmployeeMessage",
                        "This email is already registered. Use a different email.");
                } else {
                    setFieldError("addEmployeeMessage", signUpErr.message);
                }
                return;
            }

            const userId = signUpData.user?.id;
            if (!userId) {
                setFieldError("addEmployeeMessage",
                    "Could not create user account. Try again.");
                return;
            }

            /* Step 2: Insert the employee record linked to the Auth user */
            const { error: empErr } = await db.from("employees").insert({
                auth_user_id: userId,
                employee_id:  empId,
                name,
                email,
                department,
                designation,
                salary
            });

            if (empErr) {
                if (empErr.message?.toLowerCase().includes("unique") ||
                    empErr.code === "23505") {
                    const detail = empErr.details || empErr.message;
                    if (detail.includes("employee_id")) {
                        setFieldError("addEmployeeMessage",
                            "Employee ID already exists. Choose a different ID.");
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

            /* Step 3: Insert profile row for role-based access */
            const { error: profErr } = await db.from("profiles").insert({
                id:   userId,
                role: "employee",
                employee_id: empId
            });

            if (profErr) {
                console.warn("Profile insert warning:", profErr.message);
                /* Not fatal — the employee row exists; profile may have
                   been created by the Auth trigger. */
            }

            form.reset();
            clearFieldError("addEmployeeMessage");
            showToast("Employee '" + name + "' added successfully!", "success");
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
    document.getElementById("editEmpDbId").value = emp.id;
    document.getElementById("editEmpId").value = emp.employee_id;
    document.getElementById("editEmpName").value = emp.name;
    document.getElementById("editEmpEmail").value = emp.email;
    document.getElementById("editEmpDepartment").value = emp.department;
    document.getElementById("editEmpDesignation").value = emp.designation;
    document.getElementById("editEmpSalary").value = emp.salary;
    clearFieldError("editMessage");

    const modal = document.getElementById("editModal");
    modal.style.display = "flex";
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

        const dbId = document.getElementById("editEmpDbId").value;
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

/** Confirm and delete an employee */
async function confirmDeleteEmployee(emp) {
    if (!confirm(
        `Delete employee "${emp.name}" (${emp.employee_id})?\n\n` +
        "This will also delete their attendance records and leave requests."
    )) return;

    setLoading(true);
    try {
        /* Cascade deletes are defined in the DB schema (ON DELETE CASCADE),
           so deleting the employee row also clears related records. */
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

/** Fill the employee dropdown in the attendance form */
function populateAttendanceDropdown(employees) {
    const select = document.getElementById("attendanceEmployee");
    if (!select) return;

    select.replaceChildren();
    const defaultOpt = document.createElement("option");
    defaultOpt.value = "";
    defaultOpt.textContent = "Select Employee";
    select.appendChild(defaultOpt);

    employees.forEach(emp => {
        const opt = document.createElement("option");
        opt.value = emp.id;   // DB primary key (UUID)
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
            /* filterEmpId here is the employee_id text field */
            const emp = allEmployees.find(
                e => e.employee_id.toLowerCase() === filterEmpId.toLowerCase()
            );
            if (emp) query = query.eq("employee_id_fk", emp.id);
            else {
                /* No match — show empty */
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
        const tr = document.createElement("tr");
        const emp = rec.employees || {};

        [
            emp.employee_id ?? "—",
            emp.name ?? "—",
            rec.date,
            ""   // status badge placeholder
        ].forEach((val, i) => {
            const td = document.createElement("td");
            if (i === 3) {
                td.appendChild(makeBadge(rec.status));
            } else {
                td.textContent = val;
            }
            tr.appendChild(td);
        });

        const actionTd = document.createElement("td");
        const delBtn = document.createElement("button");
        delBtn.textContent = "Delete";
        delBtn.className = "delete-btn";
        delBtn.onclick = () => deleteAttendanceRecord(rec.id);
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

/** Attendance filter buttons */
function applyAttendanceFilter() {
    const empId = document.getElementById("filterAttEmployee")?.value.trim();
    const date  = document.getElementById("filterAttDate")?.value;
    loadAttendanceRecords(empId || null, date || null);
}

function clearAttendanceFilter() {
    const empField = document.getElementById("filterAttEmployee");
    const dateField = document.getElementById("filterAttDate");
    if (empField) empField.value = "";
    if (dateField) dateField.value = "";
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
            /* Check duplicate */
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
            setFieldError("attendanceFormMessage",
                "Error: " + err.message);
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
        const tr = document.createElement("tr");
        const emp = req.employees || {};

        [
            emp.employee_id ?? "—",
            emp.name ?? "—",
            req.start_date,
            req.end_date,
            req.reason,
            ""  // badge placeholder
        ].forEach((val, i) => {
            const td = document.createElement("td");
            if (i === 5) {
                td.appendChild(makeBadge(req.status));
            } else {
                td.textContent = val;
            }
            tr.appendChild(td);
        });

        const actionTd = document.createElement("td");

        if (req.status === "Pending") {
            const approveBtn = document.createElement("button");
            approveBtn.textContent = "Approve";
            approveBtn.className = "approve-btn";
            approveBtn.onclick = () => updateLeaveStatus(req.id, "Approved");

            const rejectBtn = document.createElement("button");
            rejectBtn.textContent = "Reject";
            rejectBtn.className = "reject-btn";
            rejectBtn.style.marginLeft = "6px";
            rejectBtn.onclick = () => updateLeaveStatus(req.id, "Rejected");

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
            .eq("status", "Pending");   // safety: only update pending

        if (error) throw error;

        showToast("Leave request " + newStatus.toLowerCase() + "d.", "success");
        await loadAdminLeaveRequests();
        await loadDashboardStats();
    } catch (err) {
        console.error("Update leave status error:", err);
        showToast("Failed to update leave status.", "error");
    }
}

function wireAdminLeaveActions() {
    /* Nothing to wire beyond the inline onclick handlers
       in renderAdminLeaveTable. This function is a placeholder
       in case global actions are added later. */
}

/* ============================================================
   EMPLOYEE VIEW
   ============================================================ */

async function setupEmployeeView() {
    /* Hide admin sections, show employee dashboard */
    document.getElementById("adminNav").style.display = "none";
    document.getElementById("dashboard").style.display = "none";
    document.getElementById("addEmployee").style.display = "none";
    document.getElementById("employeeRecords").style.display = "none";
    document.getElementById("attendance").style.display = "none";
    document.getElementById("leaveManagement").style.display = "none";
    document.getElementById("employeeDashboard").style.display = "block";
    document.getElementById("employeeLeaveSection").style.display = "block";

    wireLeaveForm();

    await loadEmployeeProfile();
    await loadMyAttendance();
    await loadMyLeaveRequests();
}

/** Load and render the logged-in employee's profile */
async function loadEmployeeProfile() {
    try {
        /* currentProfile has the profile row; load the full employee record */
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

        /* Store for later use (leave submission, etc.) */
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
            const p = document.createElement("p");
            const strong = document.createElement("strong");
            strong.textContent = label + ": ";
            p.append(strong, document.createTextNode(value ?? ""));
            profileDiv.appendChild(p);
        });
    } catch (err) {
        console.error("Load profile error:", err);
    }
}

/** Load and render the employee's own attendance records */
async function loadMyAttendance() {
    try {
        const userId = currentSession.user.id;

        /* Get employee DB id first */
        const { data: emp } = await db
            .from("employees")
            .select("id")
            .eq("auth_user_id", userId)
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

        const yearRecords = (records || []).filter(r =>
            r.date.startsWith(thisYear)
        );

        const presentDays = yearRecords.filter(
            r => r.status.toLowerCase() === "present"
        ).length;

        const leaveDays = yearRecords.filter(
            r => r.status.toLowerCase() === "leave"
        ).length;

        const el = (id) => document.getElementById(id);
        if (el("myPresentDays")) el("myPresentDays").textContent = presentDays;
        if (el("myLeaveDays"))   el("myLeaveDays").textContent   = leaveDays;
        if (el("myLeaveBalance")) {
            el("myLeaveBalance").textContent = Math.max(0, 12 - leaveDays);
        }

        if (attMsg) attMsg.textContent = (records?.length ?? 0) === 0
            ? "No attendance records yet." : "";

        (records || []).forEach(rec => {
            const tr = document.createElement("tr");

            const dateTd = document.createElement("td");
            dateTd.textContent = rec.date;

            const statusTd = document.createElement("td");
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

/** Load and render the employee's own leave requests */
async function loadMyLeaveRequests() {
    try {
        const userId = currentSession.user.id;

        const { data: emp } = await db
            .from("employees")
            .select("id")
            .eq("auth_user_id", userId)
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

/** Wire the leave application form */
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
            const userId = currentSession.user.id;
            const { data: emp } = await db
                .from("employees")
                .select("id")
                .eq("auth_user_id", userId)
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
   UTILITY
   ============================================================ */

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
   BOOTSTRAP
   ============================================================ */
initApp();
