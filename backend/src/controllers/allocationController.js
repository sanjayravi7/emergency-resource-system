const allocationService = require('../services/allocationService');

exports.getMyAllocations = async (req, res, next) => {
  try {
    const allocations =
      await allocationService.getAllocationsByResponder(req.user.id);

    res.json({
      success: true,
      allocations,
    });
  } catch (error) {
    next(error);
  }
};

exports.createAllocation = async (req, res, next) => {
  try {
    const allocation = await allocationService.createAllocation(req.user.id, req.body);
    res.status(201).json({ success: true, allocation });
  } catch (error) {
    next(error);
  }
};

exports.updateAllocationStatus = async (req, res, next) => {
  try {
    const allocation = await allocationService.updateAllocationStatus(
      req.user.id,
      req.params.id,
      req.body.status
    );

    res.json({
      success: true,
      message: "Allocation status updated successfully",
      allocation,
    });
  } catch (error) {
    next(error);
  }
};