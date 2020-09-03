#!/bin/bash

# This script will install everything required to run a erxes and its related apps.
# This should be run on a clean Ubuntu 18.04 server.
#
# First, you will be asked to provide a domain name you are going to use for erxes.
# 
# Once the installation has completed you will be able to access the erxes.
# 
# * we expect you have configured your domain DNS settings already as per the instructions.

ERXES_VERSION=0.19.0
ERXES_API_VERSION=0.19.1
ERXES_INTEGRATIONS_VERSION=0.19.0

NODE_VERSION=v12.16.3

#
# Ask a domain name
#

echo "You need to configure erxes to work with your domain name. If you are using a subdomain, please use the entire subdomain. For example, 'erxes.examples.com'."

while true; do

    read -p "Please enter a domain name you wish to use: " erxes_domain

    if [ -z "$erxes_domain" ]; then
        continue
    else
        break
    fi
done

# install curl for telemetry
apt-get -qqy install -y curl 

# Dependencies

echo "Installing Initial Dependencies"

apt-get -qqy update
apt-get -qqy install -y wget gnupg apt-transport-https software-properties-common python3-pip ufw

# MongoDB
echo "Installing MongoDB"
# MongoDB version 3.6+
# Latest MongoDB version https://www.mongodb.org/static/pgp/ 
# https://docs.mongodb.com/manual/tutorial/install-mongodb-on-ubuntu/
wget -qO - https://www.mongodb.org/static/pgp/server-4.2.asc | apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu bionic/mongodb-org/4.2 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-4.2.list
apt-get -qqy update
apt-get install -y mongodb-org
echo "Installed MongoDB 4.2 successfully"
echo "Enabling and starting MongoDB..."
systemctl enable mongod
systemctl start mongod
echo "MongoDB enabled and started successfully"

# Nginx
echo "Installing Nginx"
apt-get -qqy install -y nginx
echo "Installed Nginx successfully"

## setting up ufw firewall
echo 'y' | ufw enable
ufw allow 22
ufw allow 80
ufw allow 443

# install certbot
echo "Installing Certbot"
add-apt-repository universe -y
add-apt-repository ppa:certbot/certbot -y
apt-get -qqy update
apt-get -qqy install certbot python3-certbot-nginx
echo "Installed Certbot successfully"

# username that erxes will be installed in
echo "Creating a new user called 'erxes' for you to use with your server."
username=erxes

# create a new user erxes if it does not exist
id -u erxes &>/dev/null || useradd -m -s /bin/bash -U -G sudo $username

# erxes directory
erxes_root_dir=/home/$username/erxes.io

su $username -c "mkdir -p $erxes_root_dir"
cd $erxes_root_dir

# erxes repo
erxes_ui_dir=$erxes_root_dir/ui/build
erxes_widgets_dir=$erxes_root_dir/widgets

# erxes-api repo
erxes_backends_dir=$erxes_root_dir/backends
erxes_api_dir=$erxes_backends_dir/api
erxes_engages_dir=$erxes_backends_dir/engages-email-sender
erxes_logger_dir=$erxes_backends_dir/logger

# erxes-integrations repo
erxes_integrations_dir=$erxes_root_dir/integrations

su $username -c "mkdir -p $erxes_backends_dir"

# download erxes ui
su $username -c "curl -L https://github.com/battulgadavaajamts/erxes/releases/download/$ERXES_VERSION/erxes-$ERXES_VERSION.tar.gz | tar -xz -C $erxes_root_dir"

# download erxes-api
su $username -c "curl -L https://github.com/battulgadavaajamts/erxes-api/releases/download/$ERXES_API_VERSION/erxes-api-$ERXES_API_VERSION.tar.gz | tar -xz -C $erxes_backends_dir"

# download integrations
su $username -c "curl -L https://github.com/battulgadavaajamts/erxes-integrations/releases/download/$ERXES_INTEGRATIONS_VERSION/erxes-integrations-$ERXES_INTEGRATIONS_VERSION.tar.gz | tar -xz -C $erxes_root_dir"

JWT_TOKEN_SECRET=$(openssl rand -base64 24)
MONGO_PASS=$(openssl rand -hex 16)

