#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
#
# OpenStack Barebones provisioning Script
#
# Written by Stephen Hawking (Haywoodspartan#0001) @ Awakened Network LLP
#
# Uh oh Retard Alert my first full blown Linux Bash Script only for RHEL and CENTOS/FEDORA
VERSION='0.13'

trap 'exit_cleanup' EXIT
trap 'echo "interrupted, cleaning up..."; exit_cleanup; exit 1' INT
exit_cleanup()
{
	#Cleanup Files and packages that are samples or copied and modified
	yum clean all
}
# if we were git clone'd, adjust VERSION
if [ -d "$(dirname "$0")/.git" ] && command -v git >/dev/null 2>&1; then
	describe=$(git -C "$(dirname "$0")" describe --tags --dirty 2>/dev/null)
	[ -n "$describe" ] && VERSION=$(echo "$describe" | sed -e s/^v//)
fi

show_usage()
{
		# shellcheck disable=SC2086
		cat <<EOF
		Usage:
				install.sh: (New Root Database Password)
EOF
}

show_disclaimer()
{
		cat <<EOF
Disclaimer:
This tool is very unstable in it's current state and it will not reflect all configuration for the Hardware that it is used on. However this tool is modifiable from top to bottom including the names and commands used to the passwords that are set for the
Openstack Admin-Openrc file that is used to initiate openstack administrative commands via the keystone system.

Please feel free to look over the code and improve on it as you see fit and do pull requests on the github page you found this on and I will credit you as someone who has worked on it.
EOF
}
read -p "Do you agree that this tool may break your environment?"
echo    # (optional) move to a new line
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    exit 1
fi
export os=$(uname -s)

# find a sane command to print colored messages, we prefer `printf` over `echo`
# because `printf` behavior is more standard across Linux/BSD
# we'll try to avoid using shell builtins that might not take options
echo_cmd_type='echo'
# ignore SC2230 here because `which` ignores builtins while `command -v` doesn't, and
# we don't want builtins here. Even if `which` is not installed, we'll fallback to the
# `echo` builtin anyway, so this is safe.
# shellcheck disable=SC2230
if command -v printf >/dev/null 2>&1; then
	echo_cmd=$(command -v printf)
	echo_cmd_type='printf'
elif which echo >/dev/null 2>&1; then
	echo_cmd=$(which echo)
else
	# maybe the `which` command is broken?
	[ -x /bin/echo        ] && echo_cmd=/bin/echo
	# for Android
	[ -x /system/bin/echo ] && echo_cmd=/system/bin/echo
fi
# still empty? fallback to builtin
[ -z "$echo_cmd" ] && echo_cmd='echo'
__echo()
{
	opt="$1"
	shift
	_msg="$*"

	if [ "$opt_no_color" = 1 ] ; then
		# strip ANSI color codes
		# some sed versions (i.e. toybox) can't seem to handle
		# \033 aka \x1B correctly, so do it for them.
		if [ "$echo_cmd_type" = printf ]; then
			_interpret_chars=''
		else
			_interpret_chars='-e'
		fi
		_ctrlchar=$($echo_cmd $_interpret_chars "\033")
		_msg=$($echo_cmd $_interpret_chars "$_msg" | sed -r "s/$_ctrlchar\[([0-9][0-9]?(;[0-9][0-9]?)?)?m//g")
	fi
	if [ "$echo_cmd_type" = printf ]; then
		if [ "$opt" = "-n" ]; then
			$echo_cmd "$_msg"
		else
			$echo_cmd "$_msg\n"
		fi
	else
		# shellcheck disable=SC2086
		$echo_cmd $opt -e "$_msg"
	fi
}

_echo()
{
	if [ "$opt_verbose" -ge "$1" ]; then
		shift
		__echo '' "$*"
	fi
}

_echo_nol()
{
	if [ "$opt_verbose" -ge "$1" ]; then
		shift
		__echo -n "$*"
	fi
}

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi
#Check for FIPS Mode Enabled
if sysctl crypto.fips_enabled -ne 1>&2;
 then
	read -p "Would you like to enable FIPS System Cryptography" 0>&1
	echo    # (optional) move to a new line
 elif [[ ! $REPLY =~ ^[Yy]$ ]]
	then
	fips-mode-setup --enabled
 else [[ ! $REPLY =~ ^[Nn]$ ]]
	exit 1
	elfi
fi
#Call for the Change of Mariadb Root Password
if [ -n "${1}" -a -z "${2}" ]; then
    # Setup root password
    CURRENT_MYSQL_PASSWORD=''
    NEW_MYSQL_PASSWORD="${1}"
elif [ -n "${1}" -a -n "${2}" ]; then
    # Change existing root password
    CURRENT_MYSQL_PASSWORD="${1}"
    NEW_MYSQL_PASSWORD="${2}"
else
    echo "Usage:"
    echo "  Setup mysql root password: ${0} 'your_new_root_password'"
    echo "  Change mysql root password: ${0} 'your_old_root_password' 'your_new_root_password'"
    exit 1
fi
echo "[Starting Task 1: Yum Update and Enable Required Subscriptions for RHEL 8]"
echo "... About to create and enable repo files and gpg keys with cat commands ..."
setenforce 0
dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm -y
dnf install https://www.rdoproject.org/repos/rdo-release.el8.rpm -y

yum update -y
subscription-manager repos --enable=rhel-8-for-x86_64-appstream-rpms \
--enable=rhel-8-for-x86_64-supplementary-rpms --enable=codeready-builder-for-rhel-8-x86_64-rpms

echo "[Starting Task 2: Install NetworkManager and OpenvSwitch for RHEL 8]"
echo "... About to install and create the Openvswitch bridges and attach static IP's to them ..."
yum install NetworkManager-ovs openvswitch libibverbs -y
export NET_DEV="eno1"
nmcli con |grep -E -w "$((NET_DEV))"
systemctl enable --now openvswitch
systemctl restart NetworkManager
nmcli con add type ovs-bridge conn.interface provider-br con-name provider-br
nmcli con add type ovs-port conn.interface port-provider-br master provider-br con-name provider-br-port
nmcli con add type ovs-interface slave-type ovs-port conn.interface provider-br master provider-br-port con-name provider-br-int
nmcli con add type ovs-port conn.interface provider-br-eno1 master provider-br con-name provider-br-port-eno1
nmcli con add type ethernet conn.interface "${NET_DEV}" master provider-br-eno1 con-name provider-br-port-eno1-int
nmcli con modify provider-br-int ipv4.method disabled ipv6.method disabled
nmcli con modify provider-br-int ipv4.method static ipv4.addresses 10.24.1.2/21,10.24.1.3/32
nmcli con modify provider-br-int ipv4.gateway 10.24.0.1
nmcli con modify provider-br-int ipv4.dns 10.24.0.1
nmcli con down "${NET_DEV}" ; \
nmcli con up provider-br-port-eno1-int ; \
nmcli con up provider-br-int
nmcli con modify "${NET_DEV}" ipv4.method disabled ipv6.method disabled
nmcli con delete "${NET_DEV}"

echo "[Starting Task 3: Install Prerequisite OpenStack Packages and Database Server Packages]"
echo "... Installing Packages from Yum Package Manager ..."
yum install mariadb mariadb-server python2-PyMySQL rabbitmq-server memcached python3-memcached etcd httpd -y
yum install python3-openstackclient openstack-selinux -y
yum install openstack-keystone openstack-neutron openstack-neutron-ml2 openstack-neutron-o* ebtables openstack-cinder openstack-nova openstack-nova-compute openstack-placement-api openstack-dashboard python3-mod_wsgi -y

echo "[Starting Task 4: Provisioning Database defaults for OpenStack Wallaby]"
cat >/etc/my.cnf.d/openstack.cnf <<EOL
[mysqld]
bind-address = 10.24.1.3

default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOL
echo "...starting mariadb-server service and enabling..."
systemctl enable mariadb.service
systemctl start mariadb.service

SECURE_MYSQL=$(expect -c "
set timeout 3
spawn mysql_secure_installation
expect \"Enter current password for root (enter for none):\"
send \"$CURRENT_MYSQL_PASSWORD\r\"
expect \"root password?\"
send \"y\r\"
expect \"New password:\"
send \"$NEW_MYSQL_PASSWORD\r\"
expect \"Re-enter new password:\"
send \"$NEW_MYSQL_PASSWORD\r\"
expect \"Remove anonymous users?\"
send \"y\r\"
expect \"Disallow root login remotely?\"
send \"n\r\"
expect \"Remove test database and access to it?\"
send \"y\r\"
expect \"Reload privilege tables now?\"
send \"y\r\"
expect eof
")
#
# Execution mysql_secure_installation
#
echo "${SECURE_MYSQL}"

#
# Execution of Provisioning Openstack Tables
#

mysql -u root -p "$NEW_MYSQL_PASSWORD" <<EOF
CREATE SCHEMA placement;
CREATE SCHEMA glance;
CREATE SCHEMA cinder;
CREATE SCHEMA keystone;
CREATE SCHEMA neutron;
CREATE SCHEMA nova_api;
CREATE SCHEMA nova;
CREATE SCHEMA nova_cell0;
CREATE SCHEMA zun;
CREATE SCHEMA heat;
GRANT ALL PRIVILEGES ON *.* to 'root'@'%' IDENTIFIED BY \
'{$NEW_MYSQL_PASSWORD}';
GRANT GRANT OPTION ON *.* TO 'root'@'%';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY 'aYdMWWoa4qyjrF9WmIRjo2ybiDEBcwbuPcghDWESMLHajpcJmRE517BXNpLi4wZ4';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY 'aYdMWWoa4qyjrF9WmIRjo2ybiDEBcwbuPcghDWESMLHajpcJmRE517BXNpLi4wZ4';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY 'VixEoW6BcpuRmmm7GYPYj0pwB1nvIsXtf8cqCsn7RiB9ehElWCzA5g60D4NEX0Jx';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY 'VixEoW6BcpuRmmm7GYPYj0pwB1nvIsXtf8cqCsn7RiB9ehElWCzA5g60D4NEX0Jx';
GRANT ALL PRIVILEGES ON glance.* TO 'glance' @'%' IDENTIFIED BY '0DCv0Y0JqNPwd0ZRsmmIP77Txt0a7BM3B402w0TQs68CqXEseeFvXqVVyVYPmtIU';
GRANT ALL PRIVILEGES ON glance.* TO 'glance' @'localhost' IDENTIFIED BY '0DCv0Y0JqNPwd0ZRsmmIP77Txt0a7BM3B402w0TQs68CqXEseeFvXqVVyVYPmtIU';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%' IDENTIFIED BY 'tTlFAXHcYSJmIdNhkwIez7W8cJcdErBty548VUhBqrdhaf3gKO4k7l01fny3bH3y';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost' IDENTIFIED BY 'tTlFAXHcYSJmIdNhkwIez7W8cJcdErBty548VUhBqrdhaf3gKO4k7l01fny3bH3y';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY 'UvSYhWaLBs8ty1TJ47PfpciX7KrGYOe28Tqz7pXKeAdMHCSU2TX3Ng1PSIEBraql';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY 'UvSYhWaLBs8ty1TJ47PfpciX7KrGYOe28Tqz7pXKeAdMHCSU2TX3Ng1PSIEBraql';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%' IDENTIFIED BY 'UvSYhWaLBs8ty1TJ47PfpciX7KrGYOe28Tqz7pXKeAdMHCSU2TX3Ng1PSIEBraql';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost' IDENTIFIED BY 'UvSYhWaLBs8ty1TJ47PfpciX7KrGYOe28Tqz7pXKeAdMHCSU2TX3Ng1PSIEBraql';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%' IDENTIFIED BY 'UvSYhWaLBs8ty1TJ47PfpciX7KrGYOe28Tqz7pXKeAdMHCSU2TX3Ng1PSIEBraql';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost' IDENTIFIED BY 'UvSYhWaLBs8ty1TJ47PfpciX7KrGYOe28Tqz7pXKeAdMHCSU2TX3Ng1PSIEBraql';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY 'jmFKDIV1oTZljiimkGvSDySwzcs4xD2FdurwJztWP7QYW94xyVMbAhNwEKZQGQhr';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY 'jmFKDIV1oTZljiimkGvSDySwzcs4xD2FdurwJztWP7QYW94xyVMbAhNwEKZQGQhr';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost' IDENTIFIED BY 'Cbyyb8c0HdpHJqxSU60Hg6zUKmB0AkP3Z5oTNkLpkIHtotcag8JRb7v64MQb60vg';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%' IDENTIFIED BY 'Cbyyb8c0HdpHJqxSU60Hg6zUKmB0AkP3Z5oTNkLpkIHtotcag8JRb7v64MQb60vg';
GRANT ALL PRIVILEGES ON zun.* TO 'zun'@'localhost' IDENTIFIED BY 'AiYmLoKzLlNKDB2N1evROGjWSevltpcxT7GgyjbBM16Ox5q0Tex7vzPg3l4phRvr';
GRANT ALL PRIVILEGES ON zun.* TO 'zun'@'%' IDENTIFIED BY 'AiYmLoKzLlNKDB2N1evROGjWSevltpcxT7GgyjbBM16Ox5q0Tex7vzPg3l4phRvr';
exit;
EOF

echo "[Starting Task 4.1: Setting up Rabbit Message Queue Service System]"
systemctl enable rabbitmq-server.service
systemctl start rabbitmq-server.service
rabbitmqctl add_user openstack W40LFZa5ko6IiJ3KFHkAmLegBy8bY3O29xAvc0xpEQt2AbmlVYAce7m8DtRVQTh8
rabbitmqctl set_permissions openstack ".*" ".*" ".*"
sed -i 's|# vm_memory_high_watermark.absolute = 2GB|vm_memory_high_watermark = 768M|g' /etc/rabbitmq/rabbitmq.conf
more /etc/rabbitmq/rabbitmq.conf
systemctl restart rabbitmq-server.service

echo "[Starting Task 4.2: Setting up Memcached Service]"
sed -i 's|OPTIONS="-l 127.0.0.1,::1"|OPTIONS="-l 127.0.0.1,::1,10.24.1.3s,"|g' /etc/sysconfig/memcached
systemctl enable memcached.service
systemctl start memcached.service

echo "[Starting Task 4.3: Setting up Etcd System]"
sed -i 's|#ETCD_LISTEN_PEER_URLS="http://localhost:2380"|ETCD_LISTEN_PEER_URLS="http://10.24.1.3:2380"|g' /etc/etcd/etcd.conf
sed -i 's|ETCD_LISTEN_CLIENT_URLS="http://localhost:2379"|ETCD_LISTEN_CLIENT_URLS="http://10.24.1.3:2379"|g' /etc/etcd/etcd.conf
sed -i 's|ETCD_NAME="default"|ETCD_NAME="openstack.kuybii.dev"|g' /etc/etcd/etcd.conf
sed -i 's|#ETCD_INITIAL_ADVERTISE_PEER_URLS="http://localhost:2380"|ETCD_INITIAL_ADVERTISE_PEER_URLS="http://10.24.1.3:2380"|g' /etc/etcd/etcd.conf
sed -i 's|ETCD_ADVERTISE_CLIENT_URLS="http://localhost:2379"|ETCD_ADVERTISE_CLIENT_URLS="http://10.24.1.3:2379"|g' /etc/etcd/etcd.conf
sed -i 's|#ETCD_INITIAL_CLUSTER="default=http://localhost:2380"|ETCD_INITIAL_CLUSTER="openstack.kuybii.dev=http://10.24.1.3:2380"|g' /etc/etcd/etcd.conf
sed -i 's|#ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"|ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster-01"|g' /etc/etcd/etcd.conf
sed -i 's|#ETCD_INITIAL_CLUSTER_STATE="new"|ETCD_INITIAL_CLUSTER_STATE="new"|g' /etc/etcd/etcd.conf
systemctl enable etcd.service
systemctl start etcd.service

echo "[Starting Task 5: Setting up OpenStack Keystone and Provisioning Endpoints]"
sed -i 's|#connection = <None>|connection = mysql+pymysql://keystone:jmFKDIV1oTZljiimkGvSDySwzcs4xD2FdurwJztWP7QYW94xyVMbAhNwEKZQGQhr@10.24.1.2/keystone|g' /etc/keystone/keystone.conf
sed -i 's|#provider = fernet|provider = fernet|g' /etc/keystone/keystone.conf

echo "...Populating Keystone Database..."
su -s /bin/sh -c "keystone-manage db_sync" keystone

keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone

keystone-manage bootstrap --bootstrap-password ADMIN_PASS \
--bootstrap-admin-url http://10.24.1.2:5000/v3/ \
--bootstrap-internal-url http://10.24.1.2:5000/v3/ \
--bootstrap-public-url http://10.24.1.2:5000/v3/ \
--bootstrap-region-id Home

sed -i 's|#ServerName www.example.com:80|ServerName 10.24.1.2|g' /etc/httpd/conf/httpd.conf
ln -s /usr/share/keystone/wsgi-keystone.conf /etc/httpd/conf.d/
systemctl enable httpd.service
systemctl start httpd.service

echo "... Creating admin-openrc file at /root/..."
cat >~/admin-openrc <<EOL
export OS_USERNAME=admin
export OS_PASSWORD=TestSubjectE57
export OS_PROJECT_NAME=admin
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_DOMAIN_NAME=Default
export OS_AUTH_URL=http://10.24.1.2:5000/v3
export OS_IDENTITY_API_VERSION=3
EOL
. admin-Openrc
openstack project create --domain default \
  --description "Service Project" service

echo "[Starting Task 6: Setting up OpenStack Glance Imaging Service]"
	CreateGlance=$(expect -c "
	set timeout 3
	spawn openstack user create --domain default --password-prompt glance
	expect \"User Password:\"
	send \"2WFWkIdOxwMVPjuOaav9tigSEJUpVb5IZ2WdZ45uuahrHJY3SS5xX4gfi3EZFSRs\r\"
	expect \"Repeat User Password:\r\"
	send \"2WFWkIdOxwMVPjuOaav9tigSEJUpVb5IZ2WdZ45uuahrHJY3SS5xX4gfi3EZFSRs\r\"
	set timeout 7
	spawn openstack role add --project service --user glance admin
	set timeout 5
	spawn openstack service create --name glance --description "Openstack Image" image
	set timeout 5
	spawn openstack endpoint create --region Home image public http://10.24.1.2:9292
	set timeout 5
	spawn openstack endpoint create --region Home image internal http://10.24.1.2:9292
	set timeout 5
	spawn openstack endpoint create --region Home image admin http://10.24.1.2:9292
	expect eof
	")
	#
	#Execute Create Glance
	#
	echo "${CreateGlance}"
sed -i 's|#connection = <None>|connection = mysql+pymysql://glance:0DCv0Y0JqNPwd0ZRsmmIP77Txt0a7BM3B402w0TQs68CqXEseeFvXqVVyVYPmtIU@10.24.1.2/glance|g' /etc/glance/glance-api.conf
cat <<EOT >> /etc/glance/glance.conf
[keystone_authtoken]
www_authenticate_uri  = http://10.24.1.2:5000
auth_url = http://10.24.1.2:5000
memcached_servers = 10.24.1.2:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = glance
password = 2WFWkIdOxwMVPjuOaav9tigSEJUpVb5IZ2WdZ45uuahrHJY3SS5xX4gfi3EZFSRs
[paste_deploy]
flavor = keystone
[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/
EOT

su -s /bin/sh -c "glance-manage db_sync" glance
systemctl enable openstack-glance-api.service
systemctl start  openstack-glance-api.service

echo "[Starting Task 7: Setting up OpenStack Placement API Service]"
CreatePlacement=$(expect -c "
set timeout 3
spawn openstack user create --domain default --password-prompt glance
expect \"User Password:\"
send \"740EMvnrkkNmLGIi2KyR0WaRoM9ftbfnBuS9IGLewOdnFQktBxdhEzuFfvm6oEtD\r\"
expect \"Repeat User Password:\r\"
send \"740EMvnrkkNmLGIi2KyR0WaRoM9ftbfnBuS9IGLewOdnFQktBxdhEzuFfvm6oEtD\r\"
set timeout 7
spawn openstack role add --project service --user placement admin
set timeout 5
spawn openstack service create --name placement --description "Placement API" placement
set timeout 5
spawn openstack endpoint create --region Home placement public http://10.24.1.2:8778
set timeout 5
spawn openstack endpoint create --region Home placement internal http://10.24.1.2:8778
set timeout 5
spawn openstack endpoint create --region Home placemnt admin http://10.24.1.2:8778
expect eof
")
#
#Execute Create Glance
#
echo "${CreatePlacement}"
sed -i 's|#connection = <None>|connection = mysql+pymysql://placement:tTlFAXHcYSJmIdNhkwIez7W8cJcdErBty548VUhBqrdhaf3gKO4k7l01fny3bH3y@10.24.1.2/placement|g' /etc/placement/placement.conf
cat <<EOT >> /etc/placement/placement.conf
[api]
auth_strategy = keystone

[keystone_authtoken]
auth_url = http://10.24.1.2:5000/v3
memcached_servers = 10.24.1.2:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = placement
password = 740EMvnrkkNmLGIi2KyR0WaRoM9ftbfnBuS9IGLewOdnFQktBxdhEzuFfvm6oEtD
EOT
su -s /bin/sh -c "placement-manage db sync" placement
systemctl restart httpd
placement-status upgrade check
pip3 install osc-placement -y
openstack --os-placement-api-version 1.2 resource class list --sort-column name
openstack --os-placement-api-version 1.6 trait list --sort-column name
