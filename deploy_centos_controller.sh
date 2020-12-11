#!/bin/sh

#
# Deploy a VPN controller
#

###############################################################################
# CONFIGURATION
###############################################################################

MACHINE_HOSTNAME=$(hostname -f)

# DNS name of the Web Server
printf "DNS name of the Web Server [%s]: " "${MACHINE_HOSTNAME}"; read -r WEB_FQDN
WEB_FQDN=${WEB_FQDN:-${MACHINE_HOSTNAME}}

VPN_STABLE_REPO=1
VPN_DEV_REPO=${VPN_DEV_REPO:-0}
if [ "${VPN_DEV_REPO}" = 1 ]
then
    VPN_STABLE_REPO=0
fi

###############################################################################
# SYSTEM
###############################################################################

# SELinux enabled?

if ! /usr/sbin/selinuxenabled
then
    echo "Please **ENABLE** SELinux before running this script!"
    exit 1
fi

PACKAGE_MANAGER=/usr/bin/yum

###############################################################################
# SOFTWARE
###############################################################################

# disable and stop existing firewalling
systemctl disable --now firewalld >/dev/null 2>/dev/null || true
systemctl disable --now iptables >/dev/null 2>/dev/null || true
systemctl disable --now ip6tables >/dev/null 2>/dev/null || true

if grep -q "Red Hat" /etc/redhat-release
then
    # RHEL
    subscription-manager repos --enable=rhel-7-server-optional-rpms
    subscription-manager repos --enable=rhel-7-server-extras-rpms
    ${PACKAGE_MANAGER} -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm
else
    # CentOS
    ${PACKAGE_MANAGER} -y install epel-release
fi

# import PGP key and add repository
rpm --import https://repo.letsconnect-vpn.org/2/rpm/RPM-GPG-KEY-LC
cat << EOF > /etc/yum.repos.d/LC-v2.repo
[LC-v2]
name=VPN Stable Packages (EL \$releasever)
baseurl=https://repo.letsconnect-vpn.org/2/rpm/epel-7-\$basearch
gpgcheck=1
enabled=${VPN_STABLE_REPO}
EOF

cat << EOF > /etc/yum.repos.d/LC-master.repo
[LC-master]
name=VPN Development Packages (EL \$releasever)
baseurl=https://vpn-builder.tuxed.net/repo/master/epel-7-\$basearch
gpgcheck=1
gpgkey=https://vpn-builder.tuxed.net/repo/master/RPM-GPG-KEY-LC
enabled=${VPN_DEV_REPO}
EOF

# install software (dependencies)
${PACKAGE_MANAGER} -y install mod_ssl php-opcache httpd iptables pwgen \
    iptables-services php-fpm php-cli policycoreutils-python chrony

# install software (VPN packages)
${PACKAGE_MANAGER} -y install vpn-server-api vpn-user-portal vpn-maint-scripts

###############################################################################
# SELINUX
###############################################################################

# allow Apache to connect to PHP-FPM
setsebool -P httpd_can_network_connect=1

###############################################################################
# APACHE
###############################################################################

# Use a hardened ssl.conf instead of the default, gives A+ on
# https://www.ssllabs.com/ssltest/
cp resources/ssl.conf /etc/httpd/conf.d/ssl.conf
cp resources/localhost.centos.conf /etc/httpd/conf.d/localhost.conf

# Switch to MPM event (https://httpd.apache.org/docs/2.4/mod/event.html)
sed -i "s|^LoadModule mpm_prefork_module modules/mod_mpm_prefork.so$|#LoadModule mpm_prefork_module modules/mod_mpm_prefork.so|" /etc/httpd/conf.modules.d/00-mpm.conf
sed -i "s|^#LoadModule mpm_event_module modules/mod_mpm_event.so$|LoadModule mpm_event_module modules/mod_mpm_event.so|" /etc/httpd/conf.modules.d/00-mpm.conf

# php-fpm configuration (taken from Fedora php-fpm package, only required on
# CentOS)
cp resources/php.conf /etc/httpd/conf.d/php.conf

# VirtualHost
cp resources/vpn.example.centos.conf "/etc/httpd/conf.d/${WEB_FQDN}.conf"
sed -i "s/vpn.example/${WEB_FQDN}/" "/etc/httpd/conf.d/${WEB_FQDN}.conf"