API_MONGO_URL="mongodb://erxes:$MONGO_PASS@localhost/erxes?authSource=admin&replicaSet=rs0"
ENGAGES_MONGO_URL="mongodb://erxes:$MONGO_PASS@localhost/erxes-engages?authSource=admin&replicaSet=rs0"
LOGGER_MONGO_URL="mongodb://erxes:$MONGO_PASS@localhost/erxes_logs?authSource=admin&replicaSet=rs0"
INTEGRATIONS_MONGO_URL="mongodb://erxes:$MONGO_PASS@localhost/erxes_integrations?authSource=admin&replicaSet=rs0"

# create an ecosystem.config.js in $erxes_root_dir directory and change owner and permission
cat > $erxes_root_dir/ecosystem.config.js << EOF
module.exports = {
  apps: [
    {
      name: "erxes-api",
      script: "dist",
      cwd: "$erxes_api_dir",
      log_date_format: "YYYY-MM-DD HH:mm Z",
      node_args: "--max_old_space_size=4096",
      env: {
        PORT: 3300,
        NODE_ENV: "production",
        JWT_TOKEN_SECRET: "$JWT_TOKEN_SECRET",
        DEBUG: "erxes-api:*",
        MONGO_URL: "$API_MONGO_URL",
        ELASTICSEARCH_URL: "http://localhost:9200",
        ELK_SYNCER: "false",
        MAIN_APP_DOMAIN: "https://$erxes_domain",
        WIDGETS_DOMAIN: "https://$erxes_domain/widgets",
        INTEGRATIONS_API_DOMAIN: "https://$erxes_domain/integrations",
        LOGS_API_DOMAIN: "http://127.0.0.1:3800",
        ENGAGES_API_DOMAIN: "http://127.0.0.1:3900",
      },
    },
    {
      name: "erxes-cronjobs",
      script: "dist/cronJobs",
      cwd: "$erxes_api_dir",
      log_date_format: "YYYY-MM-DD HH:mm Z",
      node_args: "--max_old_space_size=4096",
      env: {
        PORT_CRONS: 3600,
        NODE_ENV: "production",
        PROCESS_NAME: "crons",
        DEBUG: "erxes-crons:*",
        MONGO_URL: "$API_MONGO_URL",
      },
    },
    {
      name: "erxes-workers",
      script: "dist/workers",
      cwd: "$erxes_api_dir",
      log_date_format: "YYYY-MM-DD HH:mm Z",
      node_args: "--experimental-worker",
      env: {
        PORT_WORKERS: 3700,
        NODE_ENV: "production",
        DEBUG: "erxes-workers:*",
        MONGO_URL: "$API_MONGO_URL",
        JWT_TOKEN_SECRET: "$JWT_TOKEN_SECRET",
      },
    },
    {
      name: "erxes-widgets",
      script: "dist",
      cwd: "$erxes_widgets_dir",
      log_date_format: "YYYY-MM-DD HH:mm Z",
      node_args: "--max_old_space_size=4096",
      env: {
        PORT: 3200,
        NODE_ENV: "production",
        ROOT_URL: "https://$erxes_domain/widgets",
        API_URL: "https://$erxes_domain/api",
        API_SUBSCRIPTIONS_URL: "wss://$erxes_domain/api/subscriptions",
      },
    },
    {
      name: "erxes-engages",
      script: "dist",
      cwd: "$erxes_engages_dir",
      log_date_format: "YYYY-MM-DD HH:mm Z",
      node_args: "--max_old_space_size=4096",
      env: {
        PORT: 3900,
        NODE_ENV: "production",
        DEBUG: "erxes-engages:*",
        MAIN_API_DOMAIN: "https://$erxes_domain/api",
        MONGO_URL: "$ENGAGES_MONGO_URL",
      },
    },
    {
      name: "erxes-logger",
      script: "dist",
      cwd: "$erxes_logger_dir",
      log_date_format: "YYYY-MM-DD HH:mm Z",
      node_args: "--max_old_space_size=4096",
      env: {
        PORT: 3800,
        NODE_ENV: "production",
        DEBUG: "erxes-logs:*",
        MONGO_URL: "$LOGGER_MONGO_URL",
      },
    },
    {
      name: "erxes-integrations",
      script: "dist",
      cwd: "$erxes_integrations_dir",
      log_date_format: "YYYY-MM-DD HH:mm Z",
      node_args: "--max_old_space_size=4096",
      env: {
        PORT: 3400,
        NODE_ENV: "production",
        DEBUG: "erxes-integrations:*",
        DOMAIN: "https://$erxes_domain/integrations",
        MAIN_APP_DOMAIN: "https://$erxes_domain",
        MAIN_API_DOMAIN: "https://$erxes_domain/api",
        MONGO_URL: "$INTEGRATIONS_MONGO_URL",
      },
    },
  ],
};
EOF

