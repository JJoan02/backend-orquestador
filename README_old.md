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

## 📋 Requisitos Previos

- Node.js >= 16.0.0
- PostgreSQL >= 12
- Redis (opcional para caché)
- Pterodactyl Panel configurado

## 🔧 Instalación

1. **Clonar el repositorio**
```bash
git clone https://github.com/tu-usuario/panel-tk-backend.git
cd panel-tk-backend
```

2. **Instalar dependencias**
```bash
npm install
```

3. **Configurar variables de entorno**
```bash
cp .env.example .env
# Editar .env con tus configuraciones
```

4. **Configurar base de datos**
```bash
# Crear base de datos en PostgreSQL
createdb panel_tk

# Ejecutar migraciones (si las hay)
npm run migrate
```

5. **Iniciar el servidor**
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
│   ├── routes/             # Rutas de la API
│   │   ├── index.js        # Punto de entrada de rutas
│   │   ├── users.js        # Rutas de usuarios
│   │   ├── servers.js      # Rutas de servidores
│   │   └── dashboard.js    # Rutas del dashboard
│   └── services/           # Servicios externos y lógica de negocio
├── logs/                   # Archivos de log
├── .env.example           # Ejemplo de variables de entorno
├── index.js               # Punto de entrada principal
└── package.json           # Dependencias y scripts
```

## 🔌 Endpoints de la API

### Autenticación
- `POST /api/auth/register` - Registro de nuevos usuarios
- `POST /api/auth/login` - Inicio de sesión
- `POST /api/auth/logout` - Cierre de sesión
- `POST /api/auth/refresh` - Refrescar token

### Usuarios
- `GET /api/users/profile` - Obtener perfil del usuario
- `PUT /api/users/profile` - Actualizar perfil
- `GET /api/users/:id` - Obtener usuario por ID (admin)

### Servidores
- `GET /api/servers` - Listar servidores del usuario
- `POST /api/servers` - Crear nuevo servidor
- `GET /api/servers/:id` - Obtener detalles del servidor
- `PUT /api/servers/:id` - Actualizar servidor
- `DELETE /api/servers/:id` - Eliminar servidor
- `POST /api/servers/:id/power` - Control de encendido/apagado

### Dashboard
- `GET /api/dashboard` - Dashboard principal del usuario
- `GET /api/dashboard/admin` - Dashboard de administrador
- `GET /api/dashboard/stats` - Estadísticas del usuario

## 🔐 Autenticación

La API utiliza JWT (JSON Web Tokens) para la autenticación. Incluye el token en el header de las peticiones:

```
Authorization: Bearer <tu-token-jwt>
```

## 🧪 Testing

```bash
# Ejecutar todos los tests
npm test

# Ejecutar tests en modo watch
npm run test:watch
```

## 📝 Scripts Disponibles

- `npm start` - Iniciar servidor en producción
- `npm run dev` - Iniciar servidor en desarrollo con nodemon
- `npm test` - Ejecutar tests
- `npm run lint` - Ejecutar linter
- `npm run lint:fix` - Ejecutar linter y arreglar errores automáticamente

## 🐛 Solución de Problemas

### Error de conexión a PostgreSQL
```bash
# Verificar que PostgreSQL esté corriendo
sudo systemctl status postgresql

# Verificar credenciales en .env
```

### Error de conexión a Pterodactyl
```bash
# Verificar URL y API key en .env
# Verificar que el panel esté accesible
```

## 🤝 Contribuir

1. Fork el proyecto
2. Crea tu feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit tus cambios (`git commit -m 'Add some AmazingFeature'`)
4. Push a la branch (`git push origin feature/AmazingFeature`)
5. Abre un Pull Request

## 📄 Licencia

Este proyecto está bajo la Licencia MIT. Ver el archivo `LICENSE` para más detalles.

## 👥 Soporte

Para soporte, por favor abre un issue en GitHub o contacta al equipo de desarrollo.
