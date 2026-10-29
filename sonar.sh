#!/bin/bash

# ============================================================
# Amazon Corretto 21 + SonarQube (Community Build)
# Operating System: RHEL 10   (EC2 t3.medium / 4 GB RAM minimum)
#
# Usage : sudo bash sonarqube.sh
#
# Root (sudo) is used ONLY for system setup: packages, Java,
# kernel parameters, user creation and file ownership.
# SonarQube itself is ALWAYS started and run as the "sonar" user.
# It is never run as root.
#
# Optional: SONARQUBE_VERSION=26.10.0.133078 sudo -E bash sonarqube.sh
# ============================================================

set -o pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

JAVA_VERSION="21"
JAVA_PACKAGE="java-${JAVA_VERSION}-amazon-corretto-devel"
JAVA_HOME_PATH="/usr/lib/jvm/java-${JAVA_VERSION}-amazon-corretto"

SONARQUBE_VERSION="${SONARQUBE_VERSION:-26.10.0.133078}"
SONARQUBE_BASE_URL="https://binaries.sonarsource.com/Distribution/sonarqube"
SONARQUBE_ARCHIVE="sonarqube-${SONARQUBE_VERSION}.zip"
SONARQUBE_URL="${SONARQUBE_BASE_URL}/${SONARQUBE_ARCHIVE}"

INSTALL_BASE_DIR="/opt"
SONARQUBE_HOME="/opt/sonarqube"
SONAR_SCRIPT_DIR="${SONARQUBE_HOME}/bin/linux-x86-64"
SONAR_USER="sonar"
SONAR_GROUP="sonar"
SONAR_HOME_DIR="/home/${SONAR_USER}"
SONAR_PORT="9000"

SYSCTL_FILE="/etc/sysctl.d/99-sonarqube.conf"
LIMITS_FILE="/etc/security/limits.d/99-sonarqube.conf"
OLD_SERVICE_FILE="/etc/systemd/system/sonarqube.service"

STARTUP_TIMEOUT=300
MIN_RAM_KB=3500000
ALLOW_LOW_RAM="${ALLOW_LOW_RAM:-false}"
RUN_SYSTEM_UPDATE="${RUN_SYSTEM_UPDATE:-false}"

LOGFILE="/tmp/sonarqube-install-$(date +%F-%H-%M-%S).log"

# ------------------------------------------------------------
# Functions
# ------------------------------------------------------------

VALIDATE() {
    local STATUS="$1"
    local MESSAGE="$2"

    if [ "$STATUS" -eq 0 ]; then
        echo "$MESSAGE... SUCCESS"
    else
        echo "$MESSAGE... FAILURE"
        echo "Check log file: $LOGFILE"
        exit 1
    fi
}

SKIP() {
    echo "$1... SKIPPING (already done)"
}

WARN() {
    echo "WARNING: $1"
}

# Run a shell command as the sonar user in a login session
# (loads PAM limits and the sonar user's environment).
RUN_AS_SONAR() {
    runuser -l "$SONAR_USER" -c "$1"
}

# ------------------------------------------------------------
# Root Check (needed for setup only)
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run this script with sudo/root for the one-time setup."
    echo "       SonarQube itself will be started as user '$SONAR_USER'."
    echo "Command: sudo bash sonarqube.sh"
    exit 1
fi

touch "$LOGFILE" || {
    echo "ERROR: Cannot create log file."
    exit 1
}

echo
echo "============================================================"
echo " Java ${JAVA_VERSION} + SonarQube Installation"
echo "============================================================"
echo
echo "Java Version      : $JAVA_VERSION"
echo "SonarQube Version : $SONARQUBE_VERSION"
echo "SonarQube Home    : $SONARQUBE_HOME"
echo "Runs As User      : $SONAR_USER (never root)"
echo "Log File          : $LOGFILE"
echo

# ------------------------------------------------------------
# Pre-flight Checks (memory and disk)
# ------------------------------------------------------------

MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)