chown $username:$username $erxes_root_dir/ecosystem.config.js
chmod 644 $erxes_root_dir/ecosystem.config.js

# set mongod password
result=$(mongo --eval "db=db.getSiblingDB('admin'); db.createUser({ user: 'erxes', pwd: \"$MONGO_PASS\", roles: [ 'root' ] })" )
echo $result

# set up mongod ReplicaSet
systemctl stop mongod
mv /etc/mongod.conf /etc/mongod.conf.bak
cat<<EOF >/etc/mongod.conf
storage:
  dbPath: /var/lib/mongodb
  journal:
    enabled: true
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  bindIp: localhost
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
replication:
  replSetName: "rs0"
security:
  authorization: enabled
EOF
systemctl start mongod

echo "Starting MongoDB..."
curl https://raw.githubusercontent.com/vishnubob/wait-for-it/master/wait-for-it.sh > /usr/local/bin/wait-for-it.sh
chmod +x /usr/local/bin/wait-for-it.sh
/usr/local/bin/wait-for-it.sh --timeout=0 localhost:27017
while true; do
    healt=$(mongo --eval "db=db.getSiblingDB('admin'); db.auth('erxes', \"$MONGO_PASS\"); rs.initiate().ok" --quiet)
    if [ $healt -eq 0 ]; then
        break
    fi
done
echo "Started MongoDB ReplicaSet successfully"


# generate env.js
cat <<EOF >$erxes_ui_dir/js/env.js
window.env = {
  PORT: 3000,
  NODE_ENV: "production",
  REACT_APP_API_URL: "https://$erxes_domain/api",
  REACT_APP_API_SUBSCRIPTION_URL: "wss://$erxes_domain/api/subscriptions",
  REACT_APP_CDN_HOST: "https://$erxes_domain/widgets"
};
EOF
chown $username:$username $erxes_ui_dir/js/env.js
chmod 664 $erxes_ui_dir/js/env.js

# install nvm and install node using nvm
su $username -c "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.35.3/install.sh | bash"
su $username -c "source ~/.nvm/nvm.sh && nvm install $NODE_VERSION && nvm alias default $NODE_VERSION && npm install -g yarn pm2"

# make pm2 starts on boot
env PATH=$PATH:/home/$username/.nvm/versions/node/$NODE_VERSION/bin pm2 startup -u $username --hp /home/$username
systemctl enable pm2-$username

# start erxes pm2 and save current processes
su $username -c "source ~/.nvm/nvm.sh && nvm use $NODE_VERSION && cd $erxes_root_dir && pm2 start ecosystem.config.js && pm2 save"

# Nginx erxes config
cat <<EOF >/etc/nginx/sites-available/default
server {
        listen 80;
        
        server_name $erxes_domain;

        root $erxes_ui_dir;
        index index.html;
        
        error_log  /var/log/nginx/erxes.error.log;
        access_log /var/log/nginx/erxes.access.log;

        location / {
                root $erxes_ui_dir;
                index index.html;

                location / {
                        try_files \$uri /index.html;
                }
        }

        # widgets is running on 3200 port.
        location /widgets/ {
                proxy_pass http://127.0.0.1:3200/;
                proxy_set_header Host \$http_host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_http_version 1.1;
                proxy_set_header Upgrade \$http_upgrade;
                proxy_set_header Connection "Upgrade";
        }

        # api project is running on 3300 port.
        location /api/ {
                proxy_pass http://127.0.0.1:3300/;
                proxy_set_header Host \$host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_http_version 1.1;
                proxy_set_header Upgrade \$http_upgrade;
                proxy_set_header Connection "Upgrade";
        }
        # erxes integrations project is running on 3400 port.
        location /integrations/ {
                proxy_pass http://127.0.0.1:3400/;
                proxy_set_header Host \$http_host;
                proxy_set_header X-Real-IP \$remote_addr;
                proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                proxy_http_version 1.1;
                proxy_set_header Upgrade \$http_upgrade;
                proxy_set_header Connection "Upgrade";
        }
}
EOF
# reload nginx service
systemctl reload nginx

echo
echo -e "\e[32mInstallation complete\e[0m"
