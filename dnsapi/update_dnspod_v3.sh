#!/usr/bin/env sh
#
# script for sending updates to dnspod.tencentcloudapi.com
# 2025 Ken <qingzi dot zhang at outlook dot com>
# API v3 documentation at https://cloud.tencent.com/document/api/1427
#
# This script is called by ddnss.sh inside handle_record() function
# https://github.com/qingzi-zhang/ddnss.sh

algorithm="TC3-HMAC-SHA256"
host="dnspod.tencentcloudapi.com"
record_line="默认"
service="dnspod"
version="2021-03-23"

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

tc3_api_req() {
  timestamp="$(date +%s)"
  date="$(date -u -d "@$timestamp" +%Y-%m-%d 2>/dev/null)"
  http_request_method="POST"
  tc3_signature
  log_to_file "REQ" "$action" "{\"Request\":${payload}}"
  response=$(curl -A "${AGENT}" \
    -X "${http_request_method}" "https://${host}" \
    -d "${payload}" \
    -H "Host: ${host}" \
    -H "Content-Type: application/json; charset=utf-8" \
    -H "Authorization: ${authorization}" \
    -H "X-TC-Action: ${action}" \
    -H "X-TC-Timestamp: ${timestamp}" \
    -H "X-TC-Version: ${version}")
  # -H "X-TC-Region: $region"
  #     X-TC-Region: Common Params. This parameter is not required for this API. (optional)
  log_to_file "ACK" "$action" "${response}"
  return $?
}

# Function to prepare payload for creating a DNS record via DNSPod API
tc3_insert_record() {
  action="CreateRecord"
  payload="$(printf -- '{"Domain":"%s","SubDomain":"%s","RecordType":"%s","RecordLine":"%s","Value":"%s"}' \
    "${domain}" "${subdomain}" "${record_type}" "${record_line}" "${ip_address}")"
}

# Function to prepare payload for querying a DNS record via DNSPod API
tc3_query_record() {
  action="DescribeRecordList"
  payload="$(printf -- '{"Domain":"%s","Subdomain":"%s","RecordType":"%s"}' \
    "${domain}" "${subdomain}" "${record_type}")"
}

# Calculates the OpenSSL HMAC-SHA256 hash of a string with a secret key and generates an authorization header for a TC3-signed request
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

# Function to prepare payload for updating a DNS record via DNSPod API
tc3_update_record() {
  action="ModifyDynamicDNS"
  payload="$(printf -- '{"Domain":"%s","RecordId":%d,"RecordLine":"%s","Value":"%s","SubDomain":"%s"}' \
    "${domain}" "${record_id}" "${record_line}" "${ip_address}" "${subdomain}")"
}

main() {
  # Attempt to insert a new DNS record
  [ -z "${ddnss_insert_record}" ] || {
    tc3_insert_record
    tc3_api_req
    tc3_api_err || return 1
    logger -p notice -s -t "${TAG}" "${domain_full_name} ${ip_version} ${ip_address} [CreateRecord] successfully"
    return 0
  }

  # Get the DDNS record information
  tc3_query_record
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

  # Update the DDNS record IP address
  tc3_update_record
  tc3_api_req
  tc3_api_err || return 1
  logger -p notice -s -t "${TAG}" "${domain_full_name} ${ip_version} address has been updated to ${ip_address}"
}

main "$@"