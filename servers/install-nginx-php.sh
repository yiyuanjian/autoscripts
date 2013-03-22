#! /bin/sh
# This script is used to build php runtime environment on RHEL(centos) system.
# Author: Yuanjian Yi, yiyuanjian@gmail.com

WEB_SERVER_USER=web
WEB_SERVER_GROUP=web
WEB_SERVER_USERID=199
WEB_SERVER_GROUPID=199

WEBSITE_ROOT=/data/website
LOGS_ROOT=/data/logs
DB_ROOT=/data/db

TMP_DIR=/tmp/install.`date '+%Y%m%d%H%M%S'`
INSTALL_LOG=$TMP_DIR/install.log

NGINX_ROOT=/opt/nginx
NGINX_BIN=$NGINX_ROOT/sbin/nginx
NGINX_CONFDIR=$NGINX_ROOT/conf/
NGINX_SPLITLOG=$NGINX_ROOT/sbin/splitlog.sh
NGINX_VERSION=1.2.4


PHP_ROOT=/opt/php
PHP_FPM_BIN=$PHP_ROOT/sbin/php-fpm
PHP_CONFIG_FILE=$PHP_ROOT/lib/php.ini
PHP_EXTENSION_DIR=$PHP_ROOT/lib/php/extensions/no-debug-non-zts-20100525
PHP_VERSION=5.4.10

################ Common function ####################
function print_error {
    echo -e "\e[31;1mERROR:\e[0m $1"
}

function print_warn {
    echo -e "\e[33;1mWARNING:\e[0m $1"
}

function print_info {
    echo -e "\e[32;1mINFO:\e[0m $1"
}

function print_processing {
    echo -e "\e[36;1mProcess:\e[0m $1"
}

function print_ok {
    col=60
    echo -e "\e[${col}G[\e[32;1m OK \e[0m]"
}

function print_fail {
    col=60
    echo -e "\e[${col}G[\e[35;1mFAIL\e[0m]"
}



####### tempory dir
function mk_temp_dir {
    if [ ! -d $TMP_DIR ]; then
        mkdir -p $TMP_DIR
    fi
    cd $TMP_DIR
}

####### create user and group
function create_user_and_group {
    print_processing "Create User and group.."
    if [ ! -z "`grep ^$WEB_SERVER_GROUP: /etc/group`" ]; then
        existGid=`grep ^$WEB_SERVER_GROUP: /etc/group | awk -F ':' '{print $3}'`
        if [ "$existGid" -ne $WEB_SERVER_GROUPID ]; then
            print_error "group $WEB_SERVER_GROUP is exist, \
                but group id is not $WEB_SERVER_GROUPID"
            exit 1
        else
            print_warn "$WEB_SERVER_GROUP was created already"
        fi
    else
        groupadd -g $WEB_SERVER_GROUPID $WEB_SERVER_GROUP
    fi

    if [ ! -z "`grep ^$WEB_SERVER_USER: /etc/passwd`" ]; then
        existUid=`grep ^$WEB_SERVER_USER: /etc/passwd | awk -F ':' '{print $3}'`
        if [ "$existUid" -ne $WEB_SERVER_USERID ]; then
            print_error "User $WEB_SERVER_USER is exist, uid is not $WEB_SERVER_USERID"
            exit 1
        else
            print_warn "$WEB_SERVER_USER was created already"
        fi
    else
        useradd -u $WEB_SERVER_USERID -g $WEB_SERVER_GROUPID $WEB_SERVER_USER
    fi
    print_ok
}

####### create work dirs
function create_dirs {
    print_processing "Create directories.."
    mkdir -p $WEBSITE_ROOT/{default,public}
    mkdir -p $LOGS_ROOT/{nginx/default,php,mysql,apps}
    chown -R $WEB_SERVER_USER:$WEB_SERVER_GROUP $WEBSITE_ROOT $LOGS_ROOT
    mkdir -p $DB_ROOT/{mysql}
    print_ok
}

####### the default page
function create_default_page {
    su web -c 'echo -e "<?php\necho \"OK\";" > '$WEBSITE_ROOT'/default/index.php'
}

