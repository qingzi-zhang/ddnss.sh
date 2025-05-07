#!/usr/bin/env sh
#
# script for sending updates to https://cn-south-1.myhuaweicloud.com/v2/zones
# 2025 Ken <qingzi dot zhang at outlook dot com>
# API v2 documentation at https://support.huaweicloud.com/api-dns/dns_api_10000.html
#
# This script is called by ddnss.sh inside handle_record() function
# https://github.com/qingzi-zhang/ddnss.sh

algorithm="SDK-HMAC-SHA256"
host="dns.cn-south-1.myhuaweicloud.com"

hw_api_err() {
  # Extract the error code
  err_code="$(echo "${response}" | sed -n 's/.*error_code":"\([^"]\+\)".*/\1/p')"
  if [ -n "${err_code}" ]; then
    # Extract the error message
    err_msg="$(echo "${response}" | sed -n 's/.*"error_msg:"\([^"]\+\)".*/\1/p')"
    logger -p err -s -t "${TAG}" "${domain_full_name} ${record_type} [${action}]: ${err_code}, ${err_msg}"
    return 1
  fi

  # Extract the error code
  err_code="$(echo "${response}" | sed -n 's/.*code":"\([^"]\+\)".*/\1/p')"
  if [ -n "${err_code}" ]; then
    # Extract the error message
    err_msg="$(echo "${response}" | sed -n 's/.*"message:"\([^"]\+\)".*/\1/p')"
    logger -p err -s -t "${TAG}" "${domain_full_name} ${record_type} [${action}]: ${err_code}, ${err_msg}"
    return 1
  fi
}

hw_api_req() {
  # Get the current UTC timestamp in the format 'YYYYMMDDTHHMMSSZ'
  timestamp=$(date -u +'%Y%m%dT%H%M%SZ')

  # Set the content type to 'application/json' for non-GET requests
  content_type=""
  [ "${http_request_method}" = "GET" ] || content_type="application/json"

  # Set the payload to an empty string for GET requests
  [ -n "${payload}" ] || payload="\"\""

  # Construct the canonical URI, ensure it ends with a slash
  canonical_uri="${path}"
  echo "${canonical_uri}" | grep -qE "/$" || canonical_uri="${canonical_uri}/"
  canonical_query_string="${query_string}"
  # Define the canonical headers
  canonical_headers="host:${host}\nx-sdk-date:${timestamp}\n"
  # Define the signed headers
  signed_headers="host;x-sdk-date"

  # Additional content type header for non-empty content type
  _h_content_type=""
  if [ "${content_type}" != "" ]; then
    canonical_headers="host:${host}\nx-sdk-date:${timestamp}\n"
    signed_headers="host;x-sdk-date"
    _h_content_type="Content-Type: ${content_type}"
  fi

  # Calculate the hashed request payload
  hashed_request_payload="$(printf -- "%b" "${payload}" | openssl dgst -sha256 -hex 2>/dev/null | sed 's/^.* //')"
  # Construct the canonical request
  canonical_request="${http_request_method}\n${canonical_uri}\n${canonical_query_string}\n${canonical_headers}\n${signed_headers}\n${hashed_request_payload}"
  # Calculate the hashed canonical request
  hashed_canonical_request="$(printf -- "%b" "${canonical_request}" | openssl dgst -sha256 -hex 2>/dev/null | sed 's/^.* //')"
  # Construct the string to sign
  string_to_sign="${algorithm}\n${timestamp}\n${hashed_canonical_request}"
  # Calculate the signature using HMAC-SHA256
  signature="$(printf -- '%b' "${string_to_sign}" | openssl dgst -sha256 -hmac "${secret_key}" -hex 2>/dev/null | sed 's/^.* //')"
  # Construct the authorization header
  authorization="${algorithm} Access=${secret_id}, SignedHeaders=${signed_headers}, Signature=${signature}"

  # Construct the request URI
	request_uri="${host}${path}"

  # Add query string if it exists
  [ -z "$query_string" ] ||  request_uri="${request_uri}""?${query_string}"

  # Log the request
  log_to_file "REQ" "$action" "{\"Request\":\"${query_string}\",\"Payload\":${payload}}"

  # Send the request using curl and capture the response
  response="$(curl -A "${AGENT}" -s \
    -X "${http_request_method}" \
    -H "X-Sdk-Date: ${timestamp}" \
    -H "host: $host" \
    -H "$_h_content_type" \
    -H "Authorization: ${authorization}" \
    -d "${payload}" \
       "https://${request_uri}" \
    )"

  # Log the response
  log_to_file "ACK" "$action" "${response}"

  return $?
}

