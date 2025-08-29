const express = require('express');
const router = express.Router();
const pterodactylService = require('../services/pterodactyl');
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
    new winston.transports.File({ filename: 'logs/servers.log' })
  ]
});

// GET /api/servers - Obtener todos los servidores
router.get('/servers', authenticateToken, requireRole(['admin', 'moderator']), async (req, res) => {
  try {
    const { page = 1, per_page = 50 } = req.query;
    
    logger.info('Obteniendo todos los servidores', { 
      userId: req.user?.id,
      page,
      per_page 
    });

    const servers = await pterodactylService.getAllServers(parseInt(page), parseInt(per_page));
    
    res.json({
      success: true,
      data: servers.data,
      meta: servers.meta
    });
  } catch (error) {
    logger.error('Error al obtener servidores', error);
    res.status(500).json({
      success: false,
      error: 'Error al obtener servidores',
      message: error.message
    });
  }
});

// GET /api/server/:id - Obtener información detallada de un servidor
router.get('/server/:id', authenticateToken, async (req, res) => {
  try {
    const serverId = req.params.id;
    
    if (!serverId) {
      return res.status(400).json({
        success: false,
        error: 'ID de servidor requerido'
      });
    }

    logger.info('Obteniendo información de servidor', { 
      serverId, 
      requestedBy: req.user?.id 
    });

    const server = await pterodactylService.getServerDetails(serverId);
    
    // Obtener información del nodo
    const node = await pterodactylService.getNodeInfo(server.node);
    
    res.json({
      success: true,
      data: {
        server,
        node: {
          id: node.id,
          name: node.name,
          location: node.location_id,
          fqdn: node.fqdn,
          memory: node.memory,
          disk: node.disk,
          cpu: node.cpu
        }
      }
    });
  } catch (error) {
    logger.error('Error al obtener información del servidor', error);
    
    if (error.message.includes('no encontrado')) {
      return res.status(404).json({
        success: false,
        error: 'Servidor no encontrado'
      });
    }

    res.status(500).json({
      success: false,
      error: 'Error al obtener información del servidor',
      message: error.message
    });
  }
});

// POST /api/server/:id/suspend - Suspender un servidor
router.post('/server/:id/suspend', authenticateToken, requireRole(['admin', 'moderator']), async (req, res) => {
  try {
    const serverId = req.params.id;
    const { reason } = req.body;

    if (!serverId) {
      return res.status(400).json({
        success: false,
        error: 'ID de servidor requerido'
      });
    }

    logger.info('Suspendiendo servidor', { 
      serverId, 
      reason, 
      suspendedBy: req.user.id 
    });

    await pterodactylService.suspendServer(serverId);

    res.json({
      success: true,
      message: 'Servidor suspendido exitosamente',
      data: { serverId, reason }
    });
  } catch (error) {
    logger.error('Error al suspender servidor', error);
    res.status(500).json({
      success: false,
      error: 'Error al suspender servidor',
      message: error.message
    });
  }
});

// POST /api/server/:id/unsuspend - Reactivar un servidor
router.post('/server/:id/unsuspend', authenticateToken, requireRole(['admin', 'moderator']), async (req, res) => {
  try {
    const serverId = req.params.id;
    const { reason } = req.body;

    if (!serverId) {
      return res.status(400).json({
        success: false,
        error: 'ID de servidor requerido'
      });
    }

    logger.info('Reactivando servidor', { 
      serverId, 
      reason, 
      unsuspendedBy: req.user.id 
    });

    await pterodactylService.unsuspendServer(serverId);

    res.json({
      success: true,
      message: 'Servidor reactivado exitosamente',
      data: { serverId, reason }
    });
  } catch (error) {
    logger.error('Error al reactivar servidor', error);
    res.status(500).json({
      success: false,
      error: 'Error al reactivar servidor',
      message: error.message
    });
  }
});

// POST /api/server/:id/reinstall - Reinstalar un servidor
router.post('/server/:id/reinstall', authenticateToken, requireRole(['admin', 'moderator']), async (req, res) => {
  try {
    const serverId = req.params.id;
    const { reason } = req.body;

    if (!serverId) {
      return res.status(400).json({
        success: false,
        error: 'ID de servidor requerido'
      });
    }

    logger.info('Reinstalando servidor', { 
      serverId, 
      reason, 
      reinstalledBy: req.user.id 
    });

    await pterodactylService.reinstallServer(serverId);

    res.json({
      success: true,
      message: 'Servidor reinstalado exitosamente',
      data: { serverId, reason }
    });
  } catch (error) {
    logger.error('Error al reinstalar servidor', error);
    res.status(500).json({
      success: false,
      error: 'Error al reinstalar servidor',
      message: error.message
    });
  }
});

// GET /api/nodes - Obtener información de nodos
router.get('/nodes', authenticateToken, requireRole(['admin', 'moderator']), async (req, res) => {
  try {
    const { page = 1, per_page = 50 } = req.query;
    
    logger.info('Obteniendo información de nodos', { 
      userId: req.user?.id,
      page,
      per_page 
    });

    const nodes = await pterodactylService.getAllNodes(parseInt(page), parseInt(per_page));
    
    res.json({
      success: true,
      data: nodes.data,
      meta: nodes.meta
    });
  } catch (error) {
    logger.error('Error al obtener nodos', { 
      error: error.message,
      userId: req.user?.id,
      stack: error.stack 
    });
    
    if (error.message.includes('no encontrado')) {
      return res.status(404).json({
        success: false,
        error: 'Nodos no encontrados'
      });
    }

    res.status(500).json({
      success: false,
      error: 'Error al obtener información de nodos',
      message: error.message
    });
  }
});

module.exports = router;