####### install packages that nginx php need
function install_dependency {
    print_processing "install dependency packages...."
    yum install -y gcc autoconf make pcre pcre-devel openssl openssl-devel zlib zlib-devel curl curl-devel libmcrypt libmcrypt-devel crypto-utils glibc glibc-devel libxml2 libxml2-devel >> $INSTALL_LOG
    if [ $? -ne 0 ]; then
        print_fail
    else
        print_ok
    fi
}


##################### start install nginx ###################
function nginx_download {
    cd $TMP_DIR
    wget -O nginx-$NGINX_VERSION.tar.gz http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz >>$INSTALL_LOG 2>&1

    if [ $? -ne 0 ]; then
        print_error "Download nginx failed"
        exit 1
    fi
}

function nginx_make_install {
    cd $TMP_DIR
    tar zxf nginx-*.tar.gz 

    cd nginx-*
    sed -i -e "s/\"$NGINX_VERSION\"/\"0.$NGINX_VERSION\"/g" -e 's/"nginx\/"/"webServer\/"/g' ./src/core/nginx.h
    ./configure --prefix=$NGINX_ROOT --with-openssl=/usr >>$INSTALL_LOG
    if [ $? -ne 0 ]; then
        print_error "Config nginx failed"
        exit 1
    fi

    make >> $INSTALL_LOG && make install >> $INSTALL_LOG
    if [ $? -ne 0 ]; then
        print_error "install nginx failed"
        exit 1
    fi
}

