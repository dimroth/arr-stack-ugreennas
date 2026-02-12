#!/bin/sh
# Generate crontab from environment variables

PAUSE_HOUR=${PAUSE_HOUR:-20}
RESUME_HOUR=${RESUME_HOUR:-6}

# Validate hours (prevent cron injection)
for var_name in PAUSE_HOUR RESUME_HOUR; do
    eval val=\$$var_name
    case "$val" in
        [0-9]|1[0-9]|2[0-3]) ;;  # Valid 0-23
        *) echo "ERROR: $var_name must be 0-23, got: $val"; exit 1 ;;
    esac
done

cat > /etc/crontabs/root << EOF
# Pause all torrents at ${PAUSE_HOUR}:00
0 ${PAUSE_HOUR} * * * /app/pause-resume.sh pause >> /proc/1/fd/1 2>&1

# Resume all torrents at ${RESUME_HOUR}:00
0 ${RESUME_HOUR} * * * /app/pause-resume.sh resume >> /proc/1/fd/1 2>&1
EOF

echo "qbit-scheduler: pause at ${PAUSE_HOUR}:00, resume at ${RESUME_HOUR}:00 (TZ: ${TZ:-UTC})"

# Run crond in foreground
exec crond -f -l 2
