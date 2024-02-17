#!/bin/sh
# Build an iocage jail under TrueNAS 12.3 using the current release of Caddy with Photoprism
# git clone https://github.com/tschettervictor/truenas-iocage-photoprism

# Check for root privileges
if ! [ $(id -u) = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
fi

#####
#
# General configuration
#
#####

# Initialize defaults
JAIL_IP=""
JAIL_INTERFACES=""
DEFAULT_GW_IP=""
INTERFACE="vnet0"
VNET="on"
POOL_PATH=""
DB_PATH=""
JAIL_NAME="photoprism"
HOST_NAME=""
DATABASE="mysql"
SELFSIGNED_CERT=0
STANDALONE_CERT=0
DNS_CERT=0
NO_CERT=0
CERT_EMAIL=""
CONFIG_NAME="photoprism-config"
DB_USER="photoprism"
DB_NAME="photoprism"

# Check for photoprism-config and set configuration
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
if ! [ -e "${SCRIPTPATH}"/"${CONFIG_NAME}" ]; then
  echo "${SCRIPTPATH}/${CONFIG_NAME} must exist."
  exit 1
fi
. "${SCRIPTPATH}"/"${CONFIG_NAME}"
INCLUDES_PATH="${SCRIPTPATH}"/includes

JAILS_MOUNT=$(zfs get -H -o value mountpoint $(iocage get -p)/iocage)
RELEASE=$(freebsd-version | cut -d - -f -1)"-RELEASE"
# If release is 13.1-RELEASE, change to 13.2-RELEASE
if [ "${RELEASE}" = "13.1-RELEASE" ]; then
  RELEASE="13.2-RELEASE"
fi

#####
#
# Input/Config Sanity checks
#
#####

# Check that necessary variables were set by photoprism-config
if [ -z "${JAIL_IP}" ]; then
  echo 'Configuration error: JAIL_IP must be set'
  exit 1
fi
if [ -z "${JAIL_INTERFACES}" ]; then
  echo 'JAIL_INTERFACES not set, defaulting to: vnet0:bridge0'
JAIL_INTERFACES="vnet0:bridge0"
fi
if [ -z "${DEFAULT_GW_IP}" ]; then
  echo 'Configuration error: DEFAULT_GW_IP must be set'
  exit 1
fi
if [ -z "${POOL_PATH}" ]; then
  echo 'Configuration error: POOL_PATH must be set'
  exit 1
fi
if [ -z "${HOST_NAME}" ]; then
  echo 'Configuration error: HOST_NAME must be set'
  exit 1
fi

# Check cert config
if [ $STANDALONE_CERT -eq 0 ] && [ $DNS_CERT -eq 0 ] && [ $NO_CERT -eq 0 ] && [ $SELFSIGNED_CERT -eq 0 ]; then
  echo 'Configuration error: Either STANDALONE_CERT, DNS_CERT, NO_CERT,'
  echo 'or SELFSIGNED_CERT must be set to 1.'
  exit 1
fi
if [ $STANDALONE_CERT -eq 1 ] && [ $DNS_CERT -eq 1 ] ; then
  echo 'Configuration error: Only one of STANDALONE_CERT and DNS_CERT'
  echo 'may be set to 1.'
  exit 1
fi
if [ $DNS_CERT -eq 1 ] && [ -z "${DNS_PLUGIN}" ] ; then
  echo "DNS_PLUGIN must be set to a supported DNS provider."
  echo "See https://caddyserver.com/download for available plugins."
  echo "Use only the last part of the name.  E.g., for"
  echo "\"github.com/caddy-dns/cloudflare\", enter \"coudflare\"."
  exit 1
fi
if [ $DNS_CERT -eq 1 ] && [ "${CERT_EMAIL}" = "" ] ; then
  echo "CERT_EMAIL must be set when using Let's Encrypt certs."
  exit 1
fi
if [ $STANDALONE_CERT -eq 1 ] && [ "${CERT_EMAIL}" = "" ] ; then
  echo "CERT_EMAIL must be set when using Let's Encrypt certs."
  exit 1
fi

# If DB_PATH wasn't set, set it and create directory
if [ -z "${DB_PATH}" ]; then
  DB_PATH="${POOL_PATH}"/photoprism/db
fi

# Check for reinstall
if [ "$(ls -A "${DB_PATH}")" ]; then
	echo "Existing Photoprism database detected."
 	echo "Checking compatability..."
	if [ "$(ls -A "${DB_PATH}/${DATABASE}")" ]; then
		echo "Database is compatible, continuing..."
		REINSTALL="true"
	else
		echo "ERROR: You can not reinstall without the previous database"
		echo "Please try again after removing your database files or using the same database used previously"
		exit 1
	fi
 	else echo "No existing database detected. Starting full install."
fi

ADMIN_PASSWORD=$(openssl rand -base64 12)
DB_PASSWORD=$(openssl rand -base64 16)
DB_ROOT_PASSWORD=$(openssl rand -base64 16)

if [ "${DB_PATH}" = "${POOL_PATH}" ]
then
  echo "DB_PATH must be different from POOL_PATH!"
  exit 1
fi

# Extract IP and netmask, sanity check netmask
IP=$(echo ${JAIL_IP} | cut -f1 -d/)
NETMASK=$(echo ${JAIL_IP} | cut -f2 -d/)
if [ "${NETMASK}" = "${IP}" ]
then
  NETMASK="24"
fi
if [ "${NETMASK}" -lt 8 ] || [ "${NETMASK}" -gt 30 ]
then
  NETMASK="24"
fi

#####
#
# Jail Creation
#
#####

# List packages to be auto-installed after jail creation
cat <<__EOF__ >/tmp/pkg.json
{
  "pkgs": [
  "go",
  "ffmpeg",
  "darktable",
  "rawtherapee",
  "libheif",
  "p5-Image-ExifTool",
  "mariadb106-server",
  "mariadb106-client"
  ]
}
__EOF__

# Create the jail and install previously listed packages
if ! iocage create --name "${JAIL_NAME}" -p /tmp/pkg.json -r "${RELEASE}" interfaces="${JAIL_INTERFACES}" ip4_addr="${INTERFACE}|${IP}/${NETMASK}" defaultrouter="${DEFAULT_GW_IP}" boot="on" host_hostname="${JAIL_NAME}" vnet="${VNET}"
then
	echo "Failed to create jail"
	exit 1
fi
rm /tmp/pkg.json

#####
#
# Directory Creation and Mounting
#
#####

mkdir -p "${POOL_PATH}"/photoprism/photos
mkdir -p "${DB_PATH}"/"${DATABASE}"
iocage exec "${JAIL_NAME}" mkdir -p /mnt/photos
iocage exec "${JAIL_NAME}" mkdir -p /var/db/mysql
iocage exec "${JAIL_NAME}" mkdir -p /mnt/includes
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/www
iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/rc.d
iocage fstab -a "${JAIL_NAME}" "${DB_PATH}"/"${DATABASE}" /var/db/mysql nullfs rw 0 0
iocage fstab -a "${JAIL_NAME}" "${POOL_PATH}"/photoprism/photos /mnt/photos nullfs rw 0 0
iocage fstab -a "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0

#####
#
# Database Setup
#
#####

iocage exec "${JAIL_NAME}" sysrc mysql_enable="YES"
iocage exec "${JAIL_NAME}" sysrc mysql_args="--bind-address=127.0.0.1"
iocage exec "${JAIL_NAME}" service mysql-server start
if [ "${REINSTALL}" == "true" ]; then
	echo "Reinstall detected, skipping generation of new database and credentials."
 	iocage exec "${JAIL_NAME}" cp -f /mnt/includes/my.cnf /root/.my.cnf
  	iocage exec "${JAIL_NAME}" sed -i '' "s|mypassword|${DB_ROOT_PASSWORD}|" /root/.my.cnf
else
	if ! iocage exec "${JAIL_NAME}" mysql -u root -e "CREATE DATABASE ${DB_NAME} CHARACTER SET = utf8mb4 COLLATE = utf8mb4_unicode_ci;"
		then
		echo "Failed to create MariaDB database, aborting"
    		exit 1
	fi
iocage exec "${JAIL_NAME}" mysql -u root -e "CREATE USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"
iocage exec "${JAIL_NAME}" mysql -u root -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* to '${DB_USER}'@'%';"
iocage exec "${JAIL_NAME}" mysql -u root -e "DELETE FROM mysql.user WHERE User='';"
iocage exec "${JAIL_NAME}" mysql -u root -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
iocage exec "${JAIL_NAME}" mysql -u root -e "DROP DATABASE IF EXISTS test;"
iocage exec "${JAIL_NAME}" mysql -u root -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
iocage exec "${JAIL_NAME}" mysql -u root -e "FLUSH PRIVILEGES;"
iocage exec "${JAIL_NAME}" mysqladmin --user=root password "${DB_ROOT_PASSWORD}" reload
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/my.cnf /root/.my.cnf
iocage exec "${JAIL_NAME}" sed -i '' "s|mypassword|${DB_ROOT_PASSWORD}|" /root/.my.cnf
# Save passwords for later reference
echo "${DB_NAME} root user is ${DB_USER} and password is ${DB_ROOT_PASSWORD}" > /root/${JAIL_NAME}_passwords.txt
echo "Photoprism database name is ${DB_NAME} and password is ${DB_PASSWORD}" >> /root/${JAIL_NAME}_passwords.txt
echo "Photoprism user is admin password is ${ADMIN_PASSWORD}" >> /root/${JAIL_NAME}_passwords.txt
echo "Passwords for Database and admin user have been saved in TrueNAS root directory."
fi

#####
#
# Photoprism Installation
#
#####

iocage exec "${JAIL_NAME}" "pkg add https://github.com/lapo-luchini/libtensorflow1-freebsd-port/releases/download/v1.15.5_2/libtensorflow1-1.15.5_2.pkg-FreeBSD-13.2-amd64-AVX-SSE42.pkg"
iocage exec "${JAIL_NAME}" "pkg add https://github.com/lapo-luchini/photoprism-freebsd-port/releases/download/2023-11-28/photoprism-g20231128-FreeBSD-13.2-amd64.pkg"
#iocage exec "${JAIL_NAME}" "pkg add https://github.com/psa/libtensorflow1-freebsd-port/releases/download/1.15.5/libtensorflow1-1.15.5-FreeBSD-12.2-noAVX.pkg"
#iocage exec "${JAIL_NAME}" "pkg add https://github.com/psa/libtensorflow1-freebsd-port/releases/download/1.15.5-pre-release-0/libtensorflow1-1.15.5-FreeBSD-13.0-AVX.pkg"
#iocage exec "${JAIL_NAME}" "pkg add https://github.com/Gaojianli/photoprism-freebsd-port/releases/download/2023-10-21/photoprism-g20231021-Freebsd-13.1.pkg"
#iocage exec "${JAIL_NAME}" "pkg add https://github.com/psa/photoprism-freebsd-port/releases/download/2023-07-19/photoprism-g20230719-FreeBSD-12.3-separatedTensorflow.pkg"
iocage exec "${JAIL_NAME}" sysrc photoprism_enable="YES"
iocage exec "${JAIL_NAME}" sysrc photoprism_assetspath="/var/db/photoprism/assets"
iocage exec "${JAIL_NAME}" sysrc photoprism_storagepath="/mnt/photos/"
iocage exec "${JAIL_NAME}" sysrc photoprism_defaultsyaml="/mnt/photos/options.yml"
iocage exec "${JAIL_NAME}" "touch /mnt/photos/options.yml"
if [ "${REINSTALL}" == "true" ]; then
	echo "No need to copy options.yml file on a reinstall."
else
iocage exec "${JAIL_NAME}" "cat >/mnt/photos/options.yml <<EOL
# options.yml
AdminPassword: ${ADMIN_PASSWORD}
AssetsPath: /var/db/photoprism/assets
StoragePath: /mnt/photos
OriginalsPath: /mnt/photos/originals
ImportPath: /mnt/photos/import
DatabaseDriver: mysql
DatabaseName: ${DB_NAME}
DatabaseServer: "127.0.0.1:3306"
DatabaseUser: ${DB_USER}
DatabasePassword: ${DB_PASSWORD}
EOL"
fi
iocage exec "${JAIL_NAME}" chown -R photoprism:photoprism /mnt/photos

#####
#
# Caddyserver Installation
#
#####

# Build xcaddy, use it to build Caddy
if ! iocage exec "${JAIL_NAME}" "go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest"
then
  echo "Failed to get xcaddy, terminating."
  exit 1
fi
if ! iocage exec "${JAIL_NAME}" cp /root/go/bin/xcaddy /usr/local/bin/xcaddy
then
  echo "Failed to move xcaddy to path, terminating."
  exit 1
fi
if [ ${DNS_CERT} -eq 1 ]; then
  if ! iocage exec "${JAIL_NAME}" xcaddy build --output /usr/local/bin/caddy --with github.com/caddy-dns/"${DNS_PLUGIN}"
  then
    echo "Failed to build Caddy with ${DNS_PLUGIN} plugin, terminating."
    exit 1
  fi  
else
  if ! iocage exec "${JAIL_NAME}" xcaddy build --output /usr/local/bin/caddy
  then
    echo "Failed to build Caddy without plugin, terminating."
    exit 1
  fi  
fi
# Generate and install self-signed cert, if necessary
if [ $SELFSIGNED_CERT -eq 1 ]; then
  iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/pki/tls/private
  iocage exec "${JAIL_NAME}" mkdir -p /usr/local/etc/pki/tls/certs
  openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj "/C=US/ST=Denial/L=Springfield/O=Dis/CN=${HOST_NAME}" -keyout "${INCLUDES_PATH}"/privkey.pem -out "${INCLUDES_PATH}"/fullchain.pem
  iocage exec "${JAIL_NAME}" cp /mnt/includes/privkey.pem /usr/local/etc/pki/tls/private/privkey.pem
  iocage exec "${JAIL_NAME}" cp /mnt/includes/fullchain.pem /usr/local/etc/pki/tls/certs/fullchain.pem
fi
if [ $STANDALONE_CERT -eq 1 ] || [ $DNS_CERT -eq 1 ]; then
  iocage exec "${JAIL_NAME}" cp -f /mnt/includes/remove-staging.sh /root/
fi
if [ $NO_CERT -eq 1 ]; then
  echo "Copying Caddyfile for no SSL"
  iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-nossl /usr/local/www/Caddyfile
elif [ $SELFSIGNED_CERT -eq 1 ]; then
  echo "Copying Caddyfile for self-signed cert"
  iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-selfsigned /usr/local/www/Caddyfile
elif [ $DNS_CERT -eq 1 ]; then
  echo "Copying Caddyfile for Let's Encrypt DNS cert"
  iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-dns /usr/local/www/Caddyfile
else
  echo "Copying Caddyfile for Let's Encrypt cert"
  iocage exec "${JAIL_NAME}" cp -f /mnt/includes/Caddyfile-standalone /usr/local/www/Caddyfile
fi
iocage exec "${JAIL_NAME}" cp -f /mnt/includes/caddy /usr/local/etc/rc.d/caddy
iocage exec "${JAIL_NAME}" sed -i '' "s/yourhostnamehere/${HOST_NAME}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/jail_ip/${IP}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/dns_plugin/${DNS_PLUGIN}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/api_token/${DNS_TOKEN}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sed -i '' "s/youremailhere/${CERT_EMAIL}/" /usr/local/www/Caddyfile
iocage exec "${JAIL_NAME}" sysrc caddy_enable="YES"
iocage exec "${JAIL_NAME}" sysrc caddy_config="/usr/local/www/Caddyfile"

# Don't need /mnt/includes any more, so unmount it
iocage fstab -r "${JAIL_NAME}" "${INCLUDES_PATH}" /mnt/includes nullfs rw 0 0

# Restart
iocage restart "${JAIL_NAME}"

if [ $STANDALONE_CERT -eq 1 ] || [ $DNS_CERT -eq 1 ]; then
  echo "You have obtained your Let's Encrypt certificate using the staging server."
  echo "This certificate will not be trusted by your browser and will cause SSL errors"
  echo "when you connect.  Once you've verified that everything else is working"
  echo "correctly, you should issue a trusted certificate.  To do this, run:"
  echo "  iocage exec ${JAIL_NAME} /root/remove-staging.sh"
  echo ""
elif [ $SELFSIGNED_CERT -eq 1 ]; then
  echo "You have chosen to create a self-signed TLS certificate for your"
  echo "installation.  This certificate will not be trusted by your browser and"
  echo "will cause SSL errors when you connect.  If you wish to replace this certificate"
  echo "with one obtained elsewhere, the private key is located at:"
  echo "/usr/local/etc/pki/tls/private/privkey.pem"
  echo "The full chain (server + intermediate certificates together) is at:"
  echo "/usr/local/etc/pki/tls/certs/fullchain.pem"
  echo ""
fi

echo "---------------"
echo "Installation complete!"
if [ $STANDALONE_CERT -eq 1 ] || [ $DNS_CERT -eq 1 ]; then
  echo "---------------"
  echo "You have obtained your Let's Encrypt certificate using the staging server."
  echo "This certificate will not be trusted by your browser and will cause SSL errors"
  echo "when you connect.  Once you've verified that everything else is working"
  echo "correctly, you should issue a trusted certificate.  To do this, run:"
  echo "  iocage exec ${JAIL_NAME} /root/remove-staging.sh"
  echo ""
elif [ $SELFSIGNED_CERT -eq 1 ]; then
  echo "---------------"
  echo "You have chosen to create a self-signed TLS certificate for your installation."
  echo "installation.  This certificate will not be trusted by your browser and"
  echo "will cause SSL errors when you connect.  If you wish to replace this certificate"
  echo "with one obtained elsewhere, the private key is located at:"
  echo "/usr/local/etc/pki/tls/private/privkey.pem"
  echo "The full chain (server + intermediate certificates together) is at:"
  echo "/usr/local/etc/pki/tls/certs/fullchain.pem"
  echo ""
fi
if [ $NO_CERT -eq 1 ]; then
  echo "---------------"
  echo "Using your web browser, go to http://${HOST_NAME} to log in"
else
  echo "---------------"
  echo "Using your web browser, go to https://${HOST_NAME} to log in"
fi
if [ "${REINSTALL}" == "true" ]; then
	echo "---------------"
	echo "You did a reinstall, please use your old database and account credentials."
else
	echo "---------------"
	echo "Database Information"
	echo "Database user = ${DB_USER}"
	echo "Database password = ${DB_PASSWORD}"
	echo "---------------"
 	echo "User Information"
	echo "Default user = admin"
 	echo "Devault password is ${ADMIN_PASSWORD}"
  	echo "---------------"
	echo "All passwords are saved in /root/${JAIL_NAME}_passwords.txt"
fi