function nginx_config {
    cat > $NGINX_CONFDIR/nginx.conf << EOF
user  web;
worker_processes  2;

error_log  $LOGS_ROOT/nginx/error.log;
pid        logs/nginx.pid;

events {
    use epoll;
    worker_connections  10240;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    log_format  main  '\$http_x_forwarded_for	\$remote_addr	\$request_time	'
                      '\$upstream_response_time	[\$time_iso8601]	"\$request"	'
                      '\$status	\$body_bytes_sent	"\$http_referer"	'
                      '"\$http_user_agent"';

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;

    large_client_header_buffers 8 8k;
    proxy_buffers               8 8K;
    proxy_buffer_size           8K;


    include extra/default;

    include extra/*.conf;
}
EOF

    mkdir -p $NGINX_CONFDIR/extra

    cat > $NGINX_CONFDIR/extra/default << EOF
server {
    listen       80;
    server_name  localhost;

    charset utf-8;

    root $WEBSITE_ROOT/default;

    location / {
        index  index.html index.php;
    }

    access_log  $LOGS_ROOT/nginx/default/access.log  main;

    location ~ \.php$ {
        fastcgi_pass   unix:/var/run/php-fpm.socket;
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME  \$document_root\$fastcgi_script_name;
        fastcgi_param  SNDA_APP_ENV product;
        include    fastcgi_params;
    }
}
EOF

# write default index.html  //not need
    cat > $WEBSITE_ROOT/default/index.html << EOF
<html>
<head>
<title>Works</title>
<head>

<body>
Web Server works!
</body>
</html>
EOF

}

function nginx_add_splitlog {
    print_info "add log split support for nginx"

#add split_log 
    cat > $NGINX_SPLITLOG << EOF
#!/bin/sh

NGINX_ROOT=$NGINX_ROOT
NGINX_CONFDIR=$NGINX_CONFDIR
NGINX_BIN=$NGINX_BIN
NGINX_PID=\$NGINX_ROOT/logs/nginx.pid

DAY=\`date -d '1 day ago' +%Y-%m-%d\`

logs=\`find \$NGINX_CONFDIR -name "*.conf" -exec grep access_log {} + | grep -v '#\s*access_log' | awk '{print \$3}'\`
for log in \$logs
do
  if [ -f "\$log" ]; then
    mv \$log \$log.\$DAY
  fi
done

error_log=\`cat \$NGINX_CONFDIR/nginx.conf | grep error_log | grep -v '#' | awk '{print \$2}'\`
mv \$error_log \$error_log.\$DAY

#\$NGINX_BIN -s reload
kill -USR1 \`cat \$NGINX_PID\`
EOF

chmox +x $NGINX_SPLITLOG

####### add to crontab
    print_info "add split log script to crontab"
    crontab -l > $TMP_DIR/crontab.tmp
    echo "0 0 * * * $NGINX_SPLITLOG" >> $TMP_DIR/crontab.tmp
    crontab $TMP_DIR/crontab.tmp
    rm $TMP_DIR/crontab.tmp
}


function nginx_install_service {
    cat > /etc/init.d/nginx << EOF
#! /bin/sh

# nginx  nginx is the web server 
# chkconfig: 2345 85 35
# description: Nginx web server
# processname: nginx
# pidfile: \$NGINX_ROOT/logs/nginx.pid

. /etc/rc.d/init.d/functions

NGINX_ROOT=$NGINX_ROOT
NGINX_BIN=\$NGINX_ROOT/sbin/nginx
PIDFILE=\$NGINX_ROOT/logs/nginx.pid

start() {
    if [ -f \$PIDFILE ]; then
        echo -n "nginx is running"
        echo_failure
        echo
        return 1
    fi
    echo -n "Starting nginx..."
    \$NGINX_BIN
    sleep 2
    if [ -f \$PIDFILE ]; then
        echo_success
        echo
        return 0
    else 
        echo_failure
        echo
        return 1
    fi
}

stop() {
    if [ ! -f \$PIDFILE ]; then
        echo -n "nginx is not running"
        echo_failure
        echo
        return 1
    fi

    echo -n "Stoping nginx...."
    \$NGINX_BIN -s stop
    sleep 2
    if [ ! -f \$PIDFILE ]; then
        echo_success
        echo
        return 0
    else
        echo_failure
        echo
        return 1
    fi
}

restart() {
    stop
    ret=\$?
    if [ "\$ret" = "0" ]; then
        start
        ret=\$?
    fi
    return \$ret
}

reload() {
    if [ ! -f \$PIDFILE ]; then
        echo "Nginx is not running ..."
        echo_failure
        return 1
    fi
    
    echo -n "Reloading nginx...."
    \$NGINX_BIN -s reload
    sleep 2
    if [ ! -f \$PIDFILE ]; then
        echo_success
        echo
        return 0
    else
        echo_failure
        echo
        return 1
    fi
}

status() {
    if [ -f \$PIDFILE ]; then
        echo "nginx is running"
    else
        echo "nginx is not running"
    fi
    return 0
}

case "\$1" in
    start)
        start
        ret=\$?
        ;;
    stop)
        stop
        ret=\$?
        ;;
    restart)
        restart
        ret=\$?
        ;;
    reload)
        reload
        ret=\$?
        ;;
    status)
        status
        ret=\$?
        ;;
    *)
        echo "Usage service nginx {start|stop|reload|restart|status}"
        exit 2
esac

exit \$ret

EOF

    chmod +x /etc/init.d/nginx
    /sbin/chkconfig --add nginx
    /sbin/chkconfig --level 2345 nginx on

}

function install_nginx {
    print_processing "Start install nginx......"
    nginx_download
    nginx_make_install
    nginx_add_splitlog
    nginx_config
    nginx_install_service

    print_info "install nginx success"
    print_ok
}

function php5_download {
    cd $TMP_DIR
    wget -O php-$PHP_VERSION.tar.bz2 http://www.php.net/get/php-$PHP_VERSION.tar.bz2/from/kr1.php.net/mirror >> $INSTALL_LOG 2>&1
    if [ $? -ne 0 ]; then
        print_error "download php failed"
        exit 1
    fi
}

function php5_make_install {
    tar jxf php-$PHP_VERSION.tar.bz2
    cd php-$PHP_VERSION
    ./configure --prefix=$PHP_ROOT --enable-fpm --enable-sigchild --enable-mbstring --enable-shmop --enable-soap --enable-sockets --enable-sysvmsg --enable-sysvsem --enable-sysvshm --enable-zip --with-curl --enable-mysqlnd --with-mysql --with-mcrypt --with-openssl --enable-bcmath >>$INSTALL_LOG
    if [ $? -ne 0 ]; then
        print_error "config php failed"
        exit 1
    fi

    make >> $INSTALL_LOG && make install >> $INSTALL_LOG
    if [ $? -ne 0 ]; then
        print_error "compile php failed"
        exit 1
    fi
}

function php5_config {
    # extension dir
    if [ ! -d PHP_EXTENSION_DIR ]; then
        mkdir -p $PHP_EXTENSION_DIR
    fi 

    cat > $PHP_CONFIG_FILE << EOF
date.timezone="Asia/Shanghai"

include_path=.:$WEBSITE_ROOT/public

display_errors=Off
error_reporting = E_ALL & ~E_NOTICE
log_errors = On
log_errors_max_len = 1024
error_log=$LOGS_ROOT/php/error.log

upload_max_filesize=8M

extension_dir=$PHP_EXTENSION_DIR
EOF

    cat > $PHP_ROOT/etc/php-fpm.conf << EOF
# this file was created by auto install script. 
# if you want more configuration options, just refer php-fpm.conf.default

[global]
pid = run/php-fpm.pid
error_log=$LOGS_ROOT/php/php-fpm-error.log
log_level = error

[www]
user = $WEB_SERVER_USER
group = $WEB_SERVER_GROUP

listen = /var/run/php-fpm.socket
listen.backlog = 256

pm = dynamic
pm.max_children = 128
pm.start_servers = 16
pm.min_spare_servers = 16
pm.max_spare_servers = 32

pm.max_requests = 204800

slowlog = $LOGS_ROOT/php/\$pool.log.slow
request_slowlog_timeout = 3

EOF
}

# TODO install php extensions
function php5_install_ext {
    extname=$1
}

function php5_install_service {
    cat > /etc/init.d/php-fpm << EOF
#! /bin/sh

# php-fpm
# chkconfig: 2345 86 34
# description: php-fpm 
# processname: php-fpm
# pidfile: \$PHP_ROOT/var/run/php-fpm.pid

. /etc/rc.d/init.d/functions

PHP_ROOT=$PHP_ROOT
PHPFPM_BIN=\$PHP_ROOT/sbin/php-fpm
PHPFPM_CONF=\$PHP_ROOT/etc/php-fpm.conf
PIDFILE=\$PHP_ROOT/var/run/php-fpm.pid

start() {
    if [ -f \$PIDFILE ]; then
        echo -n "php-fpm is running"
        echo_failure
        echo
        return 1
    fi
    echo -n "Starting php-fpm..."
    \$PHPFPM_BIN -y \$PHPFPM_CONF
    sleep 2
    if [ -f \$PIDFILE ]; then
        echo_success
        echo
        return 0
    else 
        echo_failure
        echo
        return 1
    fi
}

stop() {
    if [ ! -f \$PIDFILE ]; then
        echo -n "[php-fpm is not running"
        echo_failure
        echo
        return 1
    fi

    echo -n "Stoping php-fpm...."
    killall php-fpm
    sleep 2
    if [ ! -f \$PIDFILE ]; then
        echo_success
        echo
        return 0
    else
        echo_failure
        echo
        return 1
    fi
}

restart() {
    stop
    ret=\$?
    if [ "\$ret" = "0" ]; then
      start
      ret=\$?
    fi
    return \$ret
}

status() {
    if [ -f \$PIDFILE ]; then
        echo "php-fpm is running"
    else
        echo "php-fpm is not running"
    fi
    return 0
}

case "\$1" in
    start)
        start
        ret=\$?
        ;;
    stop)
        stop
        ret=\$?
        ;;
    restart)
        restart
        ret=\$?
        ;;
    status)
        status
        ret=\$?
        ;;
    *)
        echo "Usage service php-fpm {start|stop|reload|restart|status}"
        exit 2
esac

exit \$ret

EOF

    chmod +x /etc/init.d/php-fpm
    /sbin/chkconfig --add php-fpm
    /sbin/chkconfig --level 2345 php-fpm on
}

function install_php5 {
    print_processing "start install php....."
    php5_download
    php5_make_install
    php5_config
    php5_install_ext
    php5_install_service
    
    print_ok
}

###################################### Main ######################

####### check user ######
if [ `id -un` != "root" ]; then
    print_error "You must to run this script as root"
    exit 1
fi

mk_temp_dir
echo "Start install in $TMP_DIR at `date '+%Y-%m-%d %H:%M:%S'`" | tee $INSTALL_LOG


create_user_and_group

create_dirs
create_default_page

### kernel-release
kernel_release=`uname -r | cut -d- -f1`

install_dependency

install_nginx

install_php5

print_info "Install nginx and php complete!"


###### start webserver and php #####
print_processing "Try to start nginx and php...."
/sbin/service nginx start
/sbin/service php-fpm start
print_ok

print_info "Install complete, you can check all log in $INSTALL_LOG"
print_info "The install temporay dir is '$TMP_DIR', you can remove it"

