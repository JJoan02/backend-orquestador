-- PanelTK Database Initialization Script
-- This script sets up the initial database structure for the PanelTK application

-- Create database if it doesn't exist
CREATE DATABASE IF NOT EXISTS panel_tk;

-- Connect to the database
\c panel_tk;

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create users table
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) DEFAULT 'user' CHECK (role IN ('user', 'admin', 'moderator')),
    is_active BOOLEAN DEFAULT true,
    email_verified BOOLEAN DEFAULT false,
    avatar_url VARCHAR(500),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_login TIMESTAMP WITH TIME ZONE,
    failed_login_attempts INTEGER DEFAULT 0,
    locked_until TIMESTAMP WITH TIME ZONE
);

-- Create servers table
CREATE TABLE IF NOT EXISTS servers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    pterodactyl_id INTEGER UNIQUE NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    node_id INTEGER NOT NULL,
    allocation_id INTEGER NOT NULL,
    egg_id INTEGER NOT NULL,
    docker_image VARCHAR(255),
    startup_command TEXT,
    environment JSONB DEFAULT '{}',
    limits JSONB DEFAULT '{}',
    feature_limits JSONB DEFAULT '{}',
    is_suspended BOOLEAN DEFAULT false,
    is_installing BOOLEAN DEFAULT false,
    status VARCHAR(20) DEFAULT 'offline',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create server_backups table
CREATE TABLE IF NOT EXISTS server_backups (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    server_id UUID NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    pterodactyl_backup_id VARCHAR(100) NOT NULL,
    name VARCHAR(100) NOT NULL,
    file_size BIGINT,
    checksum VARCHAR(64),
    is_locked BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE,
    failed_at TIMESTAMP WITH TIME ZONE
);

-- Create server_schedules table
CREATE TABLE IF NOT EXISTS server_schedules (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    server_id UUID NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    pterodactyl_schedule_id INTEGER NOT NULL,
    name VARCHAR(100) NOT NULL,
    cron_expression VARCHAR(100) NOT NULL,
    is_active BOOLEAN DEFAULT true,
    is_processing BOOLEAN DEFAULT false,
    last_run TIMESTAMP WITH TIME ZONE,
    next_run TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create api_keys table
CREATE TABLE IF NOT EXISTS api_keys (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_hash VARCHAR(255) NOT NULL,
    name VARCHAR(100) NOT NULL,
    permissions JSONB DEFAULT '{}',
    last_used_at TIMESTAMP WITH TIME ZONE,
    expires_at TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create audit_logs table
CREATE TABLE IF NOT EXISTS audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    action VARCHAR(50) NOT NULL,
    resource_type VARCHAR(50) NOT NULL,
    resource_id VARCHAR(100),
    ip_address INET,
    user_agent TEXT,
    details JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create notifications table
CREATE TABLE IF NOT EXISTS notifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    type VARCHAR(50) NOT NULL,
    title VARCHAR(255) NOT NULL,
    message TEXT NOT NULL,
    is_read BOOLEAN DEFAULT false,
    action_url VARCHAR(500),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create server_stats table for monitoring
CREATE TABLE IF NOT EXISTS server_stats (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    server_id UUID NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    cpu_usage DECIMAL(5,2),
    memory_usage BIGINT,
    disk_usage BIGINT,
    network_rx BIGINT,
    network_tx BIGINT,
    players_online INTEGER DEFAULT 0,
    tps DECIMAL(4,2),
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
CREATE INDEX IF NOT EXISTS idx_servers_user_id ON servers(user_id);
CREATE INDEX IF NOT EXISTS idx_servers_pterodactyl_id ON servers(pterodactyl_id);
CREATE INDEX IF NOT EXISTS idx_server_backups_server_id ON server_backups(server_id);
CREATE INDEX IF NOT EXISTS idx_server_schedules_server_id ON server_schedules(server_id);
CREATE INDEX IF NOT EXISTS idx_api_keys_user_id ON api_keys(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id ON audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON audit_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON notifications(created_at);
CREATE INDEX IF NOT EXISTS idx_server_stats_server_id ON server_stats(server_id);
CREATE INDEX IF NOT EXISTS idx_server_stats_recorded_at ON server_stats(recorded_at);

-- Create function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create triggers for updated_at
CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_servers_updated_at BEFORE UPDATE ON servers
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_server_schedules_updated_at BEFORE UPDATE ON server_schedules
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Create admin user (password: admin123 - change in production!)
INSERT INTO users (username, email, password_hash, role, email_verified) 
VALUES ('admin', 'admin@paneltk.com', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBPj/J9eHCOOLa', 'admin', true)
ON CONFLICT (username) DO NOTHING;

-- Create default permissions for API keys
INSERT INTO api_keys (user_id, key_hash, name, permissions) 
SELECT id, 'default_admin_key', 'Default Admin Key', '{"servers": ["read", "write", "delete"], "users": ["read", "write"], "backups": ["read", "write", "delete"]}'::jsonb
FROM users WHERE username = 'admin' AND NOT EXISTS (
    SELECT 1 FROM api_keys WHERE user_id = users.id AND name = 'Default Admin Key'
);

-- Grant permissions
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO paneltk;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO paneltk;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO paneltk;

-- Create read-only user for monitoring
CREATE USER IF NOT EXISTS paneltk_readonly WITH PASSWORD 'readonly_secure_password_2024';
GRANT CONNECT ON DATABASE panel_tk TO paneltk_readonly;
GRANT USAGE ON SCHEMA public TO paneltk_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO paneltk_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO paneltk_readonly;
