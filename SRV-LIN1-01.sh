#!/bin/bash

# Définir le nom d'hôte
hostnamectl set-hostname SRV-LIN1-01

# Ajouter au domaine lin1.local (via /etc/hosts)
echo "127.0.0.1   SRV-LIN1-01.lin1.local SRV-LIN1-01" >> /etc/hosts

# Détection automatique de l'interface avec accès à Internet (en testant un ping)
INTERNET_IF=$(ip route get 8.8.8.8 | grep -oP '(?<=dev )\S+')

# Détection de la deuxième interface (celle qui n'est pas utilisée pour Internet)
ALL_IFS=$(ls /sys/class/net | grep -v lo)  # Lister toutes les interfaces sauf lo (loopback)
for iface in $ALL_IFS; do
  if [ "$iface" != "$INTERNET_IF" ]; then
    STATIC_IF=$iface
  fi
done

# Vérifier si une interface Internet et une interface statique ont été trouvées
if [ -n "$INTERNET_IF" ] && [ -n "$STATIC_IF" ]; then
  # Configuration des interfaces réseau dans /etc/network/interfaces
  cat <<EOF > /etc/network/interfaces
# Fichier de configuration des interfaces réseau

# Interface $INTERNET_IF INTERNET
auto $INTERNET_IF
iface $INTERNET_IF inet dhcp

# Interface $STATIC_IF LOCAL HOST ONLY
auto $STATIC_IF
iface $STATIC_IF inet static
address 10.10.10.11/24
EOF
else
  echo "Impossible de trouver une interface réseau correcte."
  exit 1
fi

# Installer iptables-persistent pour gérer les règles iptables au démarrage
DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent

# Activer le routage IP en modifiant le fichier sysctl.conf
sed -i '/^#net.ipv4.ip_forward=1/c\net.ipv4.ip_forward=1' /etc/sysctl.conf

# Appliquer les changements immédiatement
sysctl -p

# Configurer les règles NAT pour que le réseau local puisse accéder à Internet via l'interface Internet
iptables -t nat -A POSTROUTING -o $INTERNET_IF -j MASQUERADE

# Sauvegarder les règles iptables pour qu'elles persistent après redémarrage
netfilter-persistent save

# Appliquer les changements de réseau
systemctl restart networking

# Installer dnsmasq
apt update
DEBIAN_FRONTEND=noninteractive apt install -y dnsmasq

# Configuration de dnsmasq dans /etc/dnsmasq.conf
cat <<EOF > /etc/dnsmasq.conf
interface=$STATIC_IF

# Associe les noms de domaine locaux aux adresses IP
address=/srv-lin1-01.lin1.local/10.10.10.11
address=/srv-lin1-02.lin1.local/10.10.10.22
address=/nas-lin1-01.lin1.local/10.10.10.33

# Enregistrements PTR pour la résolution inverse
ptr-record=11.10.10.10.in-addr.arpa., "srv-lin1-01"
ptr-record=22.10.10.10.in-addr.arpa., "srv-lin1-02"
ptr-record=33.10.10.10.in-addr.arpa., "nas-lin1-01"

# Configuration d'un serveur DNS (local DNS)
server=192.168.1.254

dhcp-range=10.10.10.110,10.10.10.119,12h
dhcp-option=option:router,10.10.10.11
dhcp-option=option:dns-server,10.10.10.11
dhcp-option=option:domain-name,"lin1.local"
dhcp-option=option:netmask,255.255.255.0
EOF

# Configuration de /etc/resolv.conf
cat <<EOF > /etc/resolv.conf
domain lin1.local
search lin1.local
nameserver 10.10.10.11
EOF

# Écrire le contenu correct dans /etc/dhcp/dhclient.conf
cat <<EOF > /etc/dhcp/dhclient.conf
option rfc3442-classless-static-routes code 121 = array of unsigned integer 8;

send host-name = gethostname();
request subnet-mask, broadcast-address, time-offset, routers,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn, dhcp6.sntp-servers,
        netbios-name-servers, netbios-scope, interface-mtu,
        rfc3442-classless-static-routes, ntp-servers;
EOF

# Redémarrer le service dnsmasq pour appliquer les modifications
systemctl restart dnsmasq

# Vérification du bon fonctionnement de dnsmasq
if systemctl is-active --quiet dnsmasq; then
  echo "Le service dnsmasq a été configuré avec succès."
