#!/usr/bin/env sh

# 一个基于 DNSPod API v3 的 DDNS Shell 脚本 
# A DDNS Shell script based on DNSPod API v3
#
# https://github.com/qingzi-zhang/ddnss.sh
#
# Copyright (c) 2024 Ken <qingzi dot zhang at outlook dot com>
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
#
# DNSPod API v3 documentation at https://cloud.tencent.com/document/api/1427

# 配置文件格式说明 / Configuration file format:
# Tencent_SecretId=your_secret_id   # DNSPod API 密钥ID / API Secret ID
# Tencent_SecretKey=your_secret_key # DNSPod API 密钥Key / API Secret Key
# DNS_Server=8.8.8.8                # DNS服务器(可选) / DNS Server (optional)
# Log_File=/var/log/ddnss/ddnss.log # 日志文件路径 / Log file path
#
# DDNS记录格式 / DDNS record format:
# DDNS=domain_full_name, ip_version, interface, eui64_suffix
# 示例 / Example:
# DDNS=test.example.com,ipv4,eth0
# DDNS=test.example.com,ipv6,eth0,1:2:3:4

# 全局变量 / Global variables
AGENT="A DDNS Shell script/v24.12.0-rc5 (404919@qq.com)"
TAG="ddns-shell"

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

_DIR="${HOME}/.ddnss.sh"
DEFAULT_CFG_FILE="${_DIR}/ddnss.conf"
DEFAULT_DNS_SERVER="8.8.8.8"
DEFAULT_LOG_FILE="/var/log/ddnss/ddnss.log"
DEFAULT_LOG_LEVEL="${LOG_LEVEL_ERROR}"

config_file="${DEFAULT_CFG_FILE}"
force_update=0
log_file="${DEFAULT_LOG_FILE}"
log_level="${DEFAULT_LOG_LEVEL}"

algorithm="TC3-HMAC-SHA256"
host="dnspod.tencentcloudapi.com"
service="dnspod"
version="2021-03-23"

# 显示帮助信息 / Show help message
show_help() {
  echo "Usage:
  $(basename "$0") [options]

Options:
  -h, --help           Print this help message
  --config=<file>      Read config from a file
  --force-update       Proceed with the update regardless of IP status
  --log-level=<0|1>    Set the log level to 0 or 1 (0: Error, 1: Verbose)"
}

# 写入日志文件 / Write to log file
# $1: 动作 / Action
# $2: API名称 / API name  
# $3: 消息内容 / Message content
log_to_file() {
  # Validate the arguments action ($1), API ($2) and message ($3)
  if [ -z "$1" ] || [ -z "$2" ] ||  [ -z "$3" ]; then
    echo "Error: [log_to_file] Missing one or more required arguments."
    return 1
  fi

  if [ ! -f "${log_file}" ]; then
    logger -p crit -s -t "${TAG}" \
      "[Critical Error] The Log file '${log_file}' unexpectedly missing after init_config"
    return 2
  fi

  # Rotate log file if size exceeds limit
  log_file_size="$(du -b "${log_file}" | cut -f1)"
  if [ "${log_file_size}" -gt "${LOG_SIZE}" ]; then
    mv -f "${log_file}" "${log_file}".bak
  fi

  # Set the log_time to ISO 8601 format
  log_time="$(date "+GMT %z %Z %Y-%m-%d %H:%M:%S")"

  # Log to file as JSON format
  printf -- '{"%s":"%s","%s":%s}\n' "${log_time}" "$1" "$2" "$3" >> "${log_file}"
}