if [ -n "$MEM_KB" ] && [ "$MEM_KB" -lt "$MIN_RAM_KB" ]; then
    echo "ERROR: Only $((MEM_KB / 1024)) MB RAM detected."
    echo "       SonarQube needs about 4 GB (use t3.medium or larger)."
    echo "       On smaller instances the Linux OOM killer stops Elasticsearch."
    if [ "$ALLOW_LOW_RAM" != "true" ]; then
        echo "       To force anyway (not recommended): ALLOW_LOW_RAM=true sudo -E bash sonarqube.sh"
        exit 1
    fi
    WARN "Continuing because ALLOW_LOW_RAM=true. Startup will probably fail."
fi

DISK_KB=$(df --output=avail -k "$INSTALL_BASE_DIR" | tail -n 1 | tr -d ' ')

if [ -n "$DISK_KB" ] && [ "$DISK_KB" -lt 3000000 ]; then
    echo "ERROR: Less than 3 GB free in $INSTALL_BASE_DIR."
    exit 1
fi

# ------------------------------------------------------------
# Time Synchronization (non-fatal)
# ------------------------------------------------------------

timedatectl set-timezone UTC >> "$LOGFILE" 2>&1
timedatectl set-ntp true >> "$LOGFILE" 2>&1

if systemctl list-unit-files chronyd.service 2>/dev/null | grep -q chronyd; then
    systemctl enable --now chronyd >> "$LOGFILE" 2>&1
    if [ $? -eq 0 ]; then
        echo "Time synchronization (chronyd)... SUCCESS"
    else
        WARN "Could not start chronyd. Continuing."
    fi
else
    WARN "chronyd not installed. Skipping time sync."
fi

# ------------------------------------------------------------
# Optional System Update
# ------------------------------------------------------------

if [ "$RUN_SYSTEM_UPDATE" = "true" ]; then
    dnf update -y --allowerasing >> "$LOGFILE" 2>&1
    VALIDATE $? "System package update"
else
    SKIP "System package update"
fi

# ------------------------------------------------------------
# Required Packages
# (checked by command, not rpm name, because RHEL ships
#  curl-minimal and installing "curl" would conflict)
# ------------------------------------------------------------

MISSING_PKGS=""

for CMD in wget unzip tar curl
do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        MISSING_PKGS="$MISSING_PKGS $CMD"
    fi
done

if [ -n "$MISSING_PKGS" ]; then
    dnf install -y $MISSING_PKGS >> "$LOGFILE" 2>&1
    VALIDATE $? "Installing required packages"
else
    SKIP "Required packages"
fi

# ------------------------------------------------------------
# Install Amazon Corretto 21 JDK
# ------------------------------------------------------------

if rpm -q "$JAVA_PACKAGE" >/dev/null 2>&1; then
    SKIP "Java ${JAVA_VERSION} JDK"
else
    rpm --import https://yum.corretto.aws/corretto.key >> "$LOGFILE" 2>&1
    VALIDATE $? "Importing Corretto GPG key"

    curl -fsSL -o /etc/yum.repos.d/corretto.repo \
        https://yum.corretto.aws/corretto.repo >> "$LOGFILE" 2>&1
    VALIDATE $? "Adding Corretto repository"

    if dnf install -y "$JAVA_PACKAGE" >> "$LOGFILE" 2>&1; then
        echo "Installing Java ${JAVA_VERSION} JDK... SUCCESS"
    else
        WARN "Install with GPG check failed. Retrying with --nogpgcheck (RHEL 10 crypto policy)."
        dnf install -y "$JAVA_PACKAGE" --nogpgcheck >> "$LOGFILE" 2>&1
        VALIDATE $? "Installing Java ${JAVA_VERSION} JDK"
    fi
fi

if [ ! -x "$JAVA_HOME_PATH/bin/java" ]; then
    echo "ERROR: Java executable not found: $JAVA_HOME_PATH/bin/java"
    exit 1
fi

# Make Java 21 the system default (SonarQube 26.x will not run on Java 17)
alternatives --set java "$JAVA_HOME_PATH/bin/java" >> "$LOGFILE" 2>&1
VALIDATE $? "Setting Java ${JAVA_VERSION} as system default"

