const mysql = require('mysql2/promise');
const winston = require('winston');

const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    new winston.transports.Console(),
    new winston.transports.File({ filename: 'logs/database.log' })
  ]
});

class DatabaseService {
  constructor() {
    this.pool = null;
    this.init();
  }

  async init() {
    try {
      this.pool = mysql.createPool({
        host: process.env.DB_HOST,
        user: process.env.DB_USER,
        password: process.env.DB_PASSWORD,
        database: process.env.DB_NAME,
        port: process.env.DB_PORT || 3306,
        waitForConnections: true,
        connectionLimit: 10,
        queueLimit: 0,
        acquireTimeout: 60000,
        timeout: 60000
      });

      // Test connection
      const connection = await this.pool.getConnection();
      await connection.ping();
      connection.release();
      
      logger.info('Conexión a base de datos establecida exitosamente');
    } catch (error) {
      logger.error('Error al conectar con la base de datos', error);
      throw error;
    }
  }

  async getUserTKCoins(userId) {
    try {
      const [rows] = await this.pool.execute(
        'SELECT tk_coins FROM users WHERE id = ?',
        [userId]
      );
      
      return rows[0] ? rows[0].tk_coins : 0;
    } catch (error) {
      logger.error(`Error al obtener TK-Coins del usuario ${userId}`, error);
      throw error;
    }
  }

  async updateUserTKCoins(userId, amount, operation = 'add') {
    const connection = await this.pool.getConnection();
    
    try {
      await connection.beginTransaction();

      let query;
      let params;
      
      if (operation === 'set') {
        query = 'UPDATE users SET tk_coins = ? WHERE id = ?';
        params = [amount, userId];
      } else {
        query = 'UPDATE users SET tk_coins = tk_coins + ? WHERE id = ?';
        params = [amount, userId];
      }

      const [result] = await connection.execute(query, params);
      
      if (result.affectedRows === 0) {
        throw new Error(`Usuario ${userId} no encontrado`);
      }

      // Log the transaction
      await connection.execute(
        'INSERT INTO tk_coins_transactions (user_id, amount, operation, created_at) VALUES (?, ?, ?, NOW())',
        [userId, amount, operation]
      );

      await connection.commit();
      
      logger.info(`TK-Coins actualizados para usuario ${userId}`, {
        amount,
        operation,
        affectedRows: result.affectedRows
      });

      return true;
    } catch (error) {
      await connection.rollback();
      logger.error(`Error al actualizar TK-Coins del usuario ${userId}`, error);
      throw error;
    } finally {
      connection.release();
    }
  }

  async getUserTransactionHistory(userId, limit = 50) {
    try {
      const [rows] = await this.pool.execute(
        'SELECT * FROM tk_coins_transactions WHERE user_id = ? ORDER BY created_at DESC LIMIT ?',
        [userId, limit]
      );
      
      return rows;
    } catch (error) {
      logger.error(`Error al obtener historial de transacciones del usuario ${userId}`, error);
      throw error;
    }
  }

  async getAllUsersWithTKCoins() {
    try {
      const [rows] = await this.pool.execute(
        'SELECT id, username, email, tk_coins, created_at FROM users WHERE tk_coins > 0 ORDER BY tk_coins DESC'
      );
      
      return rows;
    } catch (error) {
      logger.error('Error al obtener usuarios con TK-Coins', error);
      throw error;
    }
  }

  async getGlobalStats() {
    try {
      const [totalUsers] = await this.pool.execute(
        'SELECT COUNT(*) as total FROM users'
      );
      
      const [usersWithCoins] = await this.pool.execute(
        'SELECT COUNT(*) as total FROM users WHERE tk_coins > 0'
      );
      
      const [totalCoins] = await this.pool.execute(
        'SELECT SUM(tk_coins) as total FROM users'
      );
      
      const [recentTransactions] = await this.pool.execute(
        'SELECT COUNT(*) as total FROM tk_coins_transactions WHERE created_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR)'
      );

      return {
        totalUsers: totalUsers[0].total,
        usersWithCoins: usersWithCoins[0].total,
        totalCoins: totalCoins[0].total || 0,
        recentTransactions: recentTransactions[0].total
      };
    } catch (error) {
      logger.error('Error al obtener estadísticas globales', error);
      throw error;
    }
  }

  async createTransactionLog(userId, amount, operation, metadata = {}) {
    try {
      await this.pool.execute(
        'INSERT INTO tk_coins_transactions (user_id, amount, operation, metadata, created_at) VALUES (?, ?, ?, ?, NOW())',
        [userId, amount, operation, JSON.stringify(metadata)]
      );
      
      logger.info('Transacción registrada', { userId, amount, operation });
    } catch (error) {
      logger.error('Error al registrar transacción', error);
      throw error;
    }
  }

  async close() {
    if (this.pool) {
      await this.pool.end();
      logger.info('Conexión a base de datos cerrada');
    }
  }
}

module.exports = new DatabaseService();