# 获取网络接口IP地址 / Get IP address from network interface
get_ip_interface() {
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
    logger -p err -s -t "${TAG}" "${domain_full_name} interface '${interface}' ${ip_version} address extraction failed or address blocks reserved"
    return 1
  fi

  # Adds specific IPv6 EUI-64 suffix if defined
  if [ -n "${eui64_suffix}" ] && echo "${ip_address}" | grep -q "::" ; then
    ip_address="${ip_address%::*}:${eui64_suffix}"
  fi
  # Validate IP address length
  if [ ${#ip_address} -gt 39 ]; then
    logger -p err -s -t "${TAG}" "${domain_full_name} interface '${interface}' ${ip_version} address '${ip_address}' exceeds the length limit"
    return 1
  fi
}

# 通过nslookup查询DNS记录 / Query DNS record via nslookup
get_ip_nslookup() {
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
    logger -p err -s -t "${TAG}" "${domain_full_name} ${record_type} [nslookup]: IP address extraction failed"
    return 1
  fi
}

# 生成API签名 / Generate API signature
tc3_signature() {
  # Function to calculate the openssl HMAC-SHA256 hash of a string with a secret key
  tc3_hmac_sha256() {
    printf -- "%b" "$1" | openssl dgst -sha256 -mac hmac -macopt hexkey:"$2" | awk '{print $2}'
  }

  # Function to calculate the openssl SHA256 hash of a string
  tc3_sha256() {
    printf -- "%b" "$1" | openssl sha256 -hex | awk '{print $2}'
  }

  # Concatenate the canonical request string
  canonical_uri="/"
  canonical_querystring=""
  canonical_headers="content-type:application/json; charset=utf-8\nhost:${host}\nx-tc-action:$(echo "${action}" | awk '{print tolower($0)}')\n"
  signed_headers="content-type;host;x-tc-action"
  hashed_request_payload=$(tc3_sha256 "${payload}")
  canonical_request="${http_request_method}\n${canonical_uri}\n${canonical_querystring}\n${canonical_headers}\n${signed_headers}\n${hashed_request_payload}"

  # Concatenate the string to be signed
  credential_scope="${date}/${service}/tc3_request"
  hashed_canonical_request=$(tc3_sha256 "${canonical_request}")
  string_to_sign="$algorithm\n${timestamp}\n${credential_scope}\n${hashed_canonical_request}"

  # Calculate the signature
  secret_date=$(printf -- "%b" "${date}" | openssl sha256 -hmac "TC3${secret_key}" | awk '{print $2}')
  secret_service=$(tc3_hmac_sha256 "${service}" "${secret_date}")
  secret_signing=$(tc3_hmac_sha256 "tc3_request" "${secret_service}")
  signature=$(tc3_hmac_sha256 "${string_to_sign}" "${secret_signing}")

  # Concatenate the authorization
  authorization="$algorithm Credential=${secret_id}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"
}

# 处理API错误 / Handle API error response
tc3_api_err() {
  # Extract the error code
  err_code="$(echo "${response}" | sed -n 's/.*"Code":"\([^"]\+\)".*/\1/p')"
  if [ -n "${err_code}" ]; then
    # Extract the error message
    err_msg="$(echo "${response}" | sed -n 's/.*"Message":"\([^"]\+\)".*/\1/p')"
    logger -p err -s -t "${TAG}" "${domain_full_name} ${record_type} [${action}]: ${err_code}, ${err_msg}"
    return 1
  fi
}

# 发送API请求 / Send API request
tc3_api_req() {
  timestamp="$(date +%s)"
  date="$(date -u -d "@$timestamp" +%Y-%m-%d 2>/dev/null)"
  http_request_method="POST"
  tc3_signature
  log_to_file "REQ" "$action" "{\"Request\":${payload}}"
  response=$(curl -A "{$AGENT}" \
    -X "${http_request_method}" "https://${host}" \
    -d "${payload}" \
    -H "Host: ${host}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -H "Authorization: ${authorization}" \
    -H "X-TC-Action: ${action}" \
    -H "X-TC-Timestamp: ${timestamp}" \
    -H "X-TC-Version: ${version}")
  # X-TC-Region: Common Params. This parameter is not required for this API. (optional)
  # -H "X-TC-Region: $region"
  log_to_file "ACK" "$action" "${response}"
  return $?
}

# 创建新DNS记录 / Create new DNS record
insert_record() {
  action="CreateRecord"
  payload="$(printf -- '{"Domain":"%s","SubDomain":"%s","RecordType":"%s","RecordLine":"%s","Value":"%s"}' \
    "${domain}" "${subdomain}" "${record_type}" "${record_line}" "${ip_address}")"
}

# 查询DNS记录 / Query DNS record
query_record() {
  action="DescribeRecordList"
  payload="$(printf -- '{"Domain":"%s","Subdomain":"%s","RecordType":"%s"}' \
    "${domain}" "${subdomain}" "${record_type}")"
}

# 更新DNS记录 / Update DNS record
update_record() {
  action="ModifyDynamicDNS"
  payload="$(printf -- '{"Domain":"%s","RecordId":%d,"RecordLine":"%s","Value":"%s","SubDomain":"%s"}' \
    "${domain}" "${record_id}" "${record_line}" "${ip_address}" "${subdomain}")"
}

# 处理单条DDNS记录 / Handle single DDNS record
handle_record() {
  record_line="默认"

  get_ip_interface || return 1

  # Create the DDNS record if it does not exist (DNSPod API: CreateRecord)
  get_ip_nslookup || {
    insert_record
    tc3_api_req
    tc3_api_err || return 1
    logger -p notice -s -t "${TAG}" "${domain_full_name} ${ip_version} ${ip_address} [CreateRecord] successfully"
    return 0
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

  # Get the DDNS record information (DNSPod API: DescribeRecordList)
  query_record
  tc3_api_req
  tc3_api_err || return 1

  # Extract RecordId and IP address
  record_id="$(echo "${response}" | sed 's/.*"RecordId":\([0-9]\+\).*/\1/')"
  record_ip="$(echo "${response}" | sed 's/.*"Value":"\([0-9a-fA-F.:]\+\)".*/\1/')"

  if [ -z "${record_id}" ] || [ -z "${record_ip}" ]; then
    logger -p err -s -t "${TAG}" "Fail attempt to extract RecordId or IP address for ${domain_full_name} ${record_type} from DNSPod API response"
    return 1
  fi

  # If the IP address is up to date here, it means the local DNS cache is out of date
  if [ "${ip_address}" = "${record_ip}" ]; then
    [ "${log_level}" -lt "${LOG_LEVEL_ERROR}" ] || logger -p info -s -t "${TAG}" "${domain_full_name} cache of ${ip_version} address ${ip_address} is up to date"
    # Skip when a force-update is not enabled (The IP address cache is already up to date)
    [ "$force_update" -eq 1 ] || return 0
  fi

  # Update the DDNS record IP address (DNSPod API: ModifyDynamicDNS)
  update_record
  tc3_api_req
  tc3_api_err || 1
  logger -p notice -s -t "${TAG}" "${domain_full_name} ${ip_version} address has been updated to ${ip_address}"
}

# 处理所有DDNS记录 / Process all DDNS records
proc_ddns_rec() {
  # Function to extract the field from a DDNS record
  # Usage: get_ddns_field field_number of a record and translate to lower case
  get_ddns_field() {
    echo "${record}" | awk -F ',' '{print tolower($'"$1"')}'
  }

  # Process each DDNS record found in the config file
  # Record format: DDNS=domain_full_name, ip_version, interface, eui64_suffix
  grep "^DDNS" "${config_file}" | while IFS= read -r record; do
    # Remove all horizontal or vertical whitespace and 'DDNS=' prefix
    record="$(printf -- '%s' "${record}" | sed 's/\s+//g; s/^DDNS=//')"

    # Skip empty records
    [ -z "${record}" ] && continue

    # Extract DDNS fields
    domain_full_name="$(get_ddns_field 1)"
    ip_version="$(get_ddns_field 2)"
    interface="$(get_ddns_field 3)"
    eui64_suffix="$(get_ddns_field 4)"

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

    # Synchronize the DDNS record
    handle_record || continue
  done
}

# 初始化配置 / Initialize configuration
init_config() {
  # Exit if the configuration file is invalid
  if [ ! -f "${config_file}" ]; then
    logger -p err -s -t "${TAG}" "Invalid configuration file '${config_file}'"
    return 1
  fi

  # Exit if no DDNS records found
  if ! grep -q "^DDNS" "${config_file}" ; then
    logger -p err -s -t "${TAG}" "No DDNS records in '${config_file}'"
    return 1
  fi

  # Exit if log level is valid
  if ! echo "${log_level}" | grep -q "^[01]$" ; then
    logger -p err -s -t "${TAG}" "Invalid log level '${log_level}', Use 0 (Error) or 1 (Verbose)."
    return 1
  fi

  # Function to extract the value of a configuration field from a file
  # Usage: get_config <value> by <key>
  # Config format: key=value
  get_config() {
    awk -F '=' -v key="$1" 'tolower($1) == tolower(key) {print $2}' "${config_file}" | sed 's/"//g; s/\s//g'
  }

  secret_id="$(get_config Tencent_SecretId)"
  secret_key="$(get_config Tencent_SecretKey)"
  # Exit if the API credentials are missing
  if [ -z "${secret_id}" ] || [ -z "${secret_key}" ]; then
    logger -p err -s -t "${TAG}" "DNSPod API credentials fields 'Tencent_SecretId' or 'Tencent_SecretKey' are missing in '${config_file}'"
    return 1
  fi

  # Set dns server as default for lookup a DDNS record if not specified in the config file
  dns_server="$(get_config DNS_Server)"
  dns_server="${dns_server:-"${DEFAULT_DNS_SERVER}"}"

  log_file="$(get_config Log_File)"
  if [ -z "${log_file}" ]; then
    log_file="${DEFAULT_LOG_FILE}"
    logger -p warning -s -t "${TAG}" "Missing 'Log_File' field in '${config_file}', using default '${DEFAULT_LOG_FILE}'"
  fi

  if [ "${#log_file}" -lt 10 ] || [ "$(echo "${log_file}" | cut -c 1-9)" != "/var/log/" ]; then
    logger -p err -s -t "${TAG}" "The log file '${log_file}' is either a directory or not within '/var/log/'"
    return 1
  fi

  # Validate log file permissions
  [ -w "${log_file}" ] && return 0

  # Attempt to create the log file if it does not exist
  umask 0077
  mkdir -p "$(dirname "${log_file}")"
  touch "${log_file}.bak" >/dev/null 2>&1
  touch "${log_file}" >/dev/null 2>&1

  if [ ! -f "${log_file}" ]; then
      logger -p err -s -t "${TAG}" "Failed to create the log file '${log_file}'"
      return 126
  fi

  if [ ! -w "${log_file}.bak" ]; then
    logger -p err -s -t "${TAG}" "The log backup file '${log_file}.bak' is not writable"
    return 126
  fi

  logger -p info -s -t "${TAG}" "The log file '${log_file}' was successfully created"
}

# 解析命令行参数 / Parse command line options
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

  if [ "${force_update}" -eq 1 ] && [ "${log_level}" -eq "${LOG_LEVEL_VERBOSE}" ]; then
    logger -p info -s -t "${TAG}" "Processing with force update is enabled"
  fi
}

# 主函数 / Main function
main() {
  parse_opt "$@" || return 1
  init_config    || return 1
  proc_ddns_rec  || return 1
}

main "$@"
