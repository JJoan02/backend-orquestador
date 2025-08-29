# Panel-TK Backend API

Backend API para Panel-TK, un sistema de gestión de servidores de juegos basado en Pterodactyl Panel.

## 🚀 Características

- **Gestión de Usuarios**: Registro, autenticación y gestión de perfiles
- **Gestión de Servidores**: Crear, editar, suspender y eliminar servidores
- **Sistema TK-Coins**: Moneda virtual para comprar servicios
- **Dashboard**: Estadísticas y métricas en tiempo real
- **Panel de Administrador**: Gestión completa del sistema
- **API RESTful**: Endpoints bien documentados y seguros
- **Autenticación JWT**: Seguridad robusta con tokens
- **Rate Limiting**: Protección contra abuso de la API
- **Webhooks**: Notificaciones en tiempo real de eventos del sistema
- **Sistema de Logs**: Registro detallado de todas las operaciones
- **Caché con Redis**: Mejora de rendimiento con caché distribuido

## 📋 Requisitos Previos

- **Node.js >= 20.0.0** (versión estable recomendada)
- PostgreSQL >= 12
- Redis (opcional para caché)
- Pterodactyl Panel configurado

## 🔧 Instalación

1. **Clonar el repositorio**
```bash
git clone https://github.com/tu-usuario/panel-tk-backend.git
cd panel-tk-backend
```

2. **Verificar versión de Node.js**
```bash
node --version  # Debe ser >= 20.0.0
```

3. **Instalar dependencias**
```bash
npm install
```

4. **Configurar variables de entorno**
```bash
cp .env.example .env
# Editar .env con tus configuraciones
```

5. **Configurar base de datos**
```bash
# Crear base de datos en PostgreSQL
createdb panel_tk

# Ejecutar migraciones (si las hay)
npm run migrate
```

6. **Iniciar el servidor**
```bash
# Modo desarrollo
npm run dev

# Modo producción
npm start
```

## 📁 Estructura del Proyecto

```
backend-orquestador/
├── src/
│   ├── middleware/          # Middleware de autenticación y validación
│   │   ├── auth.js         # Autenticación JWT
│   │   ├── rateLimiter.js  # Limitador de peticiones
│   │   └── validation.js   # Validación de datos
│   ├── routes/             # Rutas de la API
│   │   ├── index.js        # Punto de entrada de rutas
│   │   ├── users.js        # Rutas de usuarios
│   │   ├── servers.js      # Rutas de servidores
│   │   ├── dashboard.js    # Rutas del dashboard
│   │   ├── auth.js         # Rutas de autenticación
│   │   └── webhooks.js     # Webhooks del sistema
│   ├── services/           # Servicios externos y lógica de negocio
│   │   ├── pterodactyl.js  # Integración con Pterodactyl
│   │   ├── database.js     # Conexión a PostgreSQL
│   │   ├── redis.js        # Conexión a Redis
│   │   └── logger.js       # Sistema de logging
│   ├── models/             # Modelos de base de datos
│   ├── utils/              # Utilidades y helpers
│   └── config/             # Configuraciones del sistema
├── logs/                   # Archivos de log
├── .env.example           # Ejemplo de variables de entorno
├── index.js               # Punto de entrada principal
├── package.json           # Dependencias y scripts
└── ecosystem.config.js    # Configuración PM2
```

## 🔌 Endpoints de la API

### Autenticación
- `POST /api/auth/register` - Registro de nuevos usuarios
- `POST /api/auth/login` - Inicio de sesión
- `POST /api/auth/logout` - Cierre de sesión
- `POST /api/auth/refresh` - Refrescar token
- `POST /api/auth/forgot-password` - Recuperar contraseña
- `POST /api/auth/reset-password` - Restablecer contraseña

### Usuarios
- `GET /api/users/profile` - Obtener perfil del usuario
- `PUT /api/users/profile` - Actualizar perfil
- `GET /api/users/:id` - Obtener usuario por ID (admin)
- `GET /api/users` - Listar todos los usuarios (admin)
- `DELETE /api/users/:id` - Eliminar usuario (admin)
- `PUT /api/users/:id/tk-coins` - Actualizar TK-Coins (admin)

### Servidores
- `GET /api/servers` - Listar servidores del usuario
- `POST /api/servers` - Crear nuevo servidor
- `GET /api/servers/:id` - Obtener detalles del servidor
- `PUT /api/servers/:id` - Actualizar servidor
- `DELETE /api/servers/:id` - Eliminar servidor
- `POST /api/servers/:id/power` - Control de encendido/apagado
- `POST /api/servers/:id/suspend` - Suspender servidor (admin)
- `POST /api/servers/:id/unsuspend` - Reactivar servidor (admin)

### Dashboard
- `GET /api/dashboard` - Dashboard principal del usuario
- `GET /api/dashboard/admin` - Dashboard de administrador
- `GET /api/dashboard/stats` - Estadísticas del usuario
- `GET /api/dashboard/system-stats` - Estadísticas del sistema (admin)

### Webhooks
- `POST /api/webhooks/pterodactyl` - Webhook de eventos de Pterodactyl
- `POST /api/webhooks/payment` - Webhook de pagos
- `GET /api/webhooks/logs` - Ver logs de webhooks (admin)

## 🔐 Autenticación

La API utiliza JWT (JSON Web Tokens) para la autenticación. Incluye el token en el header de las peticiones:

```
Authorization: Bearer <tu-token-jwt>
```

### Refresh Tokens
Los tokens de acceso expiran después de 15 minutos. Usa el endpoint `/api/auth/refresh` con tu refresh token para obtener un nuevo token de acceso.

## 🧪 Testing

```bash
# Ejecutar tests
npm test

# Ejecutar tests en modo watch
npm run test:watch

# Ejecutar linter
npm run lint

# Arreglar problemas de linting automáticamente
npm run lint:fix
```

## 🐳 Docker (Opcional)

```bash
# Construir imagen
docker build -t panel-tk-backend .

# Ejecutar con docker-compose
docker-compose up -d
```

## 📊 Monitoreo

- **Logs**: Los logs se guardan en `./logs/`
- **Health Check**: `GET /api/health`
- **Métricas**: `GET /api/metrics` (requiere autenticación admin)

## 🚨 Solución de Problemas

### Error: "Cannot find module"
```bash
npm install
```

### Error de conexión a PostgreSQL
1. Verificar que PostgreSQL esté ejecutándose
2. Verificar credenciales en `.env`
3. Verificar que la base de datos exista

### Error de conexión a Redis
1. Verificar que Redis esté ejecutándose
2. Verificar configuración en `.env`

## 🤝 Contribuir

1. Fork el proyecto
2. Crear una rama para tu feature (`git checkout -b feature/AmazingFeature`)
3. Commit tus cambios (`git commit -m 'Add some AmazingFeature'`)
4. Push a la rama (`git push origin feature/AmazingFeature`)
5. Abrir un Pull Request

## 📄 Licencia

Este proyecto está bajo la Licencia MIT - ver el archivo [LICENSE](LICENSE) para detalles.

## 👥 Soporte

- Documentación: [docs.panel-tk.com](https://docs.panel-tk.com)
- Discord: [discord.gg/panel-tk](https://discord.gg/panel-tk)
- Issues: [GitHub Issues](https://github.com/tu-usuario/panel-tk-backend/issues)
