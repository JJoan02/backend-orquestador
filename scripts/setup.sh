#!/bin/bash
# PanelTK Setup Script
# This script automates the initial setup and configuration of the PanelTK application

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/var/log/panel-tk/setup.log"
BACKUP_DIR="/opt/panel-tk/backups"
CONFIG_DIR="/opt/panel-tk/config"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Check system requirements
check_requirements() {
    info "Checking system requirements..."
    
    # Check OS
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS version"
        exit 1
    fi
    
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
    
    info "Detected OS: $OS $VER"
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        warning "Docker is not installed. Installing Docker..."
        install_docker
    fi
    
    # Check if Docker Compose is installed
    if ! command -v docker-compose &> /dev/null; then
        warning "Docker Compose is not installed. Installing Docker Compose..."
        install_docker_compose
    fi
    
    # Check system resources
    check_system_resources
}

# Check system resources
check_system_resources() {
    info "Checking system resources..."
    
    # Check RAM
    TOTAL_RAM=$(free -g | awk 'NR==2{print $2}')
    if [[ $TOTAL_RAM -lt 4 ]]; then
        warning "System has less than 4GB RAM. PanelTK may run slowly."
    fi
    
    # Check disk space
    AVAILABLE_DISK=$(df -BG / | awk 'NR==2{print $4}' | sed 's/G//')
    if [[ $AVAILABLE_DISK -lt 20 ]]; then
        error "Insufficient disk space. At least 20GB required."
        exit 1
    fi
    
    # Check CPU cores
    CPU_CORES=$(nproc)
    if [[ $CPU_CORES -lt 2 ]]; then
        warning "System has less than 2 CPU cores. Performance may be affected."
    fi
    
    success "System requirements check completed"
}

# Install Docker
install_docker() {
    info "Installing Docker..."
    
    case $OS in
        ubuntu|debian)
            apt-get update
            apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
            curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
            apt-get update
            apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
        centos|rhel|fedora)
            yum install -y yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
            systemctl start docker
            systemctl enable docker
            ;;
        *)
            error "Unsupported OS for automatic Docker installation"
            exit 1
            ;;
    esac
    
    # Add current user to docker group
    usermod -aG docker $SUDO_USER || true
    
    success "Docker installed successfully"
}

# Install Docker Compose
install_docker_compose() {
    info "Installing Docker Compose..."
    
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    success "Docker Compose installed successfully"
}

# Create directories
create_directories() {
    info "Creating necessary directories..."
    
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "/var/log/panel-tk"
    mkdir -p "/opt/panel-tk/data"
    mkdir -p "/opt/panel-tk/certs"
    mkdir -p "/opt/panel-tk/uploads"
    
    # Set permissions
    chown -R paneltk:paneltk /opt/panel-tk
    chmod -R 755 /opt/panel-tk
    
    success "Directories created successfully"
}

# Setup firewall
setup_firewall() {
    info "Configuring firewall..."
    
    # Check if ufw is available
    if command -v ufw &> /dev/null; then
        ufw allow 22/tcp
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 8080/tcp
        ufw allow 3306/tcp
        ufw allow 5432/tcp
        ufw allow 6379/tcp
        ufw allow 9090/tcp
        ufw allow 3000/tcp
        
        # Enable UFW if not already enabled
        if ! ufw status | grep -q "Status: active"; then
            ufw --force enable
        fi
        
        success "Firewall configured successfully"
    else
        warning "UFW not found. Please configure firewall manually"
    fi
}

# Generate SSL certificates
generate_ssl_certs() {
    info "Generating SSL certificates..."
    
    CERT_DIR="/opt/panel-tk/certs"
    
    # Create self-signed certificate for development
    if [[ ! -f "$CERT_DIR/panel-tk.crt ]]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$CERT_DIR/panel-tk.key" \
            -out "$CERT_DIR/panel-tk.crt" \
            -subj "/C=US/ST=State/L=City/O=PanelTK/CN=panel-tk.local"
        
        success "SSL certificates generated"
    else
        info "SSL certificates already exist"
    fi
}

# Setup environment variables
setup_env() {
    info "Setting up environment variables..."
    
    ENV_FILE="$PROJECT_ROOT/.env"
    
    if [[ ! -f "$ENV_FILE" ]]; then
        cat > "$ENV_FILE" << EOF
# PanelTK Environment Configuration
NODE_ENV=production
PORT=3000
HOST=0.0.0.0

# Database Configuration
DB_HOST=postgres
DB_PORT=5432
DB_NAME=panel_tk
DB_USER=paneltk
DB_PASSWORD=paneltk_secure_password_2024
DB_SSL=false

# Redis Configuration
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=redis_secure_password_2024

# JWT Configuration
JWT_SECRET=your_jwt_secret_key_here_change_in_production
JWT_EXPIRES_IN=7d

# Pterodactyl Configuration
PTERODACTYL_URL=https://your-pterodactyl-panel.com
PTERODACTYL_API_KEY=your_pterodactyl_api_key_here

# Email Configuration
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your_email@gmail.com
SMTP_PASS=your_email_password
SMTP_FROM=noreply@paneltk.com

# SSL Configuration
SSL_CERT_PATH=/opt/panel-tk/certs/panel-tk.crt
SSL_KEY_PATH=/opt/panel-tk/certs/panel-tk.key

# Monitoring Configuration
PROMETHEUS_PORT=9090
GRAFANA_PORT=3001

# Security Configuration
BCRYPT_ROUNDS=12
SESSION_SECRET=your_session_secret_here_change_in_production

# File Upload Configuration
MAX_FILE_SIZE=100MB
UPLOAD_DIR=/opt/panel-tk/uploads

# Backup Configuration
BACKUP_RETENTION_DAYS=30
BACKUP_SCHEDULE=0 2 * * *

# Logging Configuration
LOG_LEVEL=info
LOG_FILE=/var/log/panel-tk/app.log

# Development Configuration
DEBUG=false
ENABLE_SWAGGER=false
EOF
        
        warning "Environment file created. Please review and update the values!"
    else
        info "Environment file already exists"
    fi
}

# Install dependencies
install_dependencies() {
    info "Installing system dependencies..."
    
    case $OS in
        ubuntu|debian)
            apt-get update
            apt-get install -y curl wget git nginx postgresql-client redis-tools
            ;;
        centos|rhel|fedora)
            yum install -y curl wget git nginx postgresql redis
            ;;
    esac
    
    success "System dependencies installed"
}

