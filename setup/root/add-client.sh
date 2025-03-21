#!/bin/bash
#
# Добавление нового клиента (* - только для OpenVPN)
#
# chmod +x add-client.sh && ./add-client.sh [ov/wg] [имя_клиента] [срок_действия*]
#
set -e

handle_error() {
	echo ""
	echo "Error occurred at line $1 while executing: $2"
	echo ""
	echo "$(lsb_release -d | awk -F'\t' '{print $2}') $(uname -r) $(date)"
	exit 1
}
trap 'handle_error $LINENO "$BASH_COMMAND"' ERR

mkdir -p /root/vpn/old

TYPE=$1
if [[ "$TYPE" != "init" && "$TYPE" != "recreate" && "$TYPE" != "list" ]]; then

	if [[ "$TYPE" != "ov" && "$TYPE" != "wg" ]]; then
		echo ""
		echo "Please choose the VPN type:"
		echo "    1) OpenVPN"
		echo "    2) WireGuard/AmneziaWG"
		until [[ $TYPE =~ ^[1-2]$ ]]; do
			read -rp "Type choice [1-2]: " -e TYPE
		done
	fi

	CLIENT=$2
	if [[ -z "$CLIENT" || ! "$CLIENT" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
		echo ""
		echo "Tell me a name for the new client"
		echo "The name client must consist of 1 to 32 alphanumeric characters, it may also include an underscore or a dash"
		until [[ $CLIENT =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; do
			read -rp "Client name: " -e CLIENT
		done
	fi

	SERVER_IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	NAME="$CLIENT"
	NAME="${NAME#antizapret-}"
	NAME="${NAME#vpn-}"

fi

render() {
	local IFS=''
	local File="$1"
	while read -r line; do
		while [[ "$line" =~ (\$\{[a-zA-Z_][a-zA-Z_0-9]*\}) ]]; do
			local LHS=${BASH_REMATCH[1]}
			local RHS="$(eval echo "\"$LHS\"")"
			line=${line//$LHS/$RHS}
		done
		echo "$line"
	done < $File
}

# OpenVPN
if [[ "$TYPE" == "ov" || "$TYPE" == "1" ]]; then

	mkdir -p /etc/openvpn/easyrsa3
	cd /etc/openvpn/easyrsa3

	load_key() {
		CA_CERT=$(grep -A 999 'BEGIN CERTIFICATE' -- "/etc/openvpn/server/keys/ca.crt")
		CLIENT_CERT=$(grep -A 999 'BEGIN CERTIFICATE' -- "/etc/openvpn/client/keys/$CLIENT.crt")
		CLIENT_KEY=$(cat -- "/etc/openvpn/client/keys/$CLIENT.key")
		if [[ ! "$CA_CERT" ]] || [[ ! "$CLIENT_CERT" ]] || [[ ! "$CLIENT_KEY" ]]; then
			echo "Can't load client keys!"
			exit 11
		fi
        DATE=$(date +'%d.%m.%Y')
	}

	if [[ ! -f ./pki/ca.crt ]] || \
	   [[ ! -f ./pki/issued/antizapret-server.crt ]] || \
	   [[ ! -f ./pki/private/antizapret-server.key ]]; then
		rm -rf ./pki/
		/usr/share/easy-rsa/easyrsa init-pki
		EASYRSA_CA_EXPIRE=3650 /usr/share/easy-rsa/easyrsa --batch --req-cn="AntiZapret CA" build-ca nopass
		EASYRSA_CERT_EXPIRE=3650 /usr/share/easy-rsa/easyrsa --batch build-server-full "antizapret-server" nopass
		echo "Created new PKI and CA"
	fi

	if [[ ! -f ./pki/crl.pem ]]; then
		/usr/share/easy-rsa/easyrsa gen-crl
		echo "Created new CRL"
	fi

	if [[ ! -f /etc/openvpn/server/keys/ca.crt ]] || \
	   [[ ! -f /etc/openvpn/server/keys/antizapret-server.crt ]] || \
	   [[ ! -f /etc/openvpn/server/keys/antizapret-server.key ]] || \
	   [[ ! -f ./pki/crl.pem ]]; then
		cp ./pki/ca.crt /etc/openvpn/server/keys/ca.crt
		cp ./pki/issued/antizapret-server.crt /etc/openvpn/server/keys/antizapret-server.crt
		cp ./pki/private/antizapret-server.key /etc/openvpn/server/keys/antizapret-server.key
		cp ./pki/crl.pem /etc/openvpn/server/keys/crl.pem
	fi

	if [[ ! -f ./pki/issued/$CLIENT.crt ]] || \
	   [[ ! -f ./pki/private/$CLIENT.key ]]; then
		CLIENT_CERT_EXPIRE=$3
		if ! [[ "$CLIENT_CERT_EXPIRE" =~ ^[0-9]+$ ]] || (( CLIENT_CERT_EXPIRE <= 0 )) || (( CLIENT_CERT_EXPIRE > 3650 )); then
			echo ""
			echo "Enter a valid client certificate expiration period (1 to 3650 days)"
			until [[ "$CLIENT_CERT_EXPIRE" =~ ^[0-9]+$ ]] && (( CLIENT_CERT_EXPIRE > 0 )) && (( CLIENT_CERT_EXPIRE <= 3650 )); do
				read -rp "Certificate expiration days (1-3650): " -e -i 3650 CLIENT_CERT_EXPIRE
			done
		fi
		EASYRSA_CERT_EXPIRE=3650 /usr/share/easy-rsa/easyrsa --batch build-client-full $CLIENT nopass
		cp ./pki/issued/$CLIENT.crt /etc/openvpn/client/keys/$CLIENT.crt
		cp ./pki/private/$CLIENT.key /etc/openvpn/client/keys/$CLIENT.key
	else
		echo "A client with the specified name was already created, please choose another name"
	fi

	if [[ ! -f /etc/openvpn/client/keys/$CLIENT.crt ]] || \
	   [[ ! -f /etc/openvpn/client/keys/$CLIENT.key ]]; then
		cp ./pki/issued/$CLIENT.crt /etc/openvpn/client/keys/$CLIENT.crt
		cp ./pki/private/$CLIENT.key /etc/openvpn/client/keys/$CLIENT.key
	fi

	load_key
	FILE_NAME="${NAME}-${SERVER_IP}"
    mkdir -p "/root/vpn/${NAME}"

    render "/etc/openvpn/client/templates/antizapret.conf" > "/root/vpn/${NAME}/AZ-U+T-$(date +'%d-%m-%y').ovpn"

    render "/etc/openvpn/client/templates/vpn.conf" > "/root/vpn/${NAME}/GL-U+T-$(date +'%d-%m-%y').ovpn"

	echo "OpenVPN configuration files for the client '$CLIENT' have been (re)created in '/root/vpn'"

# WireGuard/AmneziaWG
elif [[ "$TYPE" == "wg" || "$TYPE" == "2" ]]; then

	IPS=$(cat /etc/wireguard/ips)
	if [[ ! -f /etc/wireguard/key ]]; then
		PRIVATE_KEY=$(wg genkey)
		PUBLIC_KEY=$(echo "${PRIVATE_KEY}" | wg pubkey)
		echo "PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}" > /etc/wireguard/key
		render "/etc/wireguard/templates/antizapret.conf" > "/etc/wireguard/antizapret.conf"
		render "/etc/wireguard/templates/vpn.conf" > "/etc/wireguard/vpn.conf"
	else
		source /etc/wireguard/key
	fi

	CLIENT_BLOCK_ANTIZAPRET=$(sed -n "/^# Client = ${CLIENT}\$/,/^AllowedIPs/ {p; /^AllowedIPs/q}" /etc/wireguard/antizapret.conf)
	CLIENT_BLOCK_VPN=$(sed -n "/^# Client = ${CLIENT}\$/,/^AllowedIPs/ {p; /^AllowedIPs/q}" /etc/wireguard/vpn.conf)

	if [[ -n "$CLIENT_BLOCK_ANTIZAPRET" ]]; then
		CLIENT_PRIVATE_KEY=$(echo "$CLIENT_BLOCK_ANTIZAPRET" | grep '# PrivateKey =' | cut -d '=' -f 2- | sed 's/ //g')
		CLIENT_PUBLIC_KEY=$(echo "$CLIENT_BLOCK_ANTIZAPRET" | grep 'PublicKey =' | cut -d '=' -f 2- | sed 's/ //g')
		CLIENT_PRESHARED_KEY=$(echo "$CLIENT_BLOCK_ANTIZAPRET" | grep 'PresharedKey =' | cut -d '=' -f 2- | sed 's/ //g')
		echo "A client with the specified name was already created, please choose another name"
	elif [[ -n "$CLIENT_BLOCK_VPN" ]]; then
		CLIENT_PRIVATE_KEY=$(echo "$CLIENT_BLOCK_VPN" | grep '# PrivateKey =' | cut -d '=' -f 2- | sed 's/ //g')
		CLIENT_PUBLIC_KEY=$(echo "$CLIENT_BLOCK_VPN" | grep 'PublicKey =' | cut -d '=' -f 2- | sed 's/ //g')
		CLIENT_PRESHARED_KEY=$(echo "$CLIENT_BLOCK_VPN" | grep 'PresharedKey =' | cut -d '=' -f 2- | sed 's/ //g')
		echo "A client with the specified name was already created, please choose another name"
	else
		CLIENT_PRIVATE_KEY=$(wg genkey)
		CLIENT_PUBLIC_KEY=$(echo "${CLIENT_PRIVATE_KEY}" | wg pubkey)
		CLIENT_PRESHARED_KEY=$(wg genpsk)
	fi

	sed -i "/^# Client = ${CLIENT}\$/,/^AllowedIPs/d" /etc/wireguard/antizapret.conf
	sed -i "/^# Client = ${CLIENT}\$/,/^AllowedIPs/d" /etc/wireguard/vpn.conf

	sed -i '/^$/N;/^\n$/D' /etc/wireguard/antizapret.conf
	sed -i '/^$/N;/^\n$/D' /etc/wireguard/vpn.conf

	# AntiZapret

	BASE_CLIENT_IP=$(grep "^Address" /etc/wireguard/antizapret.conf | sed 's/.*= *//' | cut -d'.' -f1-3 | head -n 1)

	for i in {2..255}; do
		CLIENT_IP="${BASE_CLIENT_IP}.$i"
		if ! grep -q "$CLIENT_IP" /etc/wireguard/antizapret.conf; then
			break
		fi
		if [[ $i == 255 ]]; then
			echo "The WireGuard/AmneziaWG subnet can support only 253 clients"
			exit 22
		fi
	done

	CLIENT_CERT_EXPIRE=$3
	FILE_NAME="${NAME}-${SERVER_IP}"
	FILE_NAME="${FILE_NAME:0:18}"
    mkdir -p "/root/vpn/${NAME}"
	render "/etc/wireguard/templates/antizapret-client-wg.conf" > "/root/vpn/${NAME}/AZ-WG-$(date +'%d-%m-%y').conf"
    render "/etc/wireguard/templates/antizapret-client-am.conf" > "/root/vpn/${NAME}/AZ-AM-$(date +'%d-%m-%y').conf"


	echo "# Client = ${CLIENT}
# PrivateKey = ${CLIENT_PRIVATE_KEY}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32
" >> "/etc/wireguard/antizapret.conf"

	if systemctl is-active --quiet wg-quick@antizapret; then
		wg syncconf antizapret <(wg-quick strip antizapret 2>/dev/null)
	fi

	# VPN

	BASE_CLIENT_IP=$(grep "^Address" /etc/wireguard/vpn.conf | sed 's/.*= *//' | cut -d'.' -f1-3 | head -n 1)

	for i in {2..255}; do
		CLIENT_IP="${BASE_CLIENT_IP}.$i"
		if ! grep -q "$CLIENT_IP" /etc/wireguard/vpn.conf; then
			break
		fi
		if [[ $i == 255 ]]; then
			echo "The WireGuard/AmneziaWG subnet can support only 253 clients"
			exit 23
		fi
	done

	FILE_NAME="${NAME}-${SERVER_IP}"
	FILE_NAME="${FILE_NAME:0:25}"
	mkdir -p "/root/vpn/${NAME}"
	render "/etc/wireguard/templates/vpn-client-wg.conf" > "/root/vpn/${NAME}/GL-WG-$(date +'%d-%m-%y').conf"
	render "/etc/wireguard/templates/vpn-client-am.conf" > "/root/vpn/${NAME}/GL-AM-$(date +'%d-%m-%y').conf"

	echo "# Client = ${CLIENT}
# PrivateKey = ${CLIENT_PRIVATE_KEY}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32
" >> "/etc/wireguard/vpn.conf"

	if systemctl is-active --quiet wg-quick@vpn; then
		wg syncconf vpn <(wg-quick strip vpn 2>/dev/null)
	fi

	echo "WireGuard/AmneziaWG configuration files for the client '$CLIENT' have been (re)created in '/root/vpn'"

# Init/Recreate
elif [[ "$TYPE" == "init" || "$TYPE" == "recreate" ]]; then

	mv -f /root/vpn/*.* /root/vpn/old &>/dev/null || true

	# OpenVPN
	if [[ -f /etc/openvpn/easyrsa3/pki/index.txt ]]; then
		tail -n +2 /etc/openvpn/easyrsa3/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sort -u | while read -r line; do
			if [[ "$line" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
				/root/add-client.sh ov "$line" >/dev/null
				echo "OpenVPN configuration files for the client '$line' have been recreated in '/root/vpn'"
			else
				echo "Client name '$line' format is invalid"
			fi
		done
	elif [[ "$TYPE" == "init" ]]; then
		/root/add-client.sh ov antizapret-client 3650
	fi

	# WireGuard/AmneziaWG
	if [[ -f /etc/wireguard/antizapret.conf && -f /etc/wireguard/vpn.conf ]]; then
		cat /etc/wireguard/antizapret.conf /etc/wireguard/vpn.conf | grep -E "^# Client" | cut -d '=' -f 2 | sed 's/ //g' | sort -u | while read -r line; do
			if [[ "$line" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
				/root/add-client.sh wg "$line" >/dev/null
				echo "WireGuard/AmneziaWG configuration files for the client '$line' have been recreated in '/root/vpn'"
			else
				echo "Client name '$line' format is invalid"
			fi
		done
	elif [[ "$TYPE" == "init" ]]; then
		/root/add-client.sh wg antizapret-client
	fi

# List
elif [[ "$TYPE" == "list" ]]; then

	echo ""
	echo "OpenVPN existing client names:"
	tail -n +2 /etc/openvpn/easyrsa3/pki/index.txt | grep "^V" | cut -d '=' -f 2
	echo ""
	echo "WireGuard/AmneziaWG existing client names:"
	cat /etc/wireguard/antizapret.conf /etc/wireguard/vpn.conf | grep -E "^# Client" | cut -d '=' -f 2 | sed 's/ //g' | sort -u
	echo ""

fi
