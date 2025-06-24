#!/bin/bash

# setup_email.sh - Instala y configura ISC DHCP, BIND9, MySQL, Postfix, mailx, Dovecot (POP3/IMAP) y Roundcube (webmail) en Ubuntu Server
# Uso: sudo ./setup_email.sh

set -e
echo "[INFO] Iniciando configuración del servidor..."

# Interfaces
EXT_IF="enp0s3"  # interfaz hacia Internet (no modificar)
INT_IF="enp0s8"  # interfaz hacia la LAN interna

# Variables de red y dominio
domain="midominio.local"
network="10.160.0.0"
netmask="255.255.255.0"
server_ip="10.160.0.1"
gateway="10.160.0.1"
dns_ip="$server_ip"
zone_dir="/etc/bind/zones"
zone_file="db.${domain}"
reverse_zone="160.10.in-addr.arpa"
range_start="10.160.0.10"
range_end="10.160.0.200"

# 1) Configurar IP estática en INT_IF
echo "[INFO] Configurando IP estática ${server_ip}/24 en ${INT_IF}..."
ip addr flush dev ${INT_IF}
ip addr add ${server_ip}/24 dev ${INT_IF}

# 2) Instalar paquetes esenciales
echo "[INFO] Instalando paquetes: ISC DHCP, BIND9, MySQL, Postfix, mailx, Dovecot, Roundcube y Apache2..."
DEBIAN_FRONTEND=noninteractive apt install -y \
  isc-dhcp-server bind9 mysql-server postfix mailutils \
  dovecot-core dovecot-imapd dovecot-pop3d roundcube roundcube-mysql apache2

# 3) Configurar ISC DHCP para escuchar en INT_IF
echo "[INFO] Configurando Netplan..."
cat > /etc/netplan/00-installer-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${auto_int}:
      addresses: ["${server_ip}${netmask_cidr}"]
    ${auto_ext}:
      dhcp4: true
EOF
netplan apply

echo "[INFO] Estableciendo interfaz de DHCP en ${INT_IF}..."
cat > /etc/default/isc-dhcp-server <<EOF
INTERFACESv4="${INT_IF}"
EOF

# 4) Configurar DHCP
echo "[INFO] Generando /etc/dhcp/dhcpd.conf..."
cat > /etc/dhcp/dhcpd.conf <<EOF
option domain-name "${domain}";
option domain-name-servers ${dns_ip};

default-lease-time 600;
max-lease-time 7200;

authoritative;

subnet ${network} netmask ${netmask} {
  range ${range_start} ${range_end};
  option routers ${gateway};
  option broadcast-address 10.160.0.255;
}
EOF

# 5) Configurar BIND9
echo "[INFO] Configurando BIND9..."
cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";
    listen-on port 53 { 127.0.0.1; ${server_ip}; };
    allow-query { any; };
    recursion no;
    dnssec-validation auto;
    auth-nxdomain no;
};
EOF
mkdir -p ${zone_dir}
cat > /etc/bind/named.conf.local <<EOF
zone "${domain}" {
  type master;
  file "${zone_dir}/${zone_file}";
};
zone "${reverse_zone}" {
  type master;
  file "${zone_dir}/db.${reverse_zone}";
};
EOF

# 6) Zonas DNS (directa e inversa)
echo "[INFO] Creando archivos de zona DNS..."
cat > ${zone_dir}/${zone_file} <<EOF
\$TTL 604800
@ IN SOA ns1.${domain}. admin.${domain}. (
    6 ; Serial
    604800 ; Refresh
    86400 ; Retry
    2419200 ; Expire
    604800 ) ; Negative Cache TTL
;
@ IN NS ns1.${domain}.
ns1 IN A ${dns_ip}
mail IN A 10.160.0.20
smtp IN CNAME mail.${domain}.
pop3 IN CNAME mail.${domain}.
@ IN MX 10 mail.${domain}.
EOF

cat > ${zone_dir}/db.${reverse_zone} <<EOF
\$TTL 604800
@ IN SOA ns1.${domain}. admin.${domain}. (
    6 ; Serial
    604800 ; Refresh
    86400 ; Retry
    2419200 ; Expire
    604800 ) ; Negative Cache TTL
;
@ IN NS ns1.${domain}.
20 IN PTR mail.${domain}.
EOF

# 7) Configurar Postfix básico
echo "[INFO] Configurando Postfix..."
postconf -e "myhostname = mail.${domain}"
postconf -e "mydomain = ${domain}"
echo "${domain}" > /etc/mailname
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4"
postconf -e "mydestination = localhost, ${domain}, mail.${domain}"
postconf -e "relayhost ="
postconf -e "mynetworks = 127.0.0.0/8, ${network}/24"
postconf -e "home_mailbox = Maildir/"

# 8) mailx configuration
echo "set smtp=smtp://${server_ip}" >> /etc/mail.rc
echo "set from=mail@${domain}" >> /etc/mail.rc
echo "set ssl-verify=ignore" >> /etc/mail.rc

# 9) Configurar Dovecot POP3/IMAP
echo "[INFO] Configurando Dovecot POP3 e IMAP..."
sed -i 's/^#protocols =.*/protocols = pop3 imap lmtp/' /etc/dovecot/dovecot.conf
sed -i 's|^#mail_location =.*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf

cat >> /etc/dovecot/conf.d/10-master.conf <<'EOF'
# POP3 listener
service pop3-login {
  inet_listener pop3 {
    port = 110
  }
}
# IMAP listener
service imap-login {
  inet_listener imap {
    port = 143
  }
}
EOF

# 10) Roundcube Webmail
echo "[INFO] Configurando Roundcube webmail..."
cp /etc/apache2/sites-available/000-default.conf /etc/apache2/sites-available/round.conf
sed -i "s|ServerName .*|ServerName webmail.${domain}|" /etc/apache2/sites-available/round.conf || echo "ServerName webmail.${domain}" >> /etc/apache2/sites-available/round.conf
sed -i "s|DocumentRoot .*|DocumentRoot /var/lib/roundcube|" /etc/apache2/sites-available/round.conf
cat >> /etc/apache2/sites-available/round.conf <<EOF
<Directory /var/lib/roundcube>
    Require all granted
</Directory>
EOF
ln -sf /etc/apache2/sites-available/round.conf /etc/apache2/sites-enabled/round.conf

# 11) Crear usuarios de prueba
echo "[INFO] Creando usuarios de prueba..."
for user in profehermoso david; do
  if ! id $user >/dev/null 2>&1; then
    useradd -m -s /bin/bash $user
    echo "$user:123456" | chpasswd
    runuser -l $user -c "mkdir -p ~/Maildir/{cur,new,tmp}"
  fi
done

# 12) Reiniciar servicios
echo "[INFO] Reiniciando servicios: DHCP, DNS, MySQL, Postfix, Dovecot, Apache..."
systemctl restart isc-dhcp-server bind9 mysql postfix dovecot apache2

# 13) Verificación
echo "[INFO] Estado de servicios:"
systemctl is-active isc-dhcp-server bind9 mysql postfix dovecot apache2

if systemctl is-active isc-dhcp-server >/dev/null && \
  systemctl is-active bind9 >/dev/null && \
  systemctl is-active mysql >/dev/null && \
  systemctl is-active postfix >/dev/null && \
  systemctl is-active dovecot >/dev/null && \
  systemctl is-active apache2 >/dev/null; then
  echo "[SUCCESS] Todos los servicios están activos."
else
  echo "[ERROR] Revisa el estado de los servicios." >&2
fi
