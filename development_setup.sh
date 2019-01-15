#!/bin/sh

BASE_DIR=${HOME}/Projects/eduVPN

mkdir -p "${BASE_DIR}"
cd "${BASE_DIR}" || exit

# clone all repositories
git clone https://github.com/eduvpn/vpn-server-api.git
git clone https://github.com/eduvpn/vpn-user-portal.git
git clone https://github.com/eduvpn/vpn-server-node.git
git clone https://github.com/eduvpn/vpn-lib-common.git

# vpn-server-api
cd "${BASE_DIR}/vpn-server-api" || exit
composer update
mkdir config
cp config/config.php.example config/config.php
mkdir -p data
php bin/init.php

# vpn-user-portal
cd "${BASE_DIR}/vpn-user-portal" || exit
composer update
mkdir config
cp config/config.php.example config/config.php
mkdir -p data
php bin/init.php
php bin/add-user.php --user foo --pass bar
# XXX the secureCookie option is not there anymore in the default config 
# template, deal with this differently!
sed -i "s/'secureCookie' => true/'secureCookie' => false/" config/config.php
sed -i "s|'apiUri' => 'http://localhost/vpn-server-api/api.php'|'apiUri' => 'http://localhost:8008/api.php'|" config/config.php

# vpn-server-node
cd "${BASE_DIR}/vpn-server-node" || exit
composer update
mkdir config
cp config/config.php.example config/config.php
cp config/firewall.php.example config/firewall.php
mkdir -p data
mkdir openvpn-config
sed -i "s|'apiUri' => 'http://localhost/vpn-server-api/api.php'|'apiUri' => 'http://localhost:8008/api.php'|" config/config.php

# launch script
cat << 'EOF' | tee "${BASE_DIR}/launch.sh" > /dev/null
#!/bin/sh
(
    cd vpn-server-api || exit
    php -S localhost:8008 -t web &
)

(
    cd vpn-user-portal || exit
    php -S localhost:8082 -t web &
)
EOF
chmod +x "${BASE_DIR}/launch.sh"
