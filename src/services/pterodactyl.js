const axios = require('axios');
const winston = require('winston');

const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    new winston.transports.Console(),
    new winston.transports.File({ filename: 'logs/pterodactyl.log' })
  ]
});

class PterodactylService {
  constructor() {
    this.client = axios.create({
      baseURL: process.env.PTERODACTYL_URL,
      headers: {
        'Authorization': `Bearer ${process.env.PTERODACTYL_API_KEY}`,
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      },
      timeout: 10000
    });

    // Interceptor para logging
    this.client.interceptors.request.use(
      (config) => {
        logger.info('Pterodactyl API Request', {
          method: config.method,
          url: config.url,
          params: config.params
        });
        return config;
      },
      (error) => {
        logger.error('Pterodactyl API Request Error', error);
        return Promise.reject(error);
      }
    );

    this.client.interceptors.response.use(
      (response) => {
        logger.info('Pterodactyl API Response', {
          status: response.status,
          url: response.config.url
        });
        return response;
      },
      (error) => {
        logger.error('Pterodactyl API Response Error', {
          status: error.response?.status,
          message: error.message,
          url: error.config?.url
        });
        return Promise.reject(error);
      }
    );
  }

  async getUser(userId) {
    try {
      const response = await this.client.get(`/api/application/users/${userId}`);
      return response.data.attributes;
    } catch (error) {
      if (error.response?.status === 404) {
        throw new Error(`Usuario ${userId} no encontrado`);
      }
      throw error;
    }
  }

  async getUserServers(userId) {
    try {
      const response = await this.client.get(`/api/application/users/${userId}?include=servers`);
      return response.data.attributes.relationships.servers.data;
    } catch (error) {
      throw new Error(`Error al obtener servidores del usuario ${userId}: ${error.message}`);
    }
  }

  async getAllUsers(page = 1, perPage = 50) {
    try {
      const response = await this.client.get('/api/application/users', {
        params: { page, 'per_page': perPage }
      });
      
      return {
        data: response.data.data.map(user => user.attributes),
        meta: response.data.meta
      };
    } catch (error) {
      throw new Error(`Error al obtener usuarios: ${error.message}`);
    }
  }

  async getAllServers(page = 1, perPage = 50) {
    try {
      const response = await this.client.get('/api/application/servers', {
        params: { page, 'per_page': perPage }
      });
      
      return {
        data: response.data.data.map(server => server.attributes),
        meta: response.data.meta
      };
    } catch (error) {
      throw new Error(`Error al obtener servidores: ${error.message}`);
    }
  }

  async getServerDetails(serverId) {
    try {
      const response = await this.client.get(`/api/application/servers/${serverId}`);
      return response.data.attributes;
    } catch (error) {
      if (error.response?.status === 404) {
        throw new Error(`Servidor ${serverId} no encontrado`);
      }
      throw error;
    }
  }

  async getNodeInfo(nodeId) {
    try {
      const response = await this.client.get(`/api/application/nodes/${nodeId}`);
      return response.data.attributes;
    } catch (error) {
      throw new Error(`Error al obtener información del nodo ${nodeId}: ${error.message}`);
    }
  }

  async getNodeAllocations(nodeId) {
    try {
      const response = await this.client.get(`/api/application/nodes/${nodeId}/allocations`);
      return response.data.data.map(allocation => allocation.attributes);
    } catch (error) {
      throw new Error(`Error al obtener asignaciones del nodo ${nodeId}: ${error.message}`);
    }
  }

  async getAllNodes(page = 1, perPage = 50) {
    try {
      const response = await this.client.get('/api/application/nodes', {
        params: { page, 'per_page': perPage }
      });
      
      return {
        data: response.data.data.map(node => node.attributes),
        meta: response.data.meta
      };
    } catch (error) {
      throw new Error(`Error al obtener nodos: ${error.message}`);
    }
  }

  async suspendServer(serverId) {
    try {
      await this.client.post(`/api/application/servers/${serverId}/suspend`);
      logger.info(`Servidor ${serverId} suspendido`);
      return true;
    } catch (error) {
      throw new Error(`Error al suspender servidor ${serverId}: ${error.message}`);
    }
  }

  async unsuspendServer(serverId) {
    try {
      await this.client.post(`/api/application/servers/${serverId}/unsuspend`);
      logger.info(`Servidor ${serverId} reactivado`);
      return true;
    } catch (error) {
      throw new Error(`Error al reactivar servidor ${serverId}: ${error.message}`);
    }
  }

  async reinstallServer(serverId) {
    try {
      await this.client.post(`/api/application/servers/${serverId}/reinstall`);
      logger.info(`Servidor ${serverId} reinstalado`);
      return true;
    } catch (error) {
      throw new Error(`Error al reinstalar servidor ${serverId}: ${error.message}`);
    }
  }
}

module.exports = new PterodactylService();
