#!/bin/bash

# setup_email.sh - Script de instalación
# Uso: sudo ./setup_email.sh

set -e

echo "[INFO] Paso 0: Verificar interfaces y hostname"
ip a | grep -E "enp0s3|enp0s8"
hostname

echo "[INFO] Paso 1: Instalar paquetes esenciales"
apt update
apt install -y \
  isc-dhcp-server bind9 bind9-utils postfix bsd-mailx \
  dovecot-pop3d dovecot-imapd mysql-server roundcube roundcube-mysql apache2

# Variables
NETWORK="10.10.10.0/24"
SERVER_IP="10.10.10.1"
DOMAIN="midominio.local"
INT_IF="enp0s8"
EXT_IF="enp0s3"
ZONE_DIR="/etc/bind/zonas"

echo "[INFO] Paso 2: Configurar Netplan"
cat > /etc/netplan/00-installer-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INT_IF}:
      addresses: ["${SERVER_IP}/${NETWORK#*/}"]
    ${EXT_IF}:
      dhcp4: true
EOF
netplan apply

echo "[INFO] Paso 3: Configurar DHCP (/etc/dhcp/dhcpd.conf y /etc/default)"
cat >> /etc/dhcp/dhcpd.conf <<EOF

# Grupo midominio generado por script
group midominio {
  subnet ${NETWORK%/*} netmask 255.255.255.0 {
    range 10.10.10.10 10.10.10.200;
    option domain-name-servers ${SERVER_IP};
    option domain-name "${DOMAIN}";
    option subnet-mask 255.255.255.0;
    option routers ${SERVER_IP};
    option broadcast-address 10.10.10.255;
    authoritative;
  }
}
EOF

# Validar sintaxis DHCP
dhcpd -t -cf /etc/dhcp/dhcpd.conf

# Interfaz para DHCP
sed -i "/INTERFACESv4=/c\INTERFACESv4=\"${INT_IF}\"" /etc/default/isc-dhcp-server
systemctl restart isc-dhcp-server

echo "[INFO] Paso 4: Configurar DNS (BIND9)"
# Firewall
if ufw status | grep -q active; then
  ufw allow Bind9
fi

# named.conf.options
cat > /etc/bind/named.conf.options <<EOF
options {
  directory "/var/cache/bind";
  listen-on { any; };
  allow-query { localhost; 10.10.10.0/24; };
  forwarders { 8.8.8.8; };
  dnssec-validation no;
  listen-on-v6 { none; };
};
EOF

# Forzar IPv4 en named
sed -i "/^OPTIONS=/c\OPTIONS=\"-u bind -4\"" /etc/default/named
named-checkconf
systemctl restart bind9

echo "[INFO] Paso 5: Habilitar IP forwarding y NAT"
# sysctl
sed -i "/^#*net.ipv4.ip_forward/c\net.ipv4.ip_forward = 1" /etc/sysctl.d/99-sysctl.conf
sysctl --system
# iptables NAT
iptables -t nat -A POSTROUTING -s ${NETWORK%/*} -o ${EXT_IF} -j MASQUERADE

echo "[INFO] Paso 6: Añadir zonas a named.conf.local"
cat >> /etc/bind/named.conf.local <<EOF

zone "${DOMAIN}" IN {
  type master;
  file "${ZONE_DIR}/db.${DOMAIN}";
};
zone "${NETWORK%%.*}.10.in-addr.arpa" IN {
  type master;
  file "${ZONE_DIR}/db.${NETWORK%%.*}";
};
EOF
mkdir -p ${ZONE_DIR}

# Copiar plantillas y configurar zona directa
cp /etc/bind/db.local ${ZONE_DIR}/db.${DOMAIN}
sed -i "/IN SOA/,/;/c\; Zona directa ${DOMAIN}\n\$TTL 604800\n@ IN SOA server.${DOMAIN}. root.${DOMAIN}. (2 604800 86400 2419200 604800)\n@ IN NS server.${DOMAIN}.\nserver IN A ${SERVER_IP}\n" ${ZONE_DIR}/db.${DOMAIN}

# Copiar plantilla inversa
cp ${ZONE_DIR}/db.${DOMAIN} ${ZONE_DIR}/db.${NETWORK%%.*}
sed -i "/IN SOA/,/;/c\; Zona inversa ${NETWORK%/*}\n\$TTL 604800\n@ IN SOA server.${DOMAIN}. root.${DOMAIN}. (2 604800 86400 2419200 604800)\n@ IN NS server.${DOMAIN}.\n1 IN PTR server.${DOMAIN}." ${ZONE_DIR}/db.${NETWORK%%.*}

# Validar zonas
named-checkzone ${DOMAIN} ${ZONE_DIR}/db.${DOMAIN}
named-checkzone ${NETWORK%%.*}.10.in-addr.arpa ${ZONE_DIR}/db.${NETWORK%%.*}
systemctl restart bind9

echo "[INFO] Paso 7: Configurar Postfix"
# Postfix main.cf
postconf -e "mynetworks = 127.0.0.0/8, [::1]/128, 10.10.10.0/24"
postconf -e "myhostname = ${DOMAIN}"
echo "home_mailbox = Maildir/" >> /etc/postfix/main.cf
systemctl restart postfix

echo "[INFO] Paso 8: Crear usuarios de prueba"
adduser --disabled-password --gecos "" david && echo "david:123456" | chpasswd
adduser --disabled-password --gecos "" profecristian && echo "profecristian:123456" | chpasswd

echo "[INFO] Paso 9: Configurar Dovecot POP3"
sed -i "s/^#disable_plaintext_auth.*/disable_plaintext_auth = no/" /etc/dovecot/conf.d/10-auth.conf
sed -i "s/^#mail_location.*/mail_location = maildir:\~\/Maildir/" /etc/dovecot/conf.d/10-mail.conf
systemctl restart dovecot

echo "[INFO] Paso 10: Configurar IMAP/Wordpress Webmail Roundcube"
cp /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-available/round.conf
sed -i "s|ServerName .*|ServerName mail.${DOMAIN}|" /etc/apache2/sites-available/round.conf
sed -i "s|DocumentRoot .*|DocumentRoot /var/lib/roundcube|" /etc/apache2/sites-available/round.conf
cat >> /etc/apache2/sites-available/round.conf <<EOF
<Directory /var/lib/roundcube>
  Require all granted
</Directory>
EOF
a2ensite round.conf
systemctl reload apache2

echo "[INFO] Configuración completa. Verificación final de servicios:"
for svc in isc-dhcp-server bind9 postfix dovecot apache2 mysql; do
  echo -n "$svc: " && systemctl is-active $svc
done

echo "[SUCCESS] PoC lista."