# Setup logrotate
setup_logrotate() {
    info "Setting up logrotate..."
    
    cp "$PROJECT_ROOT/docker/logrotate/logrotate.conf" "/etc/logrotate.d/panel-tk"
    
    # Create logrotate cron job
    cat > "/etc/cron.daily/panel-tk-logrotate" << 'EOF'
#!/bin/bash
/usr/sbin/logrotate /etc/logrotate.d/panel-tk
EXITVALUE=$?
if [ $EXITVALUE != 0 ]; then
    /usr/bin/logger -t logrotate "ALERT exited abnormally with [$EXITVALUE]"
fi
exit 0
EOF
    
    chmod +x "/etc/cron.daily/panel-tk-logrotate"
    
    success "Logrotate configured"
}

# Setup systemd services
setup_systemd() {
    info "Setting up systemd services..."
    
    # Create systemd service for PanelTK
    cat > "/etc/systemd/system/panel-tk.service" << EOF
[Unit]
Description=PanelTK Application
After=network.target docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PROJECT_ROOT
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable panel-tk.service
    
    success "Systemd services configured"
}

# Setup monitoring
setup_monitoring() {
    info "Setting up monitoring..."
    
    # Create monitoring directories
    mkdir -p /opt/monitoring/prometheus
    mkdir -p /opt/monitoring/grafana
    
    # Copy monitoring configurations
    cp "$PROJECT_ROOT/docker/prometheus/prometheus.yml" /opt/monitoring/prometheus/
    cp "$PROJECT_ROOT/docker/prometheus/alert_rules.yml" /opt/monitoring/prometheus/
    
    success "Monitoring configured"
}

# Run database migrations
run_migrations() {
    info "Running database migrations..."
    
    # Wait for PostgreSQL to be ready
    until docker-compose exec postgres pg_isready -U paneltk; do
        info "Waiting for PostgreSQL..."
        sleep 5
    done
    
    # Run migrations
    docker-compose exec app npm run migrate
    
    success "Database migrations completed"
}

# Create backup script
create_backup_script() {
    info "Creating backup script..."
    
    cat > "/opt/panel-tk/scripts/backup.sh" << 'EOF'
#!/bin/bash
# PanelTK Backup Script

BACKUP_DIR="/opt/panel-tk/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="panel-tk_backup_${DATE}.tar.gz"

# Create backup
cd /opt/panel-tk
tar -czf "${BACKUP_DIR}/${BACKUP_FILE}" \
    --exclude='node_modules' \
    --exclude='.git' \
    --exclude='*.log' \
    .

# Backup database
docker-compose exec postgres pg_dump -U paneltk panel_tk > "${BACKUP_DIR}/database_${DATE}.sql"

# Cleanup old backups (keep last 30 days)
find "${BACKUP_DIR}" -name "*.tar.gz" -mtime +30 -delete
find "${BACKUP_DIR}" -name "*.sql" -mtime +30 -delete

echo "Backup completed: ${BACKUP_FILE}"
EOF
    
    chmod +x "/opt/panel-tk/scripts/backup.sh"
    
    # Add to crontab
    (crontab -l 2>/dev/null; echo "0 2 * * * /opt/panel-tk/scripts/backup.sh") | crontab -
    
    success "Backup script created"
}

# Main setup function
main() {
    log "Starting PanelTK setup..."
    
    check_root
    check_requirements
    install_dependencies
    create_directories
    setup_env
    generate_ssl_certs
    setup_firewall
    setup_logrotate
    setup_systemd
    setup_monitoring
    create_backup_script
    
    success "PanelTK setup completed successfully!"
    info "Next steps:"
    echo "1. Review and update .env file with your configuration"
    echo "2. Run: docker-compose up -d"
    echo "3. Access the application at https://localhost:3000"
    echo "4. Default admin credentials: admin / admin123"
    echo ""
    warning "Remember to change default passwords and secrets!"
}

# Run main function
main "$@"