"$JAVA_HOME_PATH/bin/java" -version >> "$LOGFILE" 2>&1
VALIDATE $? "Checking Java installation"

# ------------------------------------------------------------
# Kernel Settings Required by Elasticsearch
# ------------------------------------------------------------

cat > "$SYSCTL_FILE" <<EOF
vm.max_map_count=262144
fs.file-max=131072
EOF
VALIDATE $? "Writing sysctl configuration"

sysctl --system >> "$LOGFILE" 2>&1
VALIDATE $? "Applying kernel settings"

CURRENT_MAP_COUNT=$(sysctl -n vm.max_map_count)

if [ "$CURRENT_MAP_COUNT" -lt 262144 ]; then
    echo "ERROR: vm.max_map_count is $CURRENT_MAP_COUNT (need 262144)."
    exit 1
fi

# ------------------------------------------------------------
# User Limits for the sonar user
# ------------------------------------------------------------

cat > "$LIMITS_FILE" <<EOF
${SONAR_USER}   -   nofile   131072
${SONAR_USER}   -   nproc    8192
EOF
VALIDATE $? "Configuring user limits"

# ------------------------------------------------------------
# Create the sonar User (no sudo rights)
# ------------------------------------------------------------

if id "$SONAR_USER" >/dev/null 2>&1; then
    SKIP "User $SONAR_USER creation"
else
    useradd -m -s /bin/bash "$SONAR_USER" >> "$LOGFILE" 2>&1
    VALIDATE $? "Creating user $SONAR_USER"
fi

if [ "$(id -u "$SONAR_USER")" -eq 0 ]; then
    echo "ERROR: User $SONAR_USER has UID 0. Refusing to continue."
    exit 1
fi

# ------------------------------------------------------------
# Java Environment for the sonar user (~/.bashrc)
# ------------------------------------------------------------

touch "${SONAR_HOME_DIR}/.bashrc"
sed -i '/JAVA_HOME/d' "${SONAR_HOME_DIR}/.bashrc"

cat >> "${SONAR_HOME_DIR}/.bashrc" <<EOF
export JAVA_HOME=${JAVA_HOME_PATH}
export PATH=\$JAVA_HOME/bin:\$PATH
EOF
VALIDATE $? "Configuring Java environment for $SONAR_USER"

chown "$SONAR_USER:$SONAR_GROUP" "${SONAR_HOME_DIR}/.bashrc"
VALIDATE $? "Setting .bashrc ownership"

# ------------------------------------------------------------
# Remove Old systemd Service (from earlier script versions)
# ------------------------------------------------------------

if [ -f "$OLD_SERVICE_FILE" ]; then
    systemctl stop sonarqube >> "$LOGFILE" 2>&1
    systemctl disable sonarqube >> "$LOGFILE" 2>&1
    rm -f "$OLD_SERVICE_FILE"
    systemctl daemon-reload >> "$LOGFILE" 2>&1
    VALIDATE $? "Removing old systemd service"
else
    SKIP "Old systemd service cleanup"
fi

# ------------------------------------------------------------
# Stop Any Running SonarQube Instance
# ------------------------------------------------------------

if [ -x "${SONAR_SCRIPT_DIR}/sonar.sh" ]; then
    RUN_AS_SONAR "cd ${SONAR_SCRIPT_DIR} && sh sonar.sh stop" >> "$LOGFILE" 2>&1
fi

if pgrep -u "$SONAR_USER" java >/dev/null 2>&1; then
    pkill -u "$SONAR_USER" java >> "$LOGFILE" 2>&1
    sleep 5
fi

# ------------------------------------------------------------
# Download, Verify and Extract SonarQube
# ------------------------------------------------------------

cd "$INSTALL_BASE_DIR" >> "$LOGFILE" 2>&1
VALIDATE $? "Changing to $INSTALL_BASE_DIR"

if [ -x "${SONAR_SCRIPT_DIR}/sonar.sh" ]; then
    SKIP "SonarQube download and extraction"