hw_get_zone() {
  action="query_zones"
  http_request_method="GET"
  path="/v2/zones"
  # sld_name: second-level domain name, e.g. example.com of sub.example.com
  sld_name="$(echo ${domain_full_name} | awk -F '.' '{if (NF>2) print $(NF-1)"."$NF}')"
  query_string="name=${sld_name}.&search_mode=equal"
  payload=""
}

hw_insert_record() {
  action="create_record_sets"
  http_request_method="POST"
  path="/v2/zones/${zone_id}/recordsets"
  query_string=""
  payload="{\"name\":\"${domain_full_name}.\",\"type\":\"${record_type}\",\"records\":[\"${ip_address}\"]}"
}

hw_query_record() {
  action="query_records"
  http_request_method="GET"
  path="/v2/zones/${zone_id}/recordsets"
  query_string="name=${domain_full_name}.&search_mode=equal&type=${record_type}"
  payload=""
}

hw_set_record() {
  action="update_record_sets"
  http_request_method="PUT"
  path="/v2/zones/${zone_id}/recordsets/${record_id}"
  query_string=""
  payload="{\"name\":\"${domain_full_name}.\",\"type\":\"${record_type}\",\"records\":[\"${ip_address}\"]}"
}

main() {
  # Get the zone information
  hw_get_zone
  hw_api_req
  hw_api_err || return 1
  zone_id="$(echo "${response}" | sed -n 's/.*"id":"\([^"]\+\)".*/\1/p')"
  if [ -z "${zone_id}" ]; then
    logger -p err -s -t "${TAG}" "Fail attempt to extract zone_id for ${domain_full_name} ${record_type} from Huaweicloud API response"
    return 1
  fi

  # Attempt to insert a new DNS record
  [ -z "${ddnss_insert_record}" ] || {
    hw_insert_record
    hw_api_req
    hw_api_err || return 1
    logger -p notice -s -t "${TAG}" "${domain_full_name} ${ip_version} ${ip_address} [CreateRecord] successfully"
    return 0
  }

  # Get the DDNS record information
  hw_query_record
  hw_api_req
  hw_api_err || return 1
  record_id=`printf "%s" $response |  grep -Eo '"id":"[a-z0-9]+"' | cut -d':' -f2 | tr -d '"' | head -1`
  record_ip="$(printf "%s" ${response} | grep -Eo '"records":\[[^]]+]' | cut -d ':' -f 2-10 | tr -d '[' | tr -d ']' | tr -d '"' | head -1)"
  if [ -z "${record_id}" ] || [ -z "${record_ip}" ]; then
    logger -p err -s -t "${TAG}" "Fail attempt to extract record_id or record_ip for ${domain_full_name} ${record_type} from Huaweicloud API response"
    return 1
  fi

  # If the IP address is up to date here, it means the local DNS cache is out of date
  if [ "${ip_address}" = "${record_ip}" ]; then
    [ "${log_level}" -lt "${LOG_LEVEL_ERROR}" ] || logger -p info -s -t "${TAG}" "${domain_full_name} cache of ${ip_version} address ${ip_address} is up to date"
    # Skip when a force-update is not enabled (The IP address cache is already up to date)
    [ "$force_update" -eq 1 ] || return 0
  fi

  # Update the DDNS record IP address
  hw_set_record
  hw_api_req
  hw_api_err || return 1
  logger -p notice -s -t "${TAG}" "${domain_full_name} ${ip_version} address has been updated to ${ip_address}"
}

main "$@"