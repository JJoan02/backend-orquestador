const jwt = require('jsonwebtoken');
const winston = require('winston');

const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    new winston.transports.Console(),
    new winston.transports.File({ filename: 'logs/auth.log' })
  ]
});

const authenticateToken = async (req, res, next) => {
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1];

  if (!token) {
    logger.warn('Intento de acceso sin token', { 
      ip: req.ip, 
      path: req.path 
    });
    return res.status(401).json({ 
      error: 'Token requerido',
      code: 'NO_TOKEN'
    });
  }

  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    req.user = decoded;
    
    logger.info('Token válido', { 
      userId: decoded.id, 
      email: decoded.email,
      path: req.path 
    });
    
    next();
  } catch (error) {
    logger.error('Token inválido', { 
      error: error.message, 
      ip: req.ip,
      path: req.path 
    });
    
    return res.status(403).json({ 
      error: 'Token inválido o expirado',
      code: 'INVALID_TOKEN'
    });
  }
};

const requireRole = (roles) => {
  return (req, res, next) => {
    if (!req.user) {
      return res.status(401).json({ error: 'Usuario no autenticado' });
    }

    if (!roles.includes(req.user.role)) {
      logger.warn('Acceso denegado por rol insuficiente', {
        userId: req.user.id,
        role: req.user.role,
        requiredRoles: roles,
        path: req.path
      });
      
      return res.status(403).json({ 
        error: 'Permisos insuficientes',
        code: 'INSUFFICIENT_PERMISSIONS'
      });
    }

    next();
  };
};

module.exports = {
  authenticateToken,
  requireRole
};