else
    if [ -e "$SONARQUBE_HOME" ]; then
        echo "ERROR: $SONARQUBE_HOME exists but is incomplete."
        echo "Inspect or remove it, then run this script again."
        exit 1
    fi

    rm -f "$SONARQUBE_ARCHIVE"

    wget -q --tries=3 "$SONARQUBE_URL" -O "$SONARQUBE_ARCHIVE" \
        >> "$LOGFILE" 2>&1
    VALIDATE $? "Downloading SonarQube $SONARQUBE_VERSION"

    EXPECTED_SHA=$(
        curl -fsSL "${SONARQUBE_URL}.sha256" 2>> "$LOGFILE" |
            awk '{print $1}'
    )

    if echo "$EXPECTED_SHA" | grep -Eq '^[0-9a-fA-F]{64}$'; then
        echo "${EXPECTED_SHA}  ${SONARQUBE_ARCHIVE}" |
            sha256sum -c - >> "$LOGFILE" 2>&1
        VALIDATE $? "Verifying SonarQube SHA256 checksum"
    else
        WARN "Could not retrieve SHA256 checksum. Skipping verification."
    fi

    unzip -q "$SONARQUBE_ARCHIVE" >> "$LOGFILE" 2>&1
    VALIDATE $? "Extracting SonarQube"

    mv "sonarqube-${SONARQUBE_VERSION}" "$SONARQUBE_HOME" >> "$LOGFILE" 2>&1
    VALIDATE $? "Moving SonarQube to $SONARQUBE_HOME"
fi

rm -f "${INSTALL_BASE_DIR}/${SONARQUBE_ARCHIVE}"

if [ ! -x "${SONAR_SCRIPT_DIR}/sonar.sh" ]; then
    echo "ERROR: sonar.sh not found: ${SONAR_SCRIPT_DIR}/sonar.sh"
    exit 1
fi

# ------------------------------------------------------------
# Ownership and Permissions (sonar user owns everything)
# ------------------------------------------------------------

chown -R "$SONAR_USER:$SONAR_GROUP" "$SONARQUBE_HOME" >> "$LOGFILE" 2>&1
VALIDATE $? "Setting SonarQube ownership"

chmod -R 750 "$SONARQUBE_HOME" >> "$LOGFILE" 2>&1
VALIDATE $? "Setting SonarQube permissions"

# ------------------------------------------------------------
# Firewall (only if firewalld is running)
# ------------------------------------------------------------

if command -v firewall-cmd >/dev/null 2>&1 &&
   firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${SONAR_PORT}/tcp" >> "$LOGFILE" 2>&1
    firewall-cmd --reload >> "$LOGFILE" 2>&1
    VALIDATE $? "Opening port ${SONAR_PORT} in firewalld"
else
    SKIP "firewalld configuration"
fi

# ------------------------------------------------------------
# Verify the sonar user's environment BEFORE starting
# ------------------------------------------------------------

SONAR_JAVA_VERSION=$(RUN_AS_SONAR "java -version 2>&1 | head -n 1")
SONAR_JAVA_HOME=$(RUN_AS_SONAR 'echo $JAVA_HOME')
SONAR_NOFILE=$(RUN_AS_SONAR 'ulimit -n')

echo "Java for $SONAR_USER : $SONAR_JAVA_VERSION"
echo "JAVA_HOME           : $SONAR_JAVA_HOME"
echo "Open files limit    : $SONAR_NOFILE"

if ! echo "$SONAR_JAVA_VERSION" | grep -q "\"${JAVA_VERSION}\."; then
    echo "ERROR: User $SONAR_USER is not using Java ${JAVA_VERSION}."
    exit 1
fi

if [ "$SONAR_JAVA_HOME" != "$JAVA_HOME_PATH" ]; then
    echo "ERROR: JAVA_HOME for $SONAR_USER is '$SONAR_JAVA_HOME' (expected $JAVA_HOME_PATH)."
    exit 1
fi

if [ "$SONAR_NOFILE" -lt 65536 ] 2>/dev/null; then
    WARN "Open files limit for $SONAR_USER is $SONAR_NOFILE (Elasticsearch wants 65535+)."
fi

# ------------------------------------------------------------
# Start SonarQube AS THE sonar USER
# ------------------------------------------------------------

