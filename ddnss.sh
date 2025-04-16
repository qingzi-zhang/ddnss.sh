#!/usr/bin/env sh
#
#           A DDNS Shell script
# https://github.com/qingzi-zhang/ddnss.sh
#
# Copyright (c) 2024-2025 Ken <qingzi dot zhang at outlook dot com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

AGENT="A DDNS Shell script/25.01.06-rc3 (qingzi.zhang@outlook.com)"
ENTRY="ddnss.sh"
TAG="ddnss"

_HOME="${HOME}/.ddnss.sh"

if ! command -v curl >/dev/null 2>&1 ; then
  logger -p err -s -t "${TAG}" "The script requires cURL support. Please install it."
  exit 127
fi

if ! command -v openssl >/dev/null 2>&1 ; then
  logger -p err -s -t "${TAG}" "The script requires openssl-util support. Please install it."
  exit 127
fi

LOG_LEVEL_ERROR=0
LOG_LEVEL_VERBOSE=1
LOG_SIZE=1000000 # Bytes

DEFAULT_CFG_FILE="${_HOME}/config/ddnss.conf"
DEFAULT_DNS_SERVER="8.8.8.8"
DEFAULT_LOG_LEVEL="${LOG_LEVEL_ERROR}"
DEFAULT_LOG_PATH="/var/log/ddnss/"

DNSAPI_PATH="${_HOME}/dnsapi"

config_file="${DEFAULT_CFG_FILE}"
force_update=0
log_level="${DEFAULT_LOG_LEVEL}"
log_path="${DEFAULT_LOG_PATH}"

