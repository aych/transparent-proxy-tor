#!/bin/bash
# A script to install the latest version of Tor and configure it as a transparent proxy.

# Hardcoded latest version of Tor in case their site changes.
TOR_VERSION="0.2.4.17-rc"

function check_package {
  read lc <<< $(dpkg -s $1 | grep Status: | grep installed | wc -l)
  if [ $lc -eq 1 ]; then
    echo -e "[*] $1 is installed, proceeding...\n"
  else
    read -n1 -p "[*] The $1 package is not installed. Install it? (Y/n) " install_package
    case $install_package in
      [nN] ) echo -e "[-] Setup cannot proceed without $1, exiting..." 1>&2
             exit 1
             ;;
      *) apt-get install -y $1
    esac
  fi
}

# Was the script run as root?
if [[ $EUID -ne 0 ]]; then
   echo -e "[-] This script must be run as root.\n" 1>&2
   exit 1
fi

# Do they have the tools required to build Tor?
check_package build-essential

# Check for libevent-dev, which is apparently also required to build Tor.
check_package libevent-dev

# Check for libssl.
check_package libssl-dev

# Check for git, if present, we can get the latest version that way.
read -n1 -p "[*] Git may provide newer/more trusted source than the published tarball. Use git? (Y/n)" use_git
case $use_git in
  [nN] )
    # Find the latest version of Tor
    echo -e "[*] Updating Tor version information...\n"
    CONTENT=`wget -qO- https://www.torproject.org/download/download.html.en`
    if [ $? -eq 0 ]; then
      TOR_VERSION=`echo $CONTENT | grep unstable | sed -r 's/.+Tor is ([^ ]+).*/\1/' | sed 's/\.$//'`
    fi

    # Fetch some version of Tor
    URL="https://www.torproject.org/dist/tor-$TOR_VERSION.tar.gz"
    echo -e "[*] Attempting to download $URL..."
    wget $URL
    if [ $? -eq 0 ]; then
      echo -e "[*] Latest version of Tor acquired, proceeding..."
    else
      echo -e "[-] Could not download Tor, exiting...\n" 1>&2
      exit 1
    fi

    # Extract the Tor source
    echo -e "[*] Extracting Tor source..."
    tar zxf "tor-$TOR_VERSION.tar.gz"
    if [ $? -eq 0 ]; then
      echo "[*] Source extracted, proceeding..."
    else
      echo -e "[-] Could not extract Tor, exiting...\n" 1>&2
      exit 1
    fi

    # Go to the Tor directory
    cd ./tor-$TOR_VERSION
    ;;
  *) check_package git
     check_package autoconf
     git clone git://git.torproject.org/git/tor
     cd ./tor
     ./autogen.sh
     ;;
esac

# Build Tor
./configure --disable-asciidoc
if [ $? -ne 0 ]; then
  echo -e "[-] There was an error configuring Tor for the build process, exiting...\n" 1>&2
  exit 1
fi
make
if [ $? -ne 0 ]; then
  echo -e "[-] There was an error building Tor, exiting...\n" 1>&2
  exit 1
fi
make install
if [ $? -ne 0 ]; then
  echo -e "[-] There was an error installing Tor, exiting...\n" 1>&2
  exit 1
fi

# Create a user under which to run Tor
adduser --disabled-login --gecos "Tor user,,," tor
if [ $? -eq 0 ]; then
  echo "[*] User (tor) created for running Tor, proceeding..."
  TOR_USER=`id tor | sed -r 's/[^0-9]+([0-9]+).*/\1/'`
else
  echo "[-] There was an error creating a user for Tor, exiting..." 1>&2
  exit 1
fi

# Modify the torrc to reflect the settings we need.
# It's /usr/local/etc/tor/torrc.sample
cp /usr/local/etc/tor/torrc.sample /usr/local/etc/tor/torrc
echo "VirtualAddrNetwork 10.192.0.0/10" >> /usr/local/etc/tor/torrc
echo "AutomapHostsOnResolve 1" >> /usr/local/etc/tor/torrc
echo "TransPort 9040" >> /usr/local/etc/tor/torrc
echo "DNSPort 53" >> /usr/local/etc/tor/torrc

mkdir -p /var/lib/tor
mkdir -p /var/log/tor
mkdir -p /var/run/tor
chown tor:tor /var/lib/tor
chown tor:tor /var/log/tor
chown tor:tor /var/run/tor

# Manually fix permissions
chmod 750 /var/run/tor

