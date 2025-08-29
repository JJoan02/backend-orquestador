# PanelTK Restore Documentation

## Overview
This document provides comprehensive instructions for restoring PanelTK from backups using the automated restore script.

## Prerequisites
- Root or sudo access
- Docker and Docker Compose installed
- Sufficient disk space for restoration
- Network connectivity for remote backups (if applicable)

## Quick Start
```bash
# Basic restore from latest backup
./scripts/restore.sh

# Restore from specific backup
./scripts/restore.sh --backup 2024-01-15_14-30-00

# Restore with custom configuration
./scripts/restore.sh --config /path/to/custom/restore.conf

# Dry run to see what would be restored
./scripts/restore.sh --dry-run
```

## Configuration
The restore script uses `scripts/restore.conf` for configuration. Key settings:

### Database Settings
- `DB_NAME`: PostgreSQL database name
- `DB_USER`: Database username
- `DB_PASSWORD`: Database password
- `DB_HOST`: Database host (default: localhost)
- `DB_PORT`: Database port (default: 5432)

### Backup Settings
- `BACKUP_DIR`: Local backup directory
- `TEMP_DIR`: Temporary directory for extraction
- `LOG_FILE`: Log file location

### Remote Storage
- `S3_BUCKET`: AWS S3 bucket name
- `FTP_HOST`: FTP server hostname
- `FTP_USER`: FTP username

## Restore Process

### 1. Pre-restore Checks
- System requirements verification
- Available disk space check
- Backup integrity validation
- Service status verification

### 2. Backup Selection
- Local backups: `/opt/panel-tk/backups/`
- Remote backups: S3 or FTP
- Interactive selection if multiple backups exist

### 3. Restoration Steps
1. **Database Restore**
   - Stop application services
   - Drop existing database
   - Create new database
   - Restore from SQL dump

2. **File System Restore**
   - Extract backup archive
   - Restore application files
   - Restore configuration files
   - Restore SSL certificates

3. **Service Restart**
   - Start PostgreSQL
   - Start Redis
   - Start application containers
   - Verify service health

### 4. Post-restore Verification
- Database connectivity test
- API endpoint testing
- Service health checks
- Log verification

## Advanced Usage

### Automated Restore
```bash
# Non-interactive restore
./scripts/restore.sh --non-interactive --backup 2024-01-15_14-30-00

# Restore with email notification
./scripts/restore.sh --notify-email admin@example.com

# Restore with webhook notification
./scripts/restore.sh --notify-webhook https://hooks.slack.com/services/...
```

### Partial Restore
```bash
# Restore only database
./scripts/restore.sh --database-only

# Restore only files
./scripts/restore.sh --files-only

# Restore specific components
./scripts/restore.sh --components nginx,postgres
```

### Disaster Recovery
```bash
# Full system restore on new server
./scripts/restore.sh --disaster-recovery --new-server

# Restore from specific date range
./scripts/restore.sh --from-date 2024-01-01 --to-date 2024-01-15
```

## Troubleshooting

### Common Issues

#### "Insufficient disk space"
- Check available space: `df -h`
- Clean temporary files: `./scripts/restore.sh --cleanup`
- Use external storage for temporary files

#### "Database connection failed"
- Verify PostgreSQL is running: `systemctl status postgresql`
- Check connection parameters in restore.conf
- Ensure database user has proper permissions

#### "Backup file corrupted"
- Verify backup integrity: `./scripts/restore.sh --verify-backup`
- Try alternative backup file
- Check backup logs for errors

### Log Analysis
```bash
# View restore logs
tail -f /var/log/panel-tk/restore.log

# Check specific error
grep ERROR /var/log/panel-tk/restore.log

# Debug mode
./scripts/restore.sh --debug --verbose
```

## Security Considerations
- Backup files contain sensitive data - ensure secure storage
- Use encrypted backups for sensitive environments
- Rotate backup encryption keys regularly
- Limit restore script access to authorized personnel

## Monitoring and Alerts
- Set up monitoring for backup integrity
- Configure alerts for failed restores
- Monitor disk space during restore operations
- Track restore performance metrics

## Support
For issues or questions:
- Check logs: `/var/log/panel-tk/restore.log`
- Review documentation: `./docs/RESTORE.md`
- Contact support: support@panel-tk.com