get_ip_from_interface() {
  if [ "${record_type}" = "A" ]; then
    # https://www.iana.org/assignments/iana-ipv4-special-registry/iana-ipv4-special-registry.xhtml

    # [RFC791] "This network" 0.0.0.0/8
    ip4_filter="^0\."
    # [RFC1122] "This host on this network" 127.0.0.0/8
    ip4_filter="${ip4_filter}|^127\."
    # [RFC6598] Shared Address Space 100.64.0.0/10
    ip4_filter="${ip4_filter}|^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7]\.)"
    # [RFC3927] Link Local 169.254.0.0/16
    ip4_filter="${ip4_filter}|^169\.254\."
    # [RFC1918] Private-Use 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
    ip4_filter="${ip4_filter}|^10\."
    ip4_filter="${ip4_filter}|^172\.(1[6-9]|2[0-9]|3[01]\.)"
    ip4_filter="${ip4_filter}|^192\.168\."
    # [RFC1112] Reserved Address Block 240.0.0.0/4
    ip4_filter="${ip4_filter}|^240\."
    # [RFC2544] Benchmarking Address Blocks 198.18.0.0/15
    ip4_filter="${ip4_filter}|^198\.1[8-9]\."
    # [RFC5737] IPv4 Address Blocks Reserved for Documentation 198.51.100.0/24, 203.0.113.0/24
    ip4_filter="${ip4_filter}|^198\.51\.100\.|^203\.0\.113\."

    # Extract and filter IPv4 address from the specific interface
    ip_address="$(ip -4 address show dev "${interface}" \
      | sed -n 's/.*inet \([0-9.]\+\).\+scope global.*/\1/p'\
      | grep -Ev "${ip4_filter}")"
  else
    # https://www.iana.org/assignments/iana-ipv6-special-registry/iana-ipv6-special-registry.xhtml

    # [RFC4291] Unspecified Address ::/128
    ip6_filter="^::$"
    # [RFC4291] Loopback Address ::1/128
    ip6_filter="${ip6_filter}|^::1$"
    # [RFC4193][RFC8190] Unique-Local fc00::/7
    ip6_filter="${ip6_filter}|^[fF][cdCD][0-9a-fA-F]{2}:"
    # [RFC4291] Link-Local Unicast fe80::/10
    ip6_filter="${ip6_filter}|^[fF][eE][8-9a-bA-B][0-9a-fA-F]:"

    # An imprecise simplified algorithm is used here for performance reasons
    # It may not handle all edge cases but is sufficient for the majority of scenarios
    # [RFC5180][RFC Errata 1752] Benchmarking 2001:2::/48
    ip6_filter="${ip6_filter}|^2001:2:"
    # [RFC6052] IPv4-IPv6 Translat 64:ff9b::/96
    # [RFC8215] IPv4-IPv6 Translat 64:ff9b:1::/48
    ip6_filter="${ip6_filter}|^64:[fF][fF]9[bB]:"
    # [RFC6666] Discard-Only Address Block 100::/64
    ip6_filter="${ip6_filter}|^100::"

    # Extract and filter IPv6 address from the specific interface
    ip_address="$(ip -6 address show dev "${interface}" \
      | sed -n 's/.*inet6 \([0-9a-fA-F:]\+\)\/64 scope global dynamic.*/\1/p' \
      | grep -Ev "${ip6_filter}" \
      | head -n 1)"
  fi

  # Validate IP address extraction
  if [ -z "${ip_address}" ]; then
    logger -p err -s -t "${TAG}" \
      "${domain_full_name} interface '${interface}' ${ip_version} address extraction failed or address blocks reserved"
    return 1
  fi

  # Adds specific IPv6 EUI-64 suffix if defined
  if [ -n "${eui64_suffix}" ] && echo "${ip_address}" | grep -q "::" ; then
    ip_address="${ip_address%::*}:${eui64_suffix}"
  fi

  # Validate IP address length
  if [ ${#ip_address} -gt 39 ]; then
    logger -p err -s -t "${TAG}" \
      "${domain_full_name} interface '${interface}' ${ip_version} address '${ip_address}' exceeds the length limit"
    return 1
  fi
}

get_ip_from_nslookup() {
  # Retrieve DNS records via nslookup
  response="$(nslookup -type="${record_type}" "${domain_full_name}" "${dns_server}")"

  # Check for error indicator in the result
  if echo "${response}" | grep -q "\*\*" ; then
    # Extract error message
    err_msg="$(echo "${response}" | grep '\*')"
    logger -p err -s -t "${TAG}" "${domain_full_name} ${record_type} [nslookup]: ${err_msg}"
    return 1
  fi

  # Extract IP address from the result
  ns_ip_address="$(echo "${response}" | sed -n 's/.*Address: \([0-9a-fA-F.:]\+\).*/\1/p')"

  # Validate the IP address extraction
  if [ -z "${ns_ip_address}" ]; then
    logger -p err -s -t "${TAG}" "${domain_full_name} ${record_type}" \
      "[nslookup]: IP address extraction failed"
    return 1
  fi
}

handle_record() {
  # Retrieve the ip address from the specified network interface
  get_ip_from_interface || return 1
  # Retrieve the ip address from the DNS server
  get_ip_from_nslookup  || {
    # Attempt to insert the DDNS record if it does not already exist
    . "${update_script}" "insert"
    return $?
  }

  if [ "${ip_address}" = "${ns_ip_address}" ]; then
    if [ "${log_level}" -eq "${LOG_LEVEL_VERBOSE}" ]; then
      logger -p info -s -t "${TAG}" "${domain_full_name} ${ip_version} address ${ip_address} is up to date"
    else
      echo "${domain_full_name} ${ip_version} address ${ip_address} is up to date"
    fi
    # Skip if force-update option is not enabled (The IP address is already the latest)
    [ "$force_update" -ne 0 ] || return 0
  fi

  # Update the DDNS record via specified DNS API
  . "${update_script}"
}

init_config() {
  if [ ! -f "${config_file}" ]; then
    logger -p err -s -t "${TAG}" "Invalid configuration file '${config_file}'"
    return 1
  fi

  if ! grep -q "^DDNS" "${config_file}" ; then
    logger -p err -s -t "${TAG}" "No DDNS records in '${config_file}'"
    return 1
  fi

  # Validate the log level
  if ! echo "${log_level}" | grep -q "^[01]$" ; then
    logger -p err -s -t "${TAG}" "Invalid log level '${log_level}', Use 0 (Error) or 1 (Verbose)."
    return 1
  fi

  # Function to extract the value of a configuration field from a file
  # Usage: get_config <value> by <key>
  # format: key=value
  get_config() {
    awk -F '=' -v key="$1" 'tolower($1) == tolower(key) {print $2}' "${config_file}" | sed 's/"//g; s/\s//g'
  }

  # Set dns server as default for lookup a DDNS record if not specified in the config file
  dns_server="$(get_config DNS_Server)"
  dns_server="${dns_server:-"${DEFAULT_DNS_SERVER}"}"

  if [ "${force_update}" -eq 1 ] \
    && [ "${log_level}" -eq "${LOG_LEVEL_VERBOSE}" ]; then
    logger -p info -s -t "${TAG}" "Processing with force update is enabled"
  fi
}

install() {
  echo "Installing to ${_HOME} ..."
  if [ "$(uname -s)" != "Linux" ]; then
    echo "This script is intended to run on Linux only."
    return 1
  fi

  if [ -f "${_HOME}/${ENTRY}" ]; then
    echo "${ENTRY} is already installed."
    return 1
  fi

  uid="$(id -u)"
  gid="$(id -g)"
  umask 0077

  if [ ! -d "${_HOME}" ] || [ ! -d "${_HOME}/config" ] || [ ! -d "${_HOME}/dnsapi" ]; then
    echo "Creating the home directory '${_HOME}'"
    mkdir -p "${_HOME}/config"
    mkdir -p "${_HOME}/dnsapi"

    [ -d "${_HOME}" ] || {
      echo "Error: Failed to create the home directory '${_HOME}'"
      return 1
    }
  fi

  if [ ! -d "${log_path}" ]; then
    echo "Creating the log directory '${log_path}'"
    sudo_cmd="$(command -v sudo)"
    $sudo_cmd mkdir -p "${log_path}"
    $sudo_cmd chown -R "${uid}:${gid}" "${log_path}"
    [ -d "${log_path}" ] || {
      echo "Error: Failed to create the log directory '${log_path}'"
      return 1
    }
  fi

  if [ ! -w "${_HOME}" ] || [ ! -w "${log_path}" ]; then
    echo "Error: The home directory '${_HOME}' or the log directory '${log_path}' has no write permission."
    return 1
  fi

  echo "Copying files to current system"
  cp "${ENTRY}" "${_HOME}/" >/dev/null 2>&1
  chmod +x "${_HOME}/${ENTRY}" >/dev/null 2>&1

  if [ -f "${_HOME}/config/ddnss.conf" ]; then
    cp config/ddnss.conf "${_HOME}/config/ddnss.default-conf" >/dev/null 2>&1
    echo "The config file '${_HOME}/config/ddnss.conf' exists, The new config file has been copied to '${_HOME}/config/ddnss.default-conf'"
  else
    cp config/ddnss.conf "${_HOME}/config/" >/dev/null 2>&1
  fi

  cp dnsapi/*.sh "${DNSAPI_PATH}/" >/dev/null 2>&1

  sha256sum_info="$(grep 'ddnss.sh' sha256sum | cut -d ' ' -f 1)"
  file_checksums="$(sha256sum "${_HOME}/${ENTRY}" | cut -d ' ' -f 1)"
  [ "${sha256sum_info}" = "${file_checksums}" ] || {
    echo "Error: The SHA256 checksum of the file '${_HOME}/${ENTRY}' mismatch the expected value."
    rm -f "${_HOME}/${ENTRY}"
    echo "Installation failed, removed the invalid file '${_HOME}/${ENTRY}'"
    return 1
  }

  for api_file in "${DNSAPI_PATH}/"*.sh; do
    sha256sum_info="$(grep "$(basename "${api_file}")" sha256sum | cut -d ' ' -f 1)"
    file_checksums="$(sha256sum "${api_file}" | cut -d ' ' -f 1)"
    [ "${sha256sum_info}" = "${file_checksums}" ] || {
      echo "Error: The SHA256 checksum of the file '${api_file}' mismatch the expected value."
      rm -f "${api_file}"
      echo "Installation failed, removed the invalid file '${api_file}'"
      continue
    }
  done

  echo "Installation accomplished, Please modify the configuration file '${_HOME}/config/ddnss.conf' to suit your domain name."
}

log_to_file() {
  # Validate the arguments action ($1), API ($2) and message ($3)
  if [ -z "$1" ] || [ -z "$2" ] ||  [ -z "$3" ]; then
    echo "Error: [log_to_file] Missing one or more required arguments."
    return 1
  fi

  log_file="$(echo "${domain_full_name}" | sed 's/\./_/g')"
  log_file="${log_path}/${log_file}.log"

  if [ ! -f "${log_file}" ]; then
    # Attempt to create the log file if it does not exist
    umask 0077
    mkdir -p "$(dirname "${log_file}")"
    touch "${log_file}.bak" >/dev/null 2>&1
    touch "${log_file}" >/dev/null 2>&1
  fi

  if [ ! -f "${log_file}" ]; then
      logger -p err -s -t "${TAG}" "Failed to create the log file '${log_file}'"
      return 126
  fi

  if [ ! -w "${log_file}.bak" ]; then
    logger -p err -s -t "${TAG}" "The log backup file '${log_file}.bak' is not writable"
    return 126
  fi

  # Rotate log file if size exceeds limit
  log_file_size="$(du -b "${log_file}" | cut -f1)"
  if [ "${log_file_size}" -gt "${LOG_SIZE}" ]; then
    mv -f "${log_file}" "${log_file}".bak
  fi

  # Set the log_time to follow a format akin to ISO 8601
  log_time="$(date "+GMT %z %Z %Y-%m-%d %H:%M:%S")"

  printf -- '{"%s":"%s","%s":%s}\n' "${log_time}" "$1" "$2" "$3" >> "${log_file}"
}

parse_opt() {
  # Parse command line options
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        show_help
        return 1
        ;;
      --config=*)
        config_file="${1#*=}"
        shift
        ;;
      --force-update)
        force_update=1
        shift
        ;;
      --install)
        install
        exit $?
        ;;
      --log-level=*)
        log_level="${1#*=}"
        shift
        ;;
      *)
        echo "Unknown option: $1"
        show_help
        return 1
        ;;
    esac
  done
}

proc_ddns_rec() {
  # Function to extract the field from a DDNS record
  get_ddns_field() {
    echo "${record}" | awk -F ',' '{print $'"$1"'}'
  }

  grep "^DDNS" "${config_file}" | while IFS= read -r record; do
    # Remove all horizontal or vertical whitespace and 'DDNS=' prefix
    # DDNS=ai.ddns-shell.net,IPv6,br-lan,07e2:00c:0012:aaaa,dnspod,secret_id,secret_key
    record="$(printf -- '%s' "${record}" | sed 's/\s+//g; s/^DDNS=//')"

    # Skip empty records
    [ -z "${record}" ] && continue

    # Extract DDNS fields
    # DDNS=ai.ddns.sh, IPv6, pppoe-wan, 07e2:00c:0012:aaaa, 8.8.8.8, dnspod.sh, secret_id, secret_key
    domain_full_name="$(get_ddns_field 1)"
    ip_version="$(get_ddns_field 2)"
    interface="$(get_ddns_field 3)"
    update_script="$(get_ddns_field 4)"
    secret_id="$(get_ddns_field 5)"
    secret_key="$(get_ddns_field 6)"
    eui64_suffix="$(get_ddns_field 7)"

    # Skip record without domain name
    if [ -z "${domain_full_name}" ]; then
      logger -p notice -s -t "${TAG}" "Empty domain name in 'DDNS=${record}'"
      continue
    fi

    # Validate network interface
    if ! ip link ls dev "${interface}" >/dev/null 2>&1 ; then
      logger -p err -s -t "${TAG}" "${domain_full_name} interface '${interface}' is invalid not available"
      continue
    fi

    # Skip record with invalid domain name
    if ! echo "${domain_full_name}" | grep -q "\." ; then
      logger -p notice -s -t "${TAG}" "Invalid domain name '${domain_full_name}'"
      continue
    fi

    # Extract domain from domain name
    domain="$(echo "${domain_full_name}" | awk -F '.' '{print $(NF-1) "." $NF}')"

    # Skip record with invalid domain
    if [ -z "$(echo "${domain}" |  cut -d '.' -f 1)" ] \
      || [ -z "$(echo "${domain}" |  cut -d '.' -f 2)" ]; then
       logger -p notice -s -t "${TAG}" "Invalid domain '${domain}'"
       continue
    fi

    # Extract subdomain from domain name
    if [ "$(echo "$domain_full_name" | tr -cd '.' | wc -c)"  -gt 1 ]; then
      subdomain="$(echo "$domain_full_name" | sed "s/\.${domain}$//")"
    fi
    if [ "${subdomain}" = "@" ]; then
      subdomain=""
    fi

    # Set IP version to ipv6 if not specified
    ip_version="${ip_version:-ipv6}"
    # Set DDNS record type based on IP version
    case "${ip_version}" in
      "ipv4")
        record_type="A"
        ;;
      "ipv6")
        record_type="AAAA"
        ;;
      *)
        logger -p err -s -t "${TAG}" "Invalid IP version '${ip_version}' of ${domain_full_name}"
        # Skip record with invalid IP versions
        continue
        ;;
    esac
    ip_version="$(echo "${ip_version}" | sed 's/[iI][pP][vV]/IPv/')"

    # Validate the update script
    if [ -z "${update_script}" ]; then
      logger -p err -s -t "${TAG}" "Invalid update script '${update_script}'"
      continue
    fi
    update_script="${DNSAPI_PATH}/${update_script}"
    if [ ! -f "${update_script}" ]; then
      logger -p err -s -t "${TAG}" "No update script '${update_script}' found"
      continue
    fi

    # Validate the API credentials
    if [ -z "${secret_id}" ] || [ -z "${secret_key}" ]; then
      logger -p err -s -t "${TAG}" "API credentials fields 'SecretId' or 'SecretKey' are missing in '${config_file}'."
      return 1
    fi

    # handle the DDNS record
    handle_record || continue
  done
}

show_help() {
  echo "Usage:
  $(basename "$0") [options]

Options:
  -h, --help           Print this help message
  --config=<file>      Read config from a file
  --force-update       Proceed with the update regardless of IP status
  --install            Install the DDNS shell script to your system
  --log-level=<0|1>    Set the log level to 0 or 1 (0: Error, 1: Verbose)"
}

main() {
  parse_opt "$@" || return 1
  init_config    || return 1
  proc_ddns_rec  || return 1
}

main "$@"