###############################################################################
# PHP
###############################################################################

# switch to unix socket and secure it, the default in newer PHP versions, but 
# not on CentOS 7
sed -i "s|^listen = 127.0.0.1:9000$|listen = /run/php-fpm/www.sock|" /etc/php-fpm.d/www.conf
sed -i "s|;listen.mode = 0666|listen.mode = 0660|" /etc/php-fpm.d/www.conf
sed -i "s|;listen.group = nobody|listen.group = apache|" /etc/php-fpm.d/www.conf

# set timezone to UTC
cp resources/70-timezone.ini /etc/php.d/70-timezone.ini

# work around to create the session directory, otherwise we have to install
# the PHP package, this is only on CentOS
mkdir -p /var/lib/php/session
chown -R root.apache /var/lib/php/session
chmod 0770 /var/lib/php/session
restorecon -R /var/lib/php/session

###############################################################################
# VPN-SERVER-API
###############################################################################

# update hostname of VPN server
sed -i "s/vpn.example/${WEB_FQDN}/" "/etc/vpn-server-api/config.php"

# update the default IP ranges
sed -i "s|10.0.0.0/25|$(vpn-server-api-suggest-ip -4)|" "/etc/vpn-server-api/config.php"
sed -i "s|fd00:4242:4242:4242::/64|$(vpn-server-api-suggest-ip -6)|" "/etc/vpn-server-api/config.php"

# initialize the CA
sudo -u apache vpn-server-api-init

###############################################################################
# VPN-USER-PORTAL
###############################################################################

# DB init
sudo -u apache vpn-user-portal-init

###############################################################################
# UPDATE SECRETS
###############################################################################

# update internal API secrets from the defaults to something secure
SECRET_PORTAL_API=$(pwgen -s 32 -n 1)
SECRET_NODE_API=$(pwgen -s 32 -n 1)
sed -i "s|XXX-vpn-user-portal/vpn-server-api-XXX|${SECRET_PORTAL_API}|" "/etc/vpn-user-portal/config.php"
sed -i "s|XXX-vpn-user-portal/vpn-server-api-XXX|${SECRET_PORTAL_API}|" "/etc/vpn-server-api/config.php"
sed -i "s|XXX-vpn-server-node/vpn-server-api-XXX|${SECRET_NODE_API}|" "/etc/vpn-server-api/config.php"

###############################################################################
# CERTIFICATE
###############################################################################

# generate self signed certificate and key
openssl req \
    -nodes \
    -subj "/CN=${WEB_FQDN}" \
    -x509 \
    -sha256 \
    -newkey rsa:2048 \
    -keyout "/etc/pki/tls/private/${WEB_FQDN}.key" \
    -out "/etc/pki/tls/certs/${WEB_FQDN}.crt" \
    -days 90

###############################################################################
# DAEMONS
###############################################################################

systemctl enable --now php-fpm
systemctl enable --now httpd

###############################################################################
# FIREWALL
###############################################################################

# install (modified) default firewall to also allow HTTP and HTTPS
cp resources/firewall/controller/iptables /etc/sysconfig/iptables
cp resources/firewall/controller/ip6tables /etc/sysconfig/ip6tables

systemctl enable --now iptables
systemctl enable --now ip6tables

###############################################################################
# USERS
###############################################################################

REGULAR_USER="demo"
REGULAR_USER_PASS=$(pwgen 12 -n 1)

# the "admin" user is a special user, listed by ID to have access to "admin" 
# functionality in /etc/vpn-user-portal/config.php (adminUserIdList)

ADMIN_USER="admin"
ADMIN_USER_PASS=$(pwgen 12 -n 1)

sudo -u apache vpn-user-portal-add-user --user "${REGULAR_USER}" --pass "${REGULAR_USER_PASS}"
sudo -u apache vpn-user-portal-add-user --user "${ADMIN_USER}" --pass "${ADMIN_USER_PASS}"

###############################################################################
# SHOW INFO
###############################################################################

echo "########################################################################"
echo "# Portal"
echo "#     https://${WEB_FQDN}/"
echo "#         Regular User: ${REGULAR_USER}"
echo "#         Regular User Pass: ${REGULAR_USER_PASS}"
echo "#"
echo "#         Admin User: ${ADMIN_USER}"
echo "#         Admin User Pass: ${ADMIN_USER_PASS}"
echo "########################################################################"
