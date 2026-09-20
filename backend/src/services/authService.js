const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const prisma = require('../config/prisma');
const { JWT_SECRET } = require('../config/env');

exports.registerUser = async (data) => {
  const { name, email, password, phone } = data;
  const hashedPassword = await bcrypt.hash(password, 10);

  const user = await prisma.user.create({
    data: {
      name,
      email,
      password: hashedPassword,
      phone,
      role: 'REQUESTER' // Force REQUESTER on registration
    }
  });

  const { password: _, ...userWithoutPassword } = user;
  return userWithoutPassword;
};

exports.loginUser = async (data) => {
  const { email, password } = data;
  const user = await prisma.user.findUnique({ where: { email } });
  
  if (!user || !(await bcrypt.compare(password, user.password))) {
    throw new Error('Invalid credentials');
  }
  
  if (!user.isActive) {
    throw new Error('User is inactive');
  }

  const token = jwt.sign({ userId: user.id, role: user.role }, JWT_SECRET, { expiresIn: '1d' });
  const { password: _, ...userWithoutPassword } = user;
  
  return { token, user: userWithoutPassword };
};