const express = require('express');
const cors = require('cors');

const authRoutes = require('./routes/authRoutes');
const requestRoutes = require('./routes/requestRoutes');
const resourceRoutes = require('./routes/resourceRoutes');
const responderRoutes = require('./routes/responderRoutes');
const allocationRoutes = require('./routes/allocationRoutes');
const responderResourceRoutes = require('./routes/responderResourceRoutes');
const adminRoutes = require('./routes/adminRoutes');
const userRoutes = require('./routes/userRoutes');
const routeRoutes = require('./routes/routeRoutes');
const locationRoutes = require('./routes/locationRoutes');
const errorMiddleware = require('./middleware/errorMiddleware');

const app = express();

app.use(cors());
app.use(express.json());

app.use('/api/auth', authRoutes);
app.use('/api/requests', requestRoutes);
app.use('/api/resources', resourceRoutes);
app.use('/api/responders', responderRoutes);
app.use('/api/allocations', allocationRoutes);
app.use('/api/responder-resources', responderResourceRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/users', userRoutes);
app.use('/api/routes', routeRoutes);
app.use('/api/location', locationRoutes);

app.use(errorMiddleware);

module.exports = app;