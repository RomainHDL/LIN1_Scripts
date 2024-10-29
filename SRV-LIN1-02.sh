#!/bin/bash

# 1. Configuration réseau et nom d'hôte

# Mise à jour des paquets
DEBIAN_FRONTEND=noninteractive apt-get update

# Définir le nom d'hôte
hostnamectl set-hostname SRV-LIN1-02

# Ajouter au domaine lin1.local (via /etc/hosts)
echo "127.0.0.1   SRV-LIN1-02.lin1.local SRV-LIN1-02" >> /etc/hosts

# Détecter l'interface réseau automatiquement (exclure lo - loopback)
STATIC_IF=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n 1)

# Configuration de la carte réseau avec IP statique
cat <<EOF > /etc/network/interfaces
# Configuration de l'interface réseau statique
auto $STATIC_IF
iface $STATIC_IF inet static
address 10.10.10.22/24
gateway 10.10.10.11
EOF

# Appliquer les changements de réseau
systemctl restart networking

# Configuration de resolv.conf
cat <<EOF > /etc/resolv.conf
domain lin1.local
search lin1.local
nameserver 10.10.10.11
EOF

# Vérification du bon fonctionnement
echo "Le serveur SRV-LIN1-02 a été configuré avec succès avec une IP statique et une passerelle par défaut."


# 2. Installation de Nextcloud et MariaDB

# Mise à jour du système
apt update && apt upgrade -y

# Installer unzip, Apache2 et PHP
apt install -y unzip apache2 php-ldap libapache2-mod-php php-gd php-json php-mysql php-curl php-mbstring php-intl php-imagick php-xml php-zip

# Installer MariaDB (serveur et client)
apt install -y mariadb-server mariadb-client

# Démarrer le service MariaDB
systemctl start mariadb
systemctl enable mariadb

# Créer la base de données et l'utilisateur pour Nextcloud
mysql -u root <<EOF
CREATE DATABASE nextcloud;
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextclouduser'@'localhost' IDENTIFIED BY 'password';
FLUSH PRIVILEGES;
EXIT;
EOF

# Créer le dossier Nextcloud
mkdir -p /var/www/html/nextcloud/

# Télécharger la version 30.0.1 de Nextcloud
wget https://download.nextcloud.com/server/releases/nextcloud-30.0.1.zip

# Décompresser Nextcloud dans le répertoire d'Apache
unzip nextcloud-30.0.1.zip -d /var/www/html/nextcloud/

# Changer les droits sur le répertoire Nextcloud
chown -R www-data:www-data /var/www/html/nextcloud/

# Vérification du bon fonctionnement
echo "Nextcloud 30.0.1 et ses dépendances ont été installés et configurés."


# 3. Configuration Apache pour Nextcloud

# Variables
SERVER_NAME="10.10.10.22"
CONFIG_FILE="/etc/apache2/sites-available/nextcloud.conf"

# Créer le fichier de configuration Apache pour Nextcloud
echo "<VirtualHost *:80>
    ServerAdmin admin@example.com
    DocumentRoot /var/www/html/nextcloud
    ServerName $SERVER_NAME

    <Directory /var/www/html/nextcloud/>
        Options +FollowSymlinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined

</VirtualHost>" > $CONFIG_FILE

# Activer le site Nextcloud
a2ensite nextcloud.conf

# Activer le module Apache pour la réécriture d'URL
a2enmod rewrite

# Redémarrer Apache
systemctl restart apache2

# Message de confirmation
echo "Configuration Apache pour Nextcloud créée et Apache redémarré."
