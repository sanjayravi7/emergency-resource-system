const {
  getUsers,
  updateUserRole,
  setUserActiveState,
} = require("../services/userService");

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
};
