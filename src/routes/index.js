const express = require('express');
const router = express.Router();

// Importar rutas
const usersRoutes = require('./users');
const serversRoutes = require('./servers');
const dashboardRoutes = require('./dashboard');

// Montar rutas
router.use('/', usersRoutes);
router.use('/', serversRoutes);
router.use('/', dashboardRoutes);

// Ruta de salud
router.get('/health', (req, res) => {
  res.json({
    success: true,
    message: 'Panel-TK API está funcionando correctamente',
    timestamp: new Date().toISOString(),
    uptime: process.uptime()
  });
});

// Ruta raíz
router.get('/', (req, res) => {
  res.json({
    success: true,
    message: 'Bienvenido a Panel-TK API',
    version: '1.0.0',
    endpoints: {
      users: '/api/users',
      servers: '/api/servers',
      dashboard: '/api/dashboard',
      health: '/api/health'
    }
  });
});

module.exports = router;
