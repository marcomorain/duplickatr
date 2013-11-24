openssl aes-128-cbc -d -salt -in env.sh.aes -out env.sh
chmod 755 env.sh
source env.sh
