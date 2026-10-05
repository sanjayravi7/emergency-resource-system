const {
  getUsers,
  updateUserRole,
  setUserActiveState,
} = require("../services/userService");
const userAdminService = require("../services/userAdminService");

const VALID_ROLES = ["REQUESTER", "RESPONDER", "ADMIN"];

async function listUsers(req, res, next) {
  try {
    const users = await getUsers();

    return res.status(200).json({
      success: true,
      data: {
        users,
      },
    });
  } catch (error) {
    next(error);
  }
}

async function changeRole(req, res, next) {
  try {
    const { role } = req.body;

    if (!VALID_ROLES.includes(role)) {
      return res.status(400).json({
        success: false,
        message: "Invalid role",
      });
    }

    const user = await updateUserRole(Number(req.params.id), role);

    return res.status(200).json({
      success: true,
      message: "User role updated",
      data: {
        user,
      },
    });
  } catch (error) {
    if (error.code === "P2025") {
      return res.status(404).json({
        success: false,
        message: "User not found",
      });
    }

    next(error);
  }
}

/**
 * SELF-SERVICE profile correction: every authenticated account may edit its
 * OWN allowed fields (display name and phone number) - and nothing else.
 *
 * Editing ANOTHER account stays an ADMIN-only operation handled by
 * `adminController.updateUserProfile`; the route table keeps the two apart so
 * a normal requester/responder can never obtain a profile write on somebody
 * else. The email address, role and active flag are never writable here.
 */
async function updateOwnProfile(req, res, next) {
  try {
    const user = await userAdminService.updateOwnProfile(req.user.id, req.body);

    return res.status(200).json({
      success: true,
      message: "Profile updated",
      data: {
        user,
      },
    });
  } catch (error) {
    if (error instanceof userAdminService.UserAdminError) {
      return res.status(error.statusCode).json({
        success: false,
        code: error.code,
        message: error.message,
      });
    }
    next(error);
  }
}

async function activateUser(req, res, next) {
  try {
    const user = await setUserActiveState(Number(req.params.id), true);

    return res.status(200).json({
      success: true,
      message: "User activated",
      data: {
        user,
      },
    });
  } catch (error) {
    if (error.code === "P2025") {
      return res.status(404).json({
        success: false,
        message: "User not found",
      });
    }

    next(error);
  }
}

async function deactivateUser(req, res, next) {
  try {
    if (Number(req.params.id) === req.user.id) {
      return res.status(400).json({
        success: false,
        message: "You cannot deactivate your own account",
      });
    }

    const user = await setUserActiveState(Number(req.params.id), false);

    return res.status(200).json({
      success: true,
      message: "User deactivated",
      data: {
        user,
      },
    });
  } catch (error) {
    if (error.code === "P2025") {
      return res.status(404).json({
        success: false,
        message: "User not found",
      });
    }

    next(error);
  }
}

module.exports = {
  listUsers,
  changeRole,
  activateUser,
  deactivateUser,
  updateOwnProfile,
};
