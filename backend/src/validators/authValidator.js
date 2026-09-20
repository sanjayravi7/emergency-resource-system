function validateRegister(data) {
  const { name, email, password, phone } = data;

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