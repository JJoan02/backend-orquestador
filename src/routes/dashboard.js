const express = require('express');
const router = express.Router();
const pterodactylService = require('../services/pterodactyl');
const databaseService = require('../services/database');
const { authenticateToken, requireRole } = require('../middleware/auth');
const winston = require('winston');

const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    new winston.transports.Console(),
    new winston.transports.File({ filename: 'logs/dashboard.log' })
  ]
});

// GET /api/dashboard - Dashboard principal
router.get('/dashboard', authenticateToken, async (req, res) => {
  try {
    const userId = req.user.id;
    
    logger.info('Obteniendo dashboard', { userId });

    // Obtener información del usuario
    const [userInfo, userServers, tkCoins, globalStats] = await Promise.all([
      pterodactylService.getUser(userId),
      pterodactylService.getUserServers(userId),
      databaseService.getUserTKCoins(userId),
      req.user.role === 'admin' || req.user.role === 'moderator' 
        ? databaseService.getGlobalStats() 
        : Promise.resolve(null)
    ]);

    // Procesar servidores del usuario
    const processedServers = await Promise.all(
      userServers.map(async (server) => {
        try {
          const serverDetails = await pterodactylService.getServerDetails(server.attributes.id);
          return {
            id: serverDetails.id,
            name: serverDetails.name,
            identifier: serverDetails.identifier,
            status: serverDetails.status,
            suspended: serverDetails.suspended,
            limits: serverDetails.limits,
            allocations: serverDetails.allocations,
            createdAt: serverDetails.created_at,
            updatedAt: serverDetails.updated_at
          };
        } catch (error) {
          logger.warn(`Error al procesar servidor ${server.attributes.id}`, error.message);
          return {
            id: server.attributes.id,
            name: server.attributes.name,
            identifier: server.attributes.identifier,
            status: 'unknown'
          };
        }
      })
    );

    const dashboardData = {
      user: {
        id: userId,
        username: userInfo.username,
        email: userInfo.email,
        firstName: userInfo.first_name,
        lastName: userInfo.last_name,
        admin: userInfo.root_admin,
        tkCoins,
        createdAt: userInfo.created_at
      },
      servers: {
        total: processedServers.length,
        active: processedServers.filter(s => s.status === 'running').length,
        suspended: processedServers.filter(s => s.suspended).length,
        offline: processedServers.filter(s => s.status === 'offline').length,
        list: processedServers
      },
      stats: globalStats
    };

    res.json({
      success: true,
      data: dashboardData
    });
  } catch (error) {
    logger.error('Error al obtener dashboard', error);
    res.status(500).json({
      success: false,
      error: 'Error al obtener dashboard',
      message: error.message
    });
  }
});

// GET /api/dashboard/admin - Dashboard de administrador
router.get('/dashboard/admin', authenticateToken, requireRole(['admin', 'moderator']), async (req, res) => {
  try {
    logger.info('Obteniendo dashboard de administrador', { userId: req.user.id });

    const [
      globalStats,
      usersWithCoins,
      allServers
    ] = await Promise.all([
      databaseService.getGlobalStats(),
      databaseService.getAllUsersWithTKCoins(),
      pterodactylService.getAllServers(1, 100)
    ]);

    // Procesar usuarios con más TK-Coins
    const topUsers = usersWithCoins.slice(0, 10).map(user => ({
      id: user.id,
      username: user.username,
      email: user.email,
      tkCoins: user.tk_coins,
      createdAt: user.created_at
    }));

    // Procesar servidores recientes
    const recentServers = allServers.data.slice(0, 10).map(server => ({
      id: server.attributes.id,
      name: server.attributes.name,
      identifier: server.attributes.identifier,
      owner: server.attributes.user,
      status: server.attributes.status,
      createdAt: server.attributes.created_at
    }));

    const adminDashboard = {
      stats: globalStats,
      topUsers,
      recentServers,
      system: {
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        memory: process.memoryUsage()
      }
    };

    res.json({
      success: true,
      data: adminDashboard
    });
  } catch (error) {
    logger.error('Error al obtener dashboard de administrador', error);
    res.status(500).json({
      success: false,
      error: 'Error al obtener dashboard de administrador',
      message: error.message
    });
  }
});

// GET /api/dashboard/stats - Estadísticas generales
router.get('/dashboard/stats', authenticateToken, async (req, res) => {
  try {
    const userId = req.user.id;
    
    logger.info('Obteniendo estadísticas', { userId });

    const [
      userServers,
      tkCoins,
      transactionHistory
    ] = await Promise.all([
      pterodactylService.getUserServers(userId),
      databaseService.getUserTKCoins(userId),
      databaseService.getUserTransactionHistory(userId, 10)
    ]);

    const stats = {
      servers: {
        total: userServers.length,
        active: userServers.filter(s => s.attributes.status === 'running').length,
        suspended: userServers.filter(s => s.attributes.suspended).length
      },
      tkCoins: {
        current: tkCoins,
        transactions: transactionHistory.length,
        recent: transactionHistory.slice(0, 5)
      },
      account: {
        createdAt: req.user.createdAt,
        lastLogin: new Date().toISOString()
      }
    };

    res.json({
      success: true,
      data: stats
    });
  } catch (error) {
    logger.error('Error al obtener estadísticas', error);
    res.status(500).json({
      success: false,
      error: 'Error al obtener estadísticas',
      message: error.message
    });
  }
});

module.exports = router;
