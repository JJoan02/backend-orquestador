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
    new winston.transports.File({ filename: 'logs/users.log' })
  ]
});

// GET /api/users - Obtener todos los usuarios con TK-Coins
router.get('/users', authenticateToken, async (req, res) => {
  try {
    logger.info('Obteniendo usuarios con TK-Coins', { userId: req.user?.id });
    
    const users = await databaseService.getAllUsersWithTKCoins();
    
    // Enriquecer con datos de Pterodactyl
    const enrichedUsers = await Promise.all(
      users.map(async (user) => {
        try {
          const pteroUser = await pterodactylService.getUser(user.id);
          return {
            ...user,
            pterodactyl: {
              username: pteroUser.username,
              email: pteroUser.email,
              firstName: pteroUser.first_name,
              lastName: pteroUser.last_name,
              admin: pteroUser.root_admin,
              createdAt: pteroUser.created_at
            }
          };
        } catch (error) {
          logger.warn(`No se pudo obtener datos de Pterodactyl para usuario ${user.id}`, error.message);
          return user;
        }
      })
    );

    res.json({
      success: true,
      data: enrichedUsers,
      count: enrichedUsers.length
    });
  } catch (error) {
    logger.error('Error al obtener usuarios', error);
    res.status(500).json({
      success: false,
      error: 'Error al obtener usuarios',
      message: error.message
    });
  }
});

// GET /api/user/:id - Obtener información detallada de un usuario
router.get('/user/:id', authenticateToken, async (req, res) => {
  try {
    const userId = parseInt(req.params.id);
    
    if (isNaN(userId)) {
      return res.status(400).json({
        success: false,
        error: 'ID de usuario inválido'
      });
    }

    logger.info('Obteniendo información de usuario', { userId, requestedBy: req.user?.id });

    // Obtener datos de Pterodactyl
    const pteroUser = await pterodactylService.getUser(userId);
    
    // Obtener TK-Coins de la base de datos
    const tkCoins = await databaseService.getUserTKCoins(userId);
    
    // Obtener historial de transacciones
    const transactions = await databaseService.getUserTransactionHistory(userId, 20);

    const userData = {
      id: userId,
      pterodactyl: {
        username: pteroUser.username,
        email: pteroUser.email,
        firstName: pteroUser.first_name,
        lastName: pteroUser.last_name,
        admin: pteroUser.root_admin,
        language: pteroUser.language,
        createdAt: pteroUser.created_at,
        updatedAt: pteroUser.updated_at
      },
      tkCoins,
      transactions
    };

    res.json({
      success: true,
      data: userData
    });
  } catch (error) {
    logger.error('Error al obtener información de usuario', error);
    
    if (error.message.includes('no encontrado')) {
      return res.status(404).json({
        success: false,
        error: 'Usuario no encontrado'
      });
    }

    res.status(500).json({
      success: false,
      error: 'Error al obtener información del usuario',
      message: error.message
    });
  }
});

// GET /api/user/:id/servers - Obtener servidores de un usuario
router.get('/user/:id/servers', authenticateToken, async (req, res) => {
  try {
    const userId = parseInt(req.params.id);
    
    if (isNaN(userId)) {
      return res.status(400).json({
        success: false,
        error: 'ID de usuario inválido'
      });
    }

    logger.info('Obteniendo servidores de usuario', { userId, requestedBy: req.user?.id });

    const servers = await pterodactylService.getUserServers(userId);
    
    // Enriquecer información de servidores
    const enrichedServers = await Promise.all(
      servers.map(async (server) => {
        try {
          const serverDetails = await pterodactylService.getServerDetails(server.attributes.id);
          return {
            id: serverDetails.id,
            name: serverDetails.name,
            identifier: serverDetails.identifier,
            description: serverDetails.description,
            status: serverDetails.status,
            suspended: serverDetails.suspended,
            limits: serverDetails.limits,
            allocations: serverDetails.allocations,
            createdAt: serverDetails.created_at,
            updatedAt: serverDetails.updated_at
          };
        } catch (error) {
          logger.warn(`Error al obtener detalles del servidor ${server.attributes.id}`, error.message);
          return {
            id: server.attributes.id,
            name: server.attributes.name,
            identifier: server.attributes.identifier
          };
        }
      })
    );

    res.json({
      success: true,
      data: enrichedServers,
      count: enrichedServers.length
    });
  } catch (error) {
    logger.error('Error al obtener servidores del usuario', error);
    res.status(500).json({
      success: false,
      error: 'Error al obtener servidores',
      message: error.message
    });
  }
});

// PUT /api/user/:id/tk-coins - Actualizar TK-Coins de un usuario
router.put('/user/:id/tk-coins', authenticateToken, requireRole(['admin', 'moderator']), async (req, res) => {
  try {
    const userId = parseInt(req.params.id);
    const { amount, operation = 'add', reason } = req.body;

    if (isNaN(userId)) {
      return res.status(400).json({
        success: false,
        error: 'ID de usuario inválido'
      });
    }

    if (typeof amount !== 'number' || isNaN(amount)) {
      return res.status(400).json({
        success: false,
        error: 'Cantidad inválida'
      });
    }

    logger.info('Actualizando TK-Coins', {
      userId,
      amount,
      operation,
      reason,
      updatedBy: req.user.id
    });

    await databaseService.updateUserTKCoins(userId, amount, operation);

    // Registrar en log
    await databaseService.createTransactionLog(userId, amount, operation, {
      reason,
      updatedBy: req.user.id,
      updatedByEmail: req.user.email
    });

    const newBalance = await databaseService.getUserTKCoins(userId);

    res.json({
      success: true,
      message: 'TK-Coins actualizados exitosamente',
      data: {
        userId,
        newBalance,
        operation,
        amount
      }
    });
  } catch (error) {
    logger.error('Error al actualizar TK-Coins', error);
    res.status(500).json({
      success: false,
      error: 'Error al actualizar TK-Coins',
      message: error.message
    });
  }
});

module.exports = router;