echo "DataDirectory /var/lib/tor" > /usr/local/etc/tor/torrc-defaults
echo "PidFile /var/run/tor/tor.pid" >> /usr/local/etc/tor/torrc-defaults
echo "RunAsDaemon 1" >> /usr/local/etc/tor/torrc-defaults
echo "User tor" >> /usr/local/etc/tor/torrc-defaults
echo "ControlSocket /var/run/tor/control" >> /usr/local/etc/tor/torrc-defaults
echo "ControlSocketsGroupWritable 1" >> /usr/local/etc/tor/torrc-defaults
echo "CookieAuthentication 1" >> /usr/local/etc/tor/torrc-defaults
echo "CookieAuthFileGroupReadable 1" >> /usr/local/etc/tor/torrc-defaults
echo "CookieAuthFile /var/run/tor/control.authcookie" >> /usr/local/etc/tor/torrc-defaults
echo "Log notice file /var/log/tor/log" >> /usr/local/etc/tor/torrc-defaults

# Do they want to allow UDP?
UDP_MESSAGE="Tor does not transport UDP, therefore any UDP communication will take place"
UDP_MESSAGE+=" using your actual IP address. However, some programs will require UDP to"
UDP_MESSAGE+=" work. Do you want to allow UDP traffic? [Not recommended] (y/N)"

read -n1 -p "$UDP_MESSAGE" allow_udp
echo -e "\n"

# Do they want to allow ICMP, ping?
ICMP_MESSAGE="Tor does not transport ICMP, therefore any ICMP communication will take place"
ICMP_MESSAGE+=" using your actual IP address. However, some programs (like ping) will"
ICMP_MESSAGE+=" require ICMP to work. Do you want to allow ICMP traffic? [Not recommended]"
ICMP_MESSAGE+=" (y/N)"

read -n1 -p "$ICMP_MESSAGE" allow_icmp
echo -e "\n"

# Is it OK to clobber their firewall in favor of this one?
IPTABLES_MESSAGE="If you have any iptables rules, they will be removed. Is that OK? (Y/n)"

read -n1 -p "$IPTABLES_MESSAGE" delete_iptables
echo -e "\n"
case $delete_iptables in
  [nN] ) echo "iptables rules not cleared, cannot proceed. Exiting..."
         exit 1
         ;;
  *) iptables -F
     iptables -t nat -F
     ;;
esac

# Do they have a local subnet that they want to access/allow to access this?
SUBNET_MESSAGE="By default, this script will cause your system to proxy all traffic through"
SUBNET_MESSAGE+=" Tor. This renders your local subnet inaccessible. Do you want to add a"
SUBNET_MESSAGE+=" local subnet that is exempt from the transparent proxy? (y/N)"

read -n1 -p "$SUBNET_MESSAGE" allow_subnet
echo -e "\n"

case $allow_subnet in
  [yY] ) read -p "Type the subnet in CIDR notation (e.g., 192.168.0.0/24): " cidr_subnet
         iptables -A OUTPUT -d $cidr_subnet -j ACCEPT
         iptables -t nat -A OUTPUT -d $cidr_subnet -j ACCEPT
         ;;
  *) ;;
esac

# Install the necessary rules.
iptables -A OUTPUT -s 127.0.0.1/32 -d 127.0.0.1/32 -p udp -m udp --sport 53 -j ACCEPT
iptables -A OUTPUT -s 127.0.0.1/32 -p tcp -m tcp --sport 9040 -j ACCEPT
iptables -A OUTPUT -p tcp -m owner ! --uid-owner $TOR_USER -m tcp --dport 9040 -j ACCEPT
iptables -A OUTPUT -p udp -m owner ! --uid-owner $TOR_USER -m udp --dport 53 -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner $TOR_USER -j ACCEPT
case $allow_udp in
  [yY] ) ;;
  *) iptables -A OUTPUT -p udp -j DROP ;;
esac
case $allow_icmp in
  [yY] ) ;;
  *) iptables -A OUTPUT -p icmp -j DROP ;;
esac
iptables -t nat -A OUTPUT ! -o lo -p tcp -m owner ! --uid-owner $TOR_USER -j REDIRECT --to-ports 9040
iptables -t nat -A OUTPUT ! -o lo -p udp -m udp --dport 53 -m owner ! --uid-owner $TOR_USER -j REDIRECT --to-ports 53

# Save the iptables rules.
iptables-save > /etc/iptables.rules

# Fix resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf

# Modify the rc.local so that the rules get loaded on reboot.
sed -i '$ i echo "nameserver 127.0.0.1" > /etc/resolv.conf' /etc/rc.local
sed -i '$ i iptables-restore < /etc/iptables.rules' /etc/rc.local
sed -i '$ i /usr/local/bin/tor -f /usr/local/etc/tor/torrc --defaults-torrc /usr/local/etc/tor/torrc-defaults --hush' /etc/rc.local

echo "[+] Starting Tor..."
/usr/local/bin/tor -f /usr/local/etc/tor/torrc --defaults-torrc /usr/local/etc/tor/torrc-defaults --hush