RUN_AS_SONAR "cd ${SONAR_SCRIPT_DIR} && sh sonar.sh start" >> "$LOGFILE" 2>&1
VALIDATE $? "Starting SonarQube as user $SONAR_USER"

echo
echo "Waiting for SonarQube to become UP (up to ${STARTUP_TIMEOUT}s)..."

ELAPSED=0
SONAR_UP="false"

while [ "$ELAPSED" -lt "$STARTUP_TIMEOUT" ]
do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -n "."

    SONAR_STATE=$(RUN_AS_SONAR "cd ${SONAR_SCRIPT_DIR} && sh sonar.sh status" 2>&1)

    if ! echo "$SONAR_STATE" | grep -q "is running"; then
        echo
        echo "ERROR: SonarQube process stopped unexpectedly."
        echo "---- RAM ----"
        free -m
        echo "---- OOM killer ----"
        journalctl -k --no-pager 2>/dev/null | grep -i "out of memory\|oom" | tail -n 5
        echo "---- nohup.log ----"
        tail -n 20 "$SONARQUBE_HOME/logs/nohup.log" 2>/dev/null
        echo "---- sonar.log ----"
        tail -n 40 "$SONARQUBE_HOME/logs/sonar.log" 2>/dev/null
        echo "---- es.log ----"
        tail -n 40 "$SONARQUBE_HOME/logs/es.log" 2>/dev/null
        exit 1
    fi

    STATUS_JSON=$(curl -fs -m 5 "http://localhost:${SONAR_PORT}/api/system/status" 2>/dev/null)

    if echo "$STATUS_JSON" | grep -q '"status":"UP"'; then
        SONAR_UP="true"
        break
    fi
done

echo

if [ "$SONAR_UP" != "true" ]; then
    echo "ERROR: SonarQube did not become UP within ${STARTUP_TIMEOUT}s."
    echo "Check: tail -n 100 $SONARQUBE_HOME/logs/sonar.log"
    exit 1
fi

echo "SonarQube startup... SUCCESS"

# ------------------------------------------------------------
# Confirm it is NOT running as root
# ------------------------------------------------------------

SONAR_PROC_USER=$(ps -o user= -p "$(pgrep -u "$SONAR_USER" -f 'org.sonar.application.App' | head -n 1)" 2>/dev/null | tr -d ' ')

if [ "$SONAR_PROC_USER" = "root" ]; then
    echo "ERROR: SonarQube is running as root. This must never happen."
    exit 1
fi

# ------------------------------------------------------------
# Detect Public IP (AWS IMDSv2, optional)
# ------------------------------------------------------------

IMDS_TOKEN=$(curl -fs -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)

PUBLIC_IP=$(curl -fs -m 2 \
    -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null)

if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP="<EC2-PUBLIC-IP>"
fi

# ------------------------------------------------------------
# Installation Summary
# ------------------------------------------------------------

echo
echo "============================================================"
echo " SonarQube Installation Completed Successfully"
echo "============================================================"
echo

echo "Java Version:"
"$JAVA_HOME_PATH/bin/java" -version

echo
echo "SonarQube Version : $SONARQUBE_VERSION"
echo "SonarQube Home    : $SONARQUBE_HOME"
echo "Running As User   : ${SONAR_PROC_USER:-$SONAR_USER}"
echo "URL               : http://${PUBLIC_IP}:${SONAR_PORT}"
echo "Default Login     : admin / admin (change it on first login)"
echo "Install Log       : $LOGFILE"
echo
echo "Manage SonarQube as the sonar user:"
echo "  sudo su - $SONAR_USER"
echo "  cd $SONAR_SCRIPT_DIR"
echo "  sh sonar.sh start | stop | status"
echo "  tail -f $SONARQUBE_HOME/logs/sonar.log"
echo
echo "REMINDER: Open TCP ${SONAR_PORT} in the EC2 security group."
echo "NOTE: This uses the embedded H2 database (testing only)."
echo "      Use PostgreSQL for production."
echo "NOTE: SonarQube will NOT auto-start after a reboot."
echo "      After a reboot, start it again as the sonar user (see above)."
echo