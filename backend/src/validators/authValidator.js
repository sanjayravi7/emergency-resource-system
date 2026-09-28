// Mirror of the service-level allowlist: public registration may only choose
// REQUESTER or RESPONDER. ADMIN and any other value are rejected here with a
// user-facing message; authService.registerUser enforces the same rule as the
// actual security boundary.
const PUBLIC_REGISTRATION_ROLES = ["REQUESTER", "RESPONDER"];

function validateRegister(data) {
  const { name, email, password, phone, role } = data;

  const normalizedRole =
    typeof role === "string" ? role.trim() : "";

  if (!normalizedRole) {
    return "Choose how you want to use ERAS";
  }

  if (!PUBLIC_REGISTRATION_ROLES.includes(normalizedRole)) {
    return "Invalid role selection";
  }

  if (!name || !name.trim()) {
    return "Name is required";
  }

  if (!email || !email.trim()) {
    return "Email is required";
  }

  if (!password) {
    return "Password is required";
  }

  if (password.length < 6) {
    return "Password must be at least 6 characters";
  }

  if (phone && phone.length > 20) {
    return "Invalid phone number";
  }

  return null;
}

function validateLogin(data) {
  const { email, password } = data;

  if (!email || !email.trim()) {
    return "Email is required";
  }

  if (!password) {
    return "Password is required";
  }

  return null;
}

module.exports = {
  validateRegister,
  validateLogin,
};