else
  echo "Erreur : le service dnsmasq ne fonctionne pas."
  exit 1
fi

# Installation des services LDAP et LDAP Account Manager
DEBIAN_FRONTEND=noninteractive apt-get install -y slapd ldap-utils apache2 php libapache2-mod-php php-ldap php-mbstring ldap-account-manager

# Reconfiguration automatique de slapd
echo "slapd slapd/internal/adminpw password Pa$$w0rd" | debconf-set-selections
echo "slapd slapd/internal/generated_adminpw password Pa$$w0rd" | debconf-set-selections
echo "slapd slapd/password2 password Pa$$w0rd" | debconf-set-selections
echo "slapd slapd/password1 password Pa$$w0rd" | debconf-set-selections
echo "slapd slapd/domain string lin1.local" | debconf-set-selections
echo "slapd shared/organization string LIN1" | debconf-set-selections
echo "slapd slapd/no_configuration boolean false" | debconf-set-selections
dpkg-reconfigure -f noninteractive slapd

# Générer le hash du mot de passe 'Pa$$w0rd' avec slappasswd
HASHED_PASSWD=$(slappasswd -s 'Pa$$w0rd')

# Création du dossier ./ContentLDAP
mkdir -p ./ContentLDAP

# Fichier LDIF pour les Unités Organisationnelles (OU)
cat <<EOF > ./ContentLDAP/ou.ldif
dn: ou=People,dc=lin1,dc=local
objectClass: organizationalUnit
ou: People

dn: ou=Groups,dc=lin1,dc=local
objectClass: organizationalUnit
ou: Groups
EOF

# Fichier LDIF pour les Groupes
cat <<EOF > ./ContentLDAP/groups.ldif
dn: cn=Manager,ou=Groups,dc=lin1,dc=local
objectClass: posixGroup
cn: Manager
gidNumber: 5000

dn: cn=Ingenieur,ou=Groups,dc=lin1,dc=local
objectClass: posixGroup
cn: Ingenieur
gidNumber: 5001

dn: cn=Developpeur,ou=Groups,dc=lin1,dc=local
objectClass: posixGroup
cn: Developpeur
gidNumber: 5002
EOF

# Fichier LDIF pour les Utilisateurs
cat <<EOF > ./ContentLDAP/users.ldif
dn: uid=Man1,ou=People,dc=lin1,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: Man1
sn: Man1
cn: Man1
userPassword: $HASHED_PASSWD
gidNumber: 5000
uidNumber: 1000
homeDirectory: /home/man1
loginShell: /bin/bash

dn: uid=Man2,ou=People,dc=lin1,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: Man2
sn: Man2
cn: Man2
userPassword: $HASHED_PASSWD
gidNumber: 5000
uidNumber: 1001
homeDirectory: /home/man2
loginShell: /bin/bash

dn: uid=Ing1,ou=People,dc=lin1,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: Ing1
sn: Ing1
cn: Ing1
userPassword: $HASHED_PASSWD
gidNumber: 5001
uidNumber: 1002
homeDirectory: /home/ing1
loginShell: /bin/bash

dn: uid=Ing2,ou=People,dc=lin1,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: Ing2
sn: Ing2
cn: Ing2
userPassword: $HASHED_PASSWD
gidNumber: 5001
uidNumber: 1003
homeDirectory: /home/ing2
loginShell: /bin/bash

dn: uid=Dev1,ou=People,dc=lin1,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: Dev1
sn: Dev1
cn: Dev1
userPassword: $HASHED_PASSWD
gidNumber: 5002
uidNumber: 1004
homeDirectory: /home/dev1
loginShell: /bin/bash
EOF

# Importer les fichiers LDIF dans LDAP
ldapadd -x -D "cn=admin,dc=lin1,dc=local" -w Pa$$w0rd -f ./ContentLDAP/ou.ldif
ldapadd -x -D "cn=admin,dc=lin1,dc=local" -w Pa$$w0rd -f ./ContentLDAP/groups.ldif
ldapadd -x -D "cn=admin,dc=lin1,dc=local" -w Pa$$w0rd -f ./ContentLDAP/users.ldif

# Nettoyage
rm -rf ./ContentLDAP

# Afficher un message de confirmation
echo "Configuration du serveur terminée avec succès